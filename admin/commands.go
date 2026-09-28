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
var interactivePaths = map[string]bool{
	"service shell":   true,
	"auth password":   true,
	"auth user add":   true,
	"admin install":   true,
	"admin uninstall": true,
	"admin password":  true,
}

// 允许执行的完整命令路径（token 级前缀匹配；后面可以跟参数）。
var allowedPaths = [][]string{
	{"service", "up"},
	{"service", "down"},
	{"service", "restart"},
	{"service", "status"},
	{"service", "logs"},
	{"service", "shell"},
	{"service", "version"},
	{"service", "update"},
	{"service", "url"},
	{"service", "disk"},
	{"service", "help"},
	{"auth", "help"},
	{"auth", "password"},
	{"auth", "user", "list"},
	{"auth", "user", "add"},
	{"auth", "user", "disable"},
	{"auth", "totp", "enable"},
	{"auth", "totp", "disable"},
	{"self", "install"},
	{"self", "uninstall"},
	{"self", "help"},
	{"admin", "help"},
	{"admin", "status"},
	{"admin", "logs"},
	{"admin", "url"},
	{"help"},
}

type CommandInfo struct {
	Path []string `json:"path"`
	Desc string   `json:"desc"`
}

// 命令台里列出来的按钮（去掉需要交互的）。
var commandCatalog = []CommandInfo{
	{[]string{"service", "up"}, "启动 / 应用 .env 改动"},
	{[]string{"service", "restart"}, "重启 dsh"},
	{[]string{"service", "down"}, "停止（数据保留）"},
	{[]string{"service", "status"}, "健康 / 端口 / 登录用户"},
	{[]string{"service", "logs"}, "查看 dsh 日志"},
	{[]string{"service", "version"}, "容器内 dsh 版本"},
	{[]string{"service", "update"}, "升级 dsh（可跟版本号）"},
	{[]string{"service", "url"}, "一次性 launch URL"},
	{[]string{"service", "disk"}, "磁盘占用"},
	{[]string{"auth", "user", "list"}, "列出登录用户"},
	{[]string{"auth", "user", "disable"}, "禁用用户（跟用户名）"},
	{[]string{"auth", "totp", "enable"}, "开启两步验证（跟用户名）"},
	{[]string{"auth", "totp", "disable"}, "关闭两步验证（跟用户名）"},
	{[]string{"self", "install"}, "把 dshm 注册为系统命令"},
	{[]string{"admin", "help"}, "面板命令帮助"},
}

// 分组别名 + 旧的扁平写法，都归一到 allowedPaths 的形态。
var groupAlias = map[string]string{
	"svc": "service", "service": "service",
	"login": "auth", "auth": "auth",
	"cli": "self", "self": "self",
	"panel": "admin", "admin": "admin",
}

var legacyAlias = map[string][]string{
	"up": {"service", "up"}, "down": {"service", "down"}, "restart": {"service", "restart"},
	"status": {"service", "status"}, "logs": {"service", "logs"}, "version": {"service", "version"},
	"update": {"service", "update"}, "url": {"service", "url"}, "disk": {"service", "disk"},
	"pw": {"auth", "password"}, "passwd": {"auth", "password"}, "password": {"auth", "password"},
	"user": {"auth", "user"}, "totp": {"auth", "totp"},
	"install-self": {"self", "install"}, "link": {"self", "install"}, "install-cli": {"self", "install"},
	"uninstall-self": {"self", "uninstall"}, "unlink": {"self", "uninstall"},
}

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

// normalize 把分组别名与旧扁平写法翻译成规范 token 序列。
func normalize(tokens []string) []string {
	if len(tokens) == 0 {
		return tokens
	}
	if l, ok := legacyAlias[tokens[0]]; ok {
		out := append([]string{}, l...)
		return append(out, tokens[1:]...)
	}
	if g, ok := groupAlias[tokens[0]]; ok {
		out := append([]string{}, tokens...)
		out[0] = g
		return out
	}
	return append([]string{}, tokens...)
}

// validateCommand 返回可以直接交给 exec 的参数数组（不含 dshm 自身）。
func validateCommand(tokens []string) ([]string, error) {
	// 允许用户写 `dshm service status` 或 `./dshm service status`
	if len(tokens) > 0 {
		switch first := tokens[0]; {
		case first == "dshm" || first == "./dshm" || strings.HasSuffix(first, "/dshm"):
			tokens = tokens[1:]
		}
	}
	tokens = normalize(tokens)
	if len(tokens) == 0 {
		return nil, errors.New("命令为空")
	}
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
	if best < 0 {
		return nil, fmt.Errorf("不支持的 dshm 命令：%s（面板只允许白名单内的命令）", strings.Join(tokens, " "))
	}
	key := strings.Join(tokens[:best], " ")
	if interactivePaths[key] {
		return nil, fmt.Errorf("%s 需要交互输入，命令台暂不支持；请在服务器上直接运行", key)
	}
	for _, a := range tokens[best:] {
		if !safeArg.MatchString(a) {
			return nil, fmt.Errorf("参数含不允许的字符：%s", a)
		}
	}
	return tokens, nil
}
