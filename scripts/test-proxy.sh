#!/usr/bin/env bash
# 代理（proxy/index.js）的离线测试。由 test-all.sh 自动发现。
#
# 为什么要有这个包装：真正的测试是 proxy/test-inject.js（Node 写的），而 CI 里是单独
# 一个步骤跑它。本地跑 test-all.sh 时它**不会被执行** —— 于是"本地全绿、CI 红"，
# 而且任何只在代理里出现的回归（例如之前的 Expect 绕过头改写）都逃过本地防线。
#
# 依赖自己装好再跑：CI 里「离线测试」这一步在 npm install 之前，若只判 node_modules
# 目录是否存在就会在依赖不全时硬跑，崩了还报成"测试异常"。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
. "$here/test-lib.sh"

if ! command -v node >/dev/null 2>&1; then
	skip "没有 node，跳过代理测试（CI 里会跑）"
	run_tests
	exit 0
fi

# 依赖检查要落到具体文件：`http-proxy` 不在的话 test-inject.js 会直接崩。
if [ ! -d "$root/proxy/node_modules/http-proxy" ]; then
	if command -v npm >/dev/null 2>&1 && [ -f "$root/proxy/package.json" ]; then
		printf '  代理依赖未安装，正在 npm install…\n'
		if ! (cd "$root/proxy" && npm install --no-audit --no-fund >/tmp/test-proxy-npm.log 2>&1); then
			skip "npm install 失败（离线环境？），跳过代理测试：$(tail -2 /tmp/test-proxy-npm.log | tr '\n' ' ')"
			run_tests
			exit 0
		fi
	else
		skip "没有 npm 或 proxy/package.json，跳过代理测试"
		run_tests
		exit 0
	fi
fi

# `|| true` 是为了拿到输出后自己判定：test-inject.js 崩了也会退出非 0，
# 而我们要分辨"有断言失败"与"根本没跑起来"。
out="$(cd "$root/proxy" && node test-inject.js 2>&1)" || true
# test-inject.js 自己打印 PASS=n FAIL=m，转成 test-lib 的计数
p="$(printf '%s' "$out" | grep -oE 'PASS=[0-9]+' | tail -1 | cut -d= -f2 || true)"
f="$(printf '%s' "$out" | grep -oE 'FAIL=[0-9]+' | tail -1 | cut -d= -f2 || true)"
if [ -z "$p" ]; then
	# 拿不到结果 = 脚本没跑完（语法错误、依赖缺失、端口占用…），必须算失败，
	# 但要把原始输出带出来，否则只看到一句"没有输出结果"无从下手。
	fail "代理测试没能跑完（未输出 PASS=n）：$(printf '%s' "$out" | tail -4 | tr '\n' ' ')"
else
	PASS=$((PASS + p))
	FAIL=$((FAIL + f))
	if [ "$f" = "0" ]; then
		pass "代理测试全部通过（$p 条）"
	else
		fail "代理测试有 $f 条失败"
		printf '%s\n' "$out" | grep -E 'FAIL' | sed 's/^/     /' >&2
	fi
fi
rm -f /tmp/test-proxy-npm.log
run_tests
