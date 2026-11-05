#!/usr/bin/env bash
# vendor/dsh-auth-gate 的回归测试。由 test-all.sh 自动发现。
#
# 三件事：
#   1. 补丁本身的行为（resource 路由必须被守卫、拒绝时绝不执行、认不出的形状 fail closed）
#      —— 跑 vendor 里的 *.test.mjs；
#   2. vendor 目录必须与 vendor/dsh-auth-gate.patch 一致（防止有人手改后忘记更新补丁，
#      下次升级时补丁悄悄漂移）；
#   3. vendor 的版本必须与 Dockerfile 的 DSH_AUTH_GATE_VERSION 相同（构建时也会断言，
#      这里提前失败，省得打 tag 之后才发现）。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/test-lib.sh"

vendor="$root/vendor/dsh-auth-gate"

if ! command -v node >/dev/null 2>&1; then
	skip "没有 node，跳过 vendor 门禁测试"
	run_tests
	exit 0
fi

if [ ! -d "$vendor" ]; then
	fail "vendor/dsh-auth-gate 不存在"
	run_tests
	exit 1
fi

section "vendor/dsh-auth-gate"

# 1. 补丁行为
out="$(cd "$vendor" && node test/resource-guard.test.mjs 2>&1)" || true
p="$(printf '%s' "$out" | grep -oE 'PASS=[0-9]+' | tail -1 | cut -d= -f2 || true)"
f="$(printf '%s' "$out" | grep -oE 'FAIL=[0-9]+' | tail -1 | cut -d= -f2 || true)"
if [ -z "$p" ]; then
	fail "补丁测试没跑完：$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
else
	PASS=$((PASS + p))
	FAIL=$((FAIL + f))
	if [ "$f" = "0" ]; then
		pass "resource 路由守卫测试全部通过（$p 条）"
	else
		fail "resource 路由守卫测试有 $f 条失败"
		printf '%s\n' "$out" | grep -E 'FAIL' | sed 's/^/     /' >&2
	fi
fi

# 2. vendor 与补丁一致
if "$root/scripts/vendor-gate.sh" --check >/tmp/vended-check.out 2>&1; then
	pass "vendor 与补丁一致（没被手改）"
else
	fail "vendor 与补丁不一致：$(tail -2 /tmp/vended-check.out | tr '\n' ' ')"
fi
rm -f /tmp/vended-check.out

# 3. 版本与 Dockerfile 的 ARG 对齐
vendored="$(node -p "require('$vendor/package.json').version" 2>/dev/null || true)"
pinned="$(awk -F= '/^ARG DSH_AUTH_GATE_VERSION=/{gsub(/[ \t\r]/, "", $2); print $2; exit}' "$root/Dockerfile")"
if [ -n "$vendored" ] && [ "$vendored" = "$pinned" ]; then
	pass "vendor 版本与 DSH_AUTH_GATE_VERSION 一致（$vendored）"
else
	fail "vendor 版本($vendored) 与 DSH_AUTH_GATE_VERSION($pinned) 不一致"
fi

run_tests
