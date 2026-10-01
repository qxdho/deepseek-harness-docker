#!/usr/bin/env bash
# Go 侧检查：格式、vet、单元测试。由 test-all.sh 自动发现。
#
# 为什么要有这个脚本：CI 的 checks 作业里有 `test -z "$(gofmt -l .)"`，但本地跑
# test-all.sh 时不会检查 Go —— 于是「本地全绿、CI 红」出现过：删函数时留了个多余空行，
# gofmt 一眼能看出来，却因为本地没跑而白等一轮 CI。
#
# 没有 go 工具链时只提示并跳过（本地环境未必装了 Go），不算失败。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
. "$here/test-lib.sh"

if ! command -v go >/dev/null 2>&1; then
	skip "没有 go 工具链，跳过 Go 检查（CI 里会跑）"
	exit 0
fi

cd "$root/admin"

# TMPDIR 指到仓库内：有些环境 /tmp 是 noexec，而 admin 的自更新测试会把「下载到的
# 二进制」写进 t.TempDir() 再执行它 —— 放 /tmp 就会 fork/exec permission denied，
# 看起来像代码坏了，其实是挂载选项。t.TempDir() 认 TMPDIR，所以在这里统一改。
gotmp="$root/.gotmp"
mkdir -p "$gotmp"
export TMPDIR="$gotmp"
trap 'rm -rf "$gotmp"' EXIT

# gofmt：格式不合规直接失败 —— 这是 CI 里最先卡住的一步。
unformatted="$(gofmt -l .)"
if [ -n "$unformatted" ]; then
	fail "gofmt 不合规：$(printf '%s' "$unformatted" | tr '\n' ' ')"
	printf '    修复：cd admin && gofmt -w .\n' >&2
else
	pass "gofmt 合规"
fi

# 本地工具链版本低于 go.mod 要求时（本地旧 Go / CI 用匹配版本），go 会直接报
#   go: go.mod requires go >= 1.27 (running go 1.24.5; GOTOOLCHAIN=local)
# 这不是代码问题，跳过而不是失败 —— 但**必须先判断再跑**：vet 与 test 都要判，
# 否则会出现"vet 跳过了、test 却 FAIL"的自相矛盾（真踩到过）。
toolchain_mismatch() { # <日志文件>
	grep -q 'go.mod requires go\|GOTOOLCHAIN=\|go: downloading go1\.' "$1" 2>/dev/null
}

if go vet ./... >/tmp/test-go-vet.log 2>&1; then
	pass "go vet"
elif toolchain_mismatch /tmp/test-go-vet.log; then
	skip "本地 go 工具链与 go.mod 不匹配，跳过 vet 与 test（CI 里会跑）"
	rm -f /tmp/test-go-vet.log /tmp/test-go-test.log
	run_tests
	exit $?
else
	fail "go vet 失败：$(head -3 /tmp/test-go-vet.log | tr '\n' ' ')"
fi

if go test ./... >/tmp/test-go-test.log 2>&1; then
	pass "go test"
elif toolchain_mismatch /tmp/test-go-test.log; then
	skip "本地 go 工具链与 go.mod 不匹配，跳过 test（CI 里会跑）"
else
	fail "go test 失败：$(grep -E '^(---|\s+---)? *(FAIL|ok)' /tmp/test-go-test.log | head -3 | tr '\n' ' ')"
fi
rm -f /tmp/test-go-vet.log /tmp/test-go-test.log
run_tests
