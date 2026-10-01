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

# gofmt：格式不合规直接失败 —— 这是 CI 里最先卡住的一步。
unformatted="$(gofmt -l .)"
if [ -n "$unformatted" ]; then
	fail "gofmt 不合规：$(printf '%s' "$unformatted" | tr '\n' ' ')"
	printf '    修复：cd admin && gofmt -w .\n' >&2
else
	pass "gofmt 合规"
fi

# vet / test：只在能跑通时才算数。go.mod 声明的版本可能高于本地工具链
# （本地是旧版 Go、CI 是匹配版本），那种情况下工具链会自己提示，这里当作跳过。
if go vet ./... >/tmp/test-go-vet.log 2>&1; then
	pass "go vet"
else
	if grep -q 'go.mod requires go\|GOTOOLCHAIN\|go: downloading' /tmp/test-go-vet.log 2>/dev/null; then
		skip "本地 go 工具链与 go.mod 不匹配，跳过 vet（CI 里会跑）"
	else
		fail "go vet 失败：$(head -3 /tmp/test-go-vet.log | tr '\n' ' ')"
	fi
fi

if go test ./... >/tmp/test-go-test.log 2>&1; then
	pass "go test"
else
	fail "go test 失败：$(grep -E '^(---|\s+---)? *(FAIL|ok)' /tmp/test-go-test.log | head -3 | tr '\n' ' ')"
fi
rm -f /tmp/test-go-vet.log /tmp/test-go-test.log
run_tests
