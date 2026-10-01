package main

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
)

// 面板里的「命令台」不是自由 shell：输入会被拆成参数数组，用 exec 直接调用
// 项目里的 dshm（不经过 sh -c），并且命令路径必须落在白名单内。
//
// 这样既满足「在面板里敲 dshm 命令」，又不会因为一个分号/管道变成任意命令执行。
// （面板本身已经持有 docker.sock，本来就是高权限组件；这里只是把"顺手提权"
// 的最小阻力去掉。）

// 命令表：**这是唯一的一份**。
//
// 原来这里是三张手工平行的表 —— allowedPaths（白名单）、commandCatalog（按钮 +
// 描述）、interactivePaths（不可非交互执行）—— 靠注释维持一致。它们确实漂移过：
// 白名单里有但按钮列表里没有（能执行却找不到入口），以及 `version update` 的参数
// 形式只在描述里写对、白名单里写错。
//
// 现在合并成一张：
//   - `path`        命令路径（token 级前缀匹配；后面可以跟参数）
//   - `desc`        UI 上的说明；空串表示**不列进按钮**（例如 help 类、纯交互类）
//   - `interactive` 需要交互输入，命令台无法执行 → 明确拒绝而不是让用户干等
//
// allowedPaths / commandCatalog / interactivePaths 都由它派生，见下面的 init()。
// 这样"加了白名单却忘了加按钮"这类漂移在结构上就不可能发生。
type commandSpec struct {
	path        []string
	desc        string
	interactive bool
}

var commandTable = []commandSpec{
	// ── 容器生命周期 ──
	{path: []string{"service", "up"}, desc: "启动 / 应用 .env 改动"},
	{path: []string{"service", "restart"}, desc: "重启 dsh"},
	{path: []string{"service", "down"}, desc: "停止（数据保留）"},
	{path: []string{"service", "status"}, desc: "健康 / 端口 / 登录用户"},
	{path: []string{"service", "logs"}, desc: "查看 dsh 日志"},
	{path: []string{"service", "url"}, desc: "一次性 launch URL"},
	{path: []string{"service", "shell"}, interactive: true},
	{path: []string{"service", "help"}},

	// ── dsh 版本 ──
	{path: []string{"version", "show"}, desc: "看全四个 dsh 版本"},
	{path: []string{"version", "list"}, desc: "列出可装的 dsh 版本（npm）"},
	{path: []string{"version", "update"}, desc: "升级（默认拉已构建镜像；--build 本地构建）"},
	{path: []string{"version", "help"}},

	// ── 登录凭据 ──
	{path: []string{"auth", "user", "list"}, desc: "列出登录用户"},
	{path: []string{"auth", "user", "add"}, interactive: true},
	{path: []string{"auth", "user", "disable"}, desc: "禁用用户（跟用户名）"},
	{path: []string{"auth", "totp", "enable"}, desc: "开启两步验证（跟用户名）"},
	{path: []string{"auth", "totp", "disable"}, desc: "关闭两步验证（跟用户名）"},
	{path: []string{"auth", "password"}, interactive: true},
	{path: []string{"auth", "help"}},

	// ── dshm 自身 ──
	{path: []string{"dshm", "install"}, desc: "把 dshm 注册为系统命令"},
	{path: []string{"dshm", "uninstall"}, desc: "移除系统命令"},
	{path: []string{"dshm", "update"}, desc: "更新 dshm 自身（从 GitHub 拉取）"},
	{path: []string{"dshm", "help"}},

	// ── 管理面板 ──
	{path: []string{"admin", "status"}, desc: "面板运行状态"},
	{path: []string{"admin", "logs"}, desc: "面板日志"},
	{path: []string{"admin", "url"}, desc: "面板地址"},
	{path: []string{"admin", "help"}, desc: "面板命令帮助"},

	// ── 顶层 ──
	{path: []string{"disk"}, desc: "磁盘占用"},
	{path: []string{"help"}},
}

// 命令台里一个按钮的信息（JSON 输出给前端）。
type CommandInfo struct {
	Path []string `json:"path"`
	Desc string   `json:"desc"`
}

// 由 commandTable 派生的三份视图。**不要手工维护这三个**。
var (
	allowedPaths     [][]string
	commandCatalog   []CommandInfo
	interactivePaths = map[string]bool{}
)

