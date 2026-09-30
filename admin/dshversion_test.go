package main

import (
	"sort"
	"testing"
)

// dsh 的版本号全是预发布形态（0.2.0-rc.2），排序错了会让面板把「最新版」标在错误
// 的位置上 —— 而面板会拿这个值去触发构建。rc.10 vs rc.2 是最典型的坑：字典序会
// 认为 "rc.10" < "rc.2"。
func TestCompareSemver(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"0.1.7-rc.2", "0.2.0-rc.2", -1},
		{"0.2.0-rc.2", "0.1.7-rc.2", 1},
		{"0.2.0-rc.2", "0.2.0-rc.2", 0},
		{"0.2.0-rc.2", "0.2.0-rc.10", -1}, // 数字段必须按数值比
		{"0.2.0-rc.10", "0.2.0-rc.2", 1},
		{"0.1.7-alpha.1", "0.1.7-alpha.2", -1},
		{"0.1.7-alpha.2", "0.1.7-rc.1", -1}, // alpha < rc（字典序）
		{"0.1.5-rc.3", "0.1.7-rc.1", -1},
		{"1.0.0", "0.9.9", 1},
		{"0.2.0", "0.2.0-rc.1", 1}, // 正式版 > 预发布
		{"0.2.0-rc.1", "0.2.0", -1},
		{"1.2.3+build", "1.2.3", 0}, // 构建元数据不参与比较
	}
	for _, c := range cases {
		if got := compareSemver(c.a, c.b); got != c.want {
			t.Errorf("compareSemver(%q, %q) = %d，期望 %d", c.a, c.b, got, c.want)
		}
	}
}

// 排序结果必须把最新版放在最后 —— 面板取 versions[last] 作为兜底的 latest。
func TestVersionSortOrder(t *testing.T) {
	in := []string{"0.2.0-rc.2", "0.1.7-rc.2", "0.2.0-rc.10", "0.1.7-alpha.1"}
	// 用与 dshversion.go 的 all() 完全相同的排序方式
	sort.Slice(in, func(i, j int) bool { return compareSemver(in[i], in[j]) < 0 })
	// 升序：rc.2 < rc.10（数字按数值比），所以 rc.10 在最后
	want := []string{"0.1.7-alpha.1", "0.1.7-rc.2", "0.2.0-rc.2", "0.2.0-rc.10"}
	for i := range want {
		if in[i] != want[i] {
			t.Fatalf("排序结果 %v，期望 %v", in, want)
		}
	}
}

// 版本号会被写进 .env 并当作 compose 构建参数使用，所以必须严格限制字符集：
// 一个换行就能在 .env 里凭空多出一个变量（比如把 DSH_UID 改成 0）。
func TestVersionRejectsInjection(t *testing.T) {
	bad := []string{
		"",
		"1.0.0\nDSH_UID=0",
		"1.0.0\r\nDSH_UID=0",
		"1.0.0 DSH_UID=0",
		"1.0.0;rm -rf /",
		"1.0.0$(id)",
		"1.0.0`id`",
		"../etc/passwd",
		"=1.0.0",
		"-1.0.0",
		"1.0.0#comment",
		"版本",
	}
	for _, v := range bad {
		if versionRe.MatchString(v) {
			t.Errorf("versionRe 不应接受 %q", v)
		}
	}
	good := []string{
		"0.2.0-rc.2",
		"0.1.7-rc.2",
		"1.0.0",
		"0.2.0-alpha.10",
		"1.2.3+build.5",
		"latest",
	}
	for _, v := range good {
		if !versionRe.MatchString(v) {
			t.Errorf("versionRe 应接受 %q", v)
		}
	}
}

// 超长输入应被拒绝（regexp 已限定长度）
func TestVersionRejectsOverlong(t *testing.T) {
	long := make([]byte, 200)
	for i := range long {
		long[i] = '1'
	}
	if versionRe.MatchString(string(long)) {
		t.Error("versionRe 不应接受 200 字符的版本号")
	}
}
