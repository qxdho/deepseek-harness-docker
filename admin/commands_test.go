package main

import "testing"

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