func init() {
	// 容量按表大小预留，避免运行时扩容
	allowedPaths = make([][]string, 0, len(commandTable))
	commandCatalog = make([]CommandInfo, 0, len(commandTable))
	for _, spec := range commandTable {
		allowedPaths = append(allowedPaths, spec.path)
		if spec.interactive {
			interactivePaths[strings.Join(spec.path, " ")] = true
		}
		// desc 为空表示"能执行但不列进按钮"（help 类，以及纯交互类）
		if spec.desc != "" {
			commandCatalog = append(commandCatalog, CommandInfo{Path: spec.path, Desc: spec.desc})
		}
	}
}

// 注意：这里曾经有 groupAlias（svc/login/cli/panel）与 legacyAlias（up/pw …）两张
// 映射表，以及配套的 normalize()。它们在 dshm 只保留一套写法之后已全部删除 ——
// 面板不再替用户翻译旧命令，只接受 `dshm <分组> <子命令>`。

var safeArg = regexp.MustCompile(`^[A-Za-z0-9._@/:=+,-]+$`)

// tokenize 按空白拆分，支持单/双引号；不处理转义，也不认识任何 shell 语法
// （因为根本不会交给 shell）。
func tokenize(line string) ([]string, error) {
	var out []string
	var cur strings.Builder
	var quote byte
	started := false
	for i := 0; i < len(line); i++ {
		c := line[i]
		if quote != 0 {
			if c == quote {
				quote = 0
				continue
			}
			cur.WriteByte(c)
			continue
		}
		switch c {
		case '\'', '"':
			quote = c
			started = true
		case ' ', '\t', '\n', '\r':
			if started || cur.Len() > 0 {
				out = append(out, cur.String())
				cur.Reset()
				started = false
			}
		default:
			cur.WriteByte(c)
			started = true
		}
	}
	if quote != 0 {
		return nil, errors.New("引号没有闭合")
	}
	if started || cur.Len() > 0 {
		out = append(out, cur.String())
	}
	return out, nil
}

// matchAllowed 返回 tokens 命中的最长白名单路径长度（0 表示不匹配）。
func matchAllowed(tokens []string) int {
	best := -1
	for _, path := range allowedPaths {
		if len(tokens) < len(path) {
			continue
		}
		match := true
		for i, p := range path {
			if tokens[i] != p {
				match = false
				break
			}
		}
		if match && len(path) > best {
			best = len(path)
		}
	}
	return best
}

// validateCommand 返回可以直接交给 exec 的参数数组（不含 dshm 自身）。
func validateCommand(tokens []string) ([]string, error) {
	if len(tokens) == 0 {
		return nil, errors.New("命令为空")
	}
	// 允许用户写 `dshm service status` 或 `./dshm service status`。
	//
	// 但要注意：`dshm` 本身也是一个**分组名**（管理 dshm 自身，如 `dshm install`）。
	// 所以不能见到首 token 是 dshm 就无条件剥掉 —— 那会把 `dshm install` 变成
	// `install`，从而匹配不到白名单里的 {"dshm","install"}。这里两种解释都试，
	// 取能匹配上的那个。
	best := matchAllowed(tokens)
	argv := tokens
	if first := tokens[0]; first == "dshm" || first == "./dshm" || strings.HasSuffix(first, "/dshm") {
		if stripped := matchAllowed(tokens[1:]); stripped > best {
			best = stripped
			argv = tokens[1:]
		}
	}
	if len(argv) == 0 || best < 0 {
		return nil, fmt.Errorf("不支持的 dshm 命令：%s（面板只允许白名单内的命令）", strings.Join(tokens, " "))
	}
	key := strings.Join(argv[:best], " ")
	if interactivePaths[key] {
		return nil, fmt.Errorf("%s 需要交互输入，命令台暂不支持；请在服务器上直接运行", key)
	}
	for _, a := range argv[best:] {
		if !safeArg.MatchString(a) {
			return nil, fmt.Errorf("参数含不允许的字符：%s", a)
		}
	}
	// `service logs` 默认是 `docker compose logs -f`（跟随滚动、永不返回）。面板把 dshm
	// 调用串行化（一把 execMu），一个不返回的命令会占住那把锁直到 15 分钟超时，期间
	// 启停、重启、切换 dsh 版本全部 409 —— 一个只读的"看日志"按钮就能把面板锁死。
	// 所以面板一律补上 --no-follow（打印最近 100 行后返回）。
	// 放在这里而不是 UI 里：面板的日志按钮走 /api/logs，但命令台里手敲
	// `service logs` 也要被兜住。
	if key == "service logs" {
		argv = append(argv, "--no-follow")
	}
	return argv, nil
}
