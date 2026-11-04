#!/usr/bin/env bash
# scripts/healthcheck.sh 的单测。
#
# 守的是那条真实事故：门禁插件没挂上时 `/` 会回 401，旧版健康检查把它当成健康，
# 于是「谁都能进」的容器在编排层看起来一切正常。现在只认 /auth/login == 200。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/test-lib.sh"

check="$root/scripts/healthcheck.sh"
[ -f "$check" ] || {
	fail "找不到 scripts/healthcheck.sh"
	run_tests
	exit 1
}

if ! command -v node >/dev/null 2>&1; then
	skip "没有 node，跳过 healthcheck 单测"
	run_tests
	exit 0
fi

port=$(((RANDOM % 800) + 19200))

# 假服务：按路径返回预设状态码。/auth/login 的码由环境变量决定。
node -e '
const http = require("node:http");
const loginCode = Number(process.env.LOGIN_CODE || "200");
const rootCode = Number(process.env.ROOT_CODE || "401");
http.createServer((q, r) => {
  const path = String(q.url || "/").split("?")[0];
  r.writeHead(path === "/auth/login" ? loginCode : rootCode, { "content-type": "text/plain" });
  r.end("x");
}).listen(Number(process.argv[1]), "127.0.0.1");
' "$port" &
srv=$!
trap 'kill "$srv" 2>/dev/null || true' EXIT
sleep 1

run_hc() { PROXY_PORT="$port" "$check" >/dev/null 2>&1; }

section "healthcheck.sh"

# 1. 正常：登录页 200
if PROXY_PORT="$port" "$check" >/dev/null 2>&1; then
	pass "登录页 200：判定健康"
else
	fail "登录页 200 却判定不健康"
fi

# 2. 事故复现：登录页 404（门禁没挂），但 / 返回 401 —— 旧版会误判成健康
kill "$srv" 2>/dev/null || true
wait "$srv" 2>/dev/null || true
LOGIN_CODE=404 ROOT_CODE=401 node -e '
const http = require("node:http");
http.createServer((q, r) => {
  const path = String(q.url || "/").split("?")[0];
  r.writeHead(path === "/auth/login" ? 404 : 401, { "content-type": "text/plain" });
  r.end("x");
}).listen(Number(process.argv[1]), "127.0.0.1");
' "$port" &
srv=$!
sleep 1
if PROXY_PORT="$port" "$check" >/dev/null 2>&1; then
	fail "门禁没挂上（/auth/login 404）却判定健康 —— 这正是那次事故的样子"
else
	pass "门禁没挂上（/auth/login 404）判定为不健康"
fi

# 3. / 返回 200 也不能替代登录页
kill "$srv" 2>/dev/null || true
wait "$srv" 2>/dev/null || true
node -e '
const http = require("node:http");
http.createServer((q, r) => {
  const path = String(q.url || "/").split("?")[0];
  r.writeHead(path === "/auth/login" ? 500 : 200, { "content-type": "text/plain" });
  r.end("x");
}).listen(Number(process.argv[1]), "127.0.0.1");
' "$port" &
srv=$!
sleep 1
if PROXY_PORT="$port" "$check" >/dev/null 2>&1; then
	fail "/ 是 200、登录页 500 却判定健康"
else
	pass "/ 正常但登录页 500：判定不健康"
fi

# 4. 服务根本不通：不健康（而不是超时后误判）
kill "$srv" 2>/dev/null || true
wait "$srv" 2>/dev/null || true
srv=""
if PROXY_PORT="$port" "$check" >/dev/null 2>&1; then
	fail "端口没人监听却判定健康"
else
	pass "端口没人监听：判定不健康"
fi

run_tests
