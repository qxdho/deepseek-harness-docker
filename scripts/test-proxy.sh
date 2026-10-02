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
# 启动代理并**真实转发一次请求**时，不能出现与使用者无关的弃用警告。
#
# http-proxy 内部调用 Node 已废弃的 `util._extend`，而且是在**转发请求**时调用
# （common.js 的 setupOutgoing），所以只启动不打流量是测不出来的。proxy/index.js
# 在 require 之前把它替换成 Object.assign；这条用例专门守住它 —— 否则升级 Node
# 或调整 require 顺序时会悄悄把警告带回来（用户会来问"这是什么"）。
dep_log="$(mktemp)"
dep_up_port=$(((RANDOM % 500) + 15200))
dep_port=$((dep_up_port + 500))
node -e "require('http').createServer((q,r)=>{r.writeHead(200);r.end('ok')}).listen(${dep_up_port},'127.0.0.1')" &
dep_up=$!
DSH_HOST=127.0.0.1 DSH_PORT="$dep_up_port" PROXY_PORT="$dep_port" \
	node "$root/proxy/index.js" >"$dep_log" 2>&1 &
dep_pid=$!
for _ in $(seq 1 50); do
	grep -q '\[proxy\] 0.0.0.0' "$dep_log" 2>/dev/null && break
	sleep 0.1
done
if kill -0 "$dep_pid" 2>/dev/null; then
	pass "代理启动成功"
else
	fail "代理没能启动：$(tail -2 "$dep_log" | tr '\n' ' ')"
fi
# 驱动一次真实转发：正是这一步才会触发 http-proxy 的 _extend 调用
node -e "require('http').get({host:'127.0.0.1',port:${dep_port},path:'/'},(r)=>{r.resume();r.on('end',()=>process.exit(0))}).on('error',()=>process.exit(1))" \
	>/dev/null 2>&1 || true
sleep 0.3
if grep -q 'DEP0060' "$dep_log"; then
	fail "转发时仍打印 DEP0060（util._extend 没有被替换）"
else
	pass "转发请求时没有 util._extend 弃用警告（DEP0060）"
fi
kill "$dep_pid" "$dep_up" 2>/dev/null || true
wait "$dep_pid" "$dep_up" 2>/dev/null || true
rm -f "$dep_log"

rm -f /tmp/test-proxy-npm.log
run_tests
