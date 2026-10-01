#!/usr/bin/env bash
# 代理（proxy/index.js）的离线测试。由 test-all.sh 自动发现。
#
# 为什么要有这个包装：真正的测试是 proxy/test-inject.js（Node 写的），而 CI 里是单独
# 一个步骤跑它。本地跑 test-all.sh 时它**不会被执行** —— 于是"本地全绿、CI 红"，
# 而且任何只在代理里出现的回归（例如之前的 Expect 绕过头改写）都逃过本地防线。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
. "$here/test-lib.sh"

if ! command -v node >/dev/null 2>&1; then
	skip "没有 node，跳过代理测试（CI 里会跑）"
	run_tests
fi
if [ ! -d "$root/proxy/node_modules" ]; then
	skip "proxy/node_modules 不存在（先 cd proxy && npm install），跳过"
	run_tests
fi

out="$(cd "$root/proxy" && node test-inject.js 2>&1)" || true
# test-inject.js 自己打印 PASS=n FAIL=m，转成 test-lib 的计数
p="$(printf '%s' "$out" | grep -oE 'PASS=[0-9]+' | tail -1 | cut -d= -f2 || true)"
f="$(printf '%s' "$out" | grep -oE 'FAIL=[0-9]+' | tail -1 | cut -d= -f2 || true)"
if [ -z "$p" ]; then
	fail "代理测试没有输出结果（可能崩了）：$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
	run_tests
fi
PASS=$((PASS + p))
FAIL=$((FAIL + f))
if [ "$f" = "0" ]; then
	pass "代理测试全部通过（$p 条）"
else
	fail "代理测试有 $f 条失败"
	printf '%s\n' "$out" | grep -E 'FAIL' | sed 's/^/     /' >&2
fi
run_tests
