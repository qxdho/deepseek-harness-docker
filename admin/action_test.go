package main

import "testing"

// 面板的启停必须映射到等价的 dshm 子命令。
//
// 这是「dshm 是唯一操作入口，面板只是外壳」这条定位的具体体现。曾经面板直接调
// Docker API 的 start/stop/restart，会绕过 dshm 的启动前预检 —— 改了 .env 之后点
// 「重启」看着成功、实际毫无变化。这个测试把映射钉住，避免有人图省事又改回去。
func TestActionDshmMapping(t *testing.T) {
	must := map[string]string{
		"start":   "service up",
		"stop":    "service down",
		"restart": "service restart",
	}
	for action, want := range must {
		argv, ok := actionDshm(action)
		if !ok {
			t.Errorf("%s 应有对应的 dshm 命令", action)
			continue
		}
		got := ""
		for i, a := range argv {
			if i > 0 {
				got += " "
			}
			got += a
		}
		if got != want {
			t.Errorf("%s 应映射到 %q，实际 %q", action, want, got)
		}
	}
}

// 未知动作必须被拒，绝不能回落到「直接调 Docker」之类的路径
func TestActionDshmRejectsUnknown(t *testing.T) {
	for _, bad := range []string{"", "kill", "pause", "rm", "exec", "up", "restart; rm -rf /"} {
		if argv, ok := actionDshm(bad); ok {
			t.Errorf("未知动作 %q 不应被接受，实际映射到 %v", bad, argv)
		}
	}
}
