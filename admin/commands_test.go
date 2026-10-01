package main

import (
	"strings"
	"testing"
)

func TestTokenize(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"service status", []string{"service", "status"}},
		{"  service   logs  ", []string{"service", "logs"}},
		{`auth user disable "bob smith"`, []string{"auth", "user", "disable", "bob smith"}},
		{"service update 0.1.7-rc.2", []string{"service", "update", "0.1.7-rc.2"}},
	}
	for _, c := range cases {
		got, err := tokenize(c.in)
		if err != nil {
			t.Fatalf("tokenize(%q) 出错：%v", c.in, err)
		}
		if len(got) != len(c.want) {
			t.Fatalf("tokenize(%q) = %v，期望 %v", c.in, got, c.want)
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Fatalf("tokenize(%q)[%d] = %q，期望 %q", c.in, i, got[i], c.want[i])
			}
		}
	}
	if _, err := tokenize(`auth user add "bob`); err == nil {
		t.Fatal("未闭合的引号应当报错")
	}
}

func TestValidateCommandAllows(t *testing.T) {
	ok := [][]string{
		{"service", "status"},
		{"dshm", "service", "restart"}, // 带 dshm 前缀
		{"./dshm", "service", "logs"},
		{"version", "show"},
		{"version", "list"},
		{"version", "update", "0.1.8"},
		{"auth", "user", "disable", "bob"},
		{"dshm", "install"},
		{"disk"},
		{"help"},
	}
	for _, in := range ok {
		if _, err := validateCommand(in); err != nil {
			t.Errorf("validateCommand(%v) 被拒：%v", in, err)
		}
	}
}

func TestValidateCommandRejects(t *testing.T) {
	bad := [][]string{
		{},
		{"rm", "-rf", "/"},
		{"service", "status;", "id"},   // 分号不是命令分隔符，只是非法子命令
		{"service", "status", "$(id)"}, // 参数含非法字符
		{"service", "status", "`id`"},
		{"install.sh"},
		{"service", "shell"},           // 交互命令
		{"auth", "password"},           // 交互命令
		{"auth", "user", "add", "bob"}, // 交互命令
		// 旧的扁平写法与分组简称已全部移除，必须被拒（面板不替用户翻译）
		{"status"},
		{"up"},
		{"pw"},
		{"user", "list"},
		{"self", "install"},
		{"versions"},
		{"svc", "up"},
		{"login", "password"},
		{"cli", "update"},
		{"panel", "status"},
		// 已迁到 version 分组的老路径
		{"service", "version"},
		{"service", "versions"},
		{"service", "update"},
		{"service", "disk"},
	}
	for _, in := range bad {
		if _, err := validateCommand(in); err == nil {
			t.Errorf("validateCommand(%v) 本应被拒，却通过了", in)
		}
	}
}

// 三张派生表必须自洽 —— 这是"合并成一张表"这个重构的回归保护。
//
// 原来 allowedPaths / commandCatalog / interactivePaths 是三张手工平行的表，
// 靠注释保持一致，结果漂移过：白名单里有但按钮列表里没有（能执行却找不到入口）。
// 现在它们都由 commandTable 派生，本测试断言这个派生关系真的成立。
func TestDerivedCommandTables(t *testing.T) {
	allowed := map[string]bool{}
	for _, p := range allowedPaths {
		k := strings.Join(p, " ")
		if allowed[k] {
			t.Errorf("allowedPaths 里有重复项：%s", k)
		}
		allowed[k] = true
	}

	// 每个白名单路径都必须来自 commandTable（防止有人在派生之后又手工追加）
	tableKeys := map[string]bool{}
	for _, s := range commandTable {
		k := strings.Join(s.path, " ")
		if tableKeys[k] {
			t.Errorf("commandTable 里有重复项：%s", k)
		}
		tableKeys[k] = true
	}
	for k := range allowed {
		if !tableKeys[k] {
			t.Errorf("allowedPaths 里的 %s 不在 commandTable 里", k)
		}
	}

	// 被标记为交互的命令必须在白名单里，否则那条拒绝规则是死的
	for k := range interactivePaths {
		if !allowed[k] {
			t.Errorf("interactivePaths 里的 %s 不在白名单里（拒绝规则是死的）", k)
		}
	}
	// 按钮必须在白名单里，且必须有描述，否则点了会被 400 或显示空白
	for _, c := range commandCatalog {
		k := strings.Join(c.Path, " ")
		if !allowed[k] {
			t.Errorf("按钮 %s 不在白名单里（点了会被拒）", k)
		}
		if c.Desc == "" {
			t.Errorf("按钮 %s 没有描述", k)
		}
	}

	// 数量写死：改动命令表时这个测试会提醒你确认是不是有意的
	if len(allowedPaths) != 29 {
		t.Errorf("allowedPaths 应为 29 条，实际 %d", len(allowedPaths))
	}
	if len(commandCatalog) != 21 {
		t.Errorf("commandCatalog 应为 21 条，实际 %d", len(commandCatalog))
	}
	if len(interactivePaths) != 3 {
		t.Errorf("interactivePaths 应为 3 条，实际 %d", len(interactivePaths))
	}
}
