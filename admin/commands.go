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

// 需要交互输入的命令，命令台无法非交互执行，明确拒绝而不是让用户干等。
// 只需要列 allowedPaths 里确实存在的那些（其余属于"不在白名单"）。
var interactivePaths = map[string]bool{
	"service shell": true,
	"auth password": true,
	"auth user add": true,
}

// 允许执行的完整命令路径（token 级前缀匹配；后面可以跟参数）。
// 与 dshm 的分组结构一一对应：service / version / auth / dshm / admin。
var allowedPaths = [][]string{
	{"service", "up"},
	{"service", "down"},
	{"service", "restart"},
	{"service", "status"},
	{"service", "logs"},
	{"service", "shell"},
	{"service", "url"},
	{"service", "help"},
	{"version", "show"},
	{"version", "list"},
	{"version", "update"},
	{"version", "help"},
	{"auth", "help"},
	{"auth", "password"},
	{"auth", "user", "list"},
	{"auth", "user", "add"},
	{"auth", "user", "disable"},
	{"auth", "totp", "enable"},
	{"auth", "totp", "disable"},
	{"dshm", "install"},
	{"dshm", "uninstall"},
	{"dshm", "update"},
	{"dshm", "help"},
	{"admin", "help"},
	{"admin", "status"},
	{"admin", "logs"},
	{"admin", "url"},
	{"disk"},
	{"help"},
}

type CommandInfo struct {
	Path []string `json:"path"`
	Desc string   `json:"desc"`
}

// 命令台里列出来的按钮（去掉需要交互的，以及 help 这类没人会点的）。
var commandCatalog = []CommandInfo{
	{Path: []string{"service", "up"}, Desc: "启动 / 应用 .env 改动"},
	{Path: []string{"service", "restart"}, Desc: "重启 dsh"},
	{Path: []string{"service", "down"}, Desc: "停止（数据保留）"},
	{Path: []string{"service", "status"}, Desc: "健康 / 端口 / 登录用户"},
	{Path: []string{"service", "logs"}, Desc: "查看 dsh 日志"},
	{Path: []string{"version", "show"}, Desc: "看全四个 dsh 版本"},
	{Path: []string{"version", "list"}, Desc: "列出可装的 dsh 版本（npm）"},
	{Path: []string{"version", "update"}, Desc: "升级（默认拉镜像，可跟版本号）"},
	{Path: []string{"service", "url"}, Desc: "一次性 launch URL"},
	{Path: []string{"disk"}, Desc: "磁盘占用"},
	{Path: []string{"auth", "user", "list"}, Desc: "列出登录用户"},
	{Path: []string{"auth", "user", "disable"}, Desc: "禁用用户（跟用户名）"},
	{Path: []string{"auth", "totp", "enable"}, Desc: "开启两步验证（跟用户名）"},
	{Path: []string{"auth", "totp", "disable"}, Desc: "关闭两步验证（跟用户名）"},
	{Path: []string{"dshm", "install"}, Desc: "把 dshm 注册为系统命令"},
	{Path: []string{"dshm", "uninstall"}, Desc: "移除系统命令"},
	{Path: []string{"dshm", "update"}, Desc: "更新 dshm 自身（从 GitHub 拉取）"},
	{Path: []string{"admin", "status"}, Desc: "面板运行状态"},
	{Path: []string{"admin", "logs"}, Desc: "面板日志"},
	{Path: []string{"admin", "url"}, Desc: "面板地址"},
	{Path: []string{"admin", "help"}, Desc: "面板命令帮助"},
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
	return argv, nil
}
