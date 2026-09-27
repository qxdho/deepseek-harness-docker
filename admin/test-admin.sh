#!/usr/bin/env bash
# admin/ 面板的离线测试：不需要 docker，只验证鉴权、CSRF、路由与静态页。
#
#   ./admin/test-admin.sh
#
# 需要 go（现场构建）或设置 DSH_ADMIN_BIN 指向已构建的二进制；需要 curl。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# 临时目录放在脚本所在目录下（而不是 /tmp）：某些环境 /tmp 是 noexec，
# 在那里构建出来的二进制根本执行不了。
tmp="$(mktemp -d "$HERE/.admin-test.XXXXXX")"
pid=""
cleanup() {
	[ -n "$pid" ] && kill "$pid" 2>/dev/null || true
	rm -rf "$tmp"
}
trap cleanup EXIT

BIN="${DSH_ADMIN_BIN:-}"
if [ -z "$BIN" ]; then
	if ! command -v go >/dev/null 2>&1; then
		echo "需要 go，或设置 DSH_ADMIN_BIN 指向已构建的 dsh-admin"
		exit 1
	fi
	(cd "$HERE" && go build -trimpath -ldflags='-s -w' -o "$tmp/dsh-admin" .)
	BIN="$tmp/dsh-admin"
fi
command -v curl >/dev/null 2>&1 || { echo "需要 curl"; exit 1; }

port=$(((RANDOM % 10000) + 20000))
hash="$(printf 'TestPassw0rd!x' | "$BIN" -hash)"
secret="$("$BIN" -gen-secret)"
cat >"$tmp/config.json" <<EOF
{"listen":"127.0.0.1:${port}","container":"qxdho-dsh","socket":"/nonexistent/docker.sock",
 "password_hash":"${hash}","session_secret":"${secret}","audit_log":""}
EOF

"$BIN" -config "$tmp/config.json" >"$tmp/log" 2>&1 &
pid=$!
base="http://127.0.0.1:${port}"
for _ in $(seq 1 50); do
	curl -fsS -o /dev/null "$base/" 2>/dev/null && break
	sleep 0.1
done

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

[ "$(code "$base/")" = "200" ] && pass "首页 200" || fail "首页不是 200"
curl -s "$base/" | grep -q 'DSH 管理面板' && pass "首页含面板标题" || fail "首页内容不对"

[ "$(code "$base/api/status")" = "401" ] && pass "未登录 /api/status → 401" || fail "未登录应 401"
[ "$(code -X POST -H 'Content-Type: application/json' -d '{"password":"nope"}' "$base/api/login")" = "401" ] \
	&& pass "错误密码 → 401" || fail "错误密码应 401"
[ "$(code -c "$tmp/jar" -X POST -H 'Content-Type: application/json' \
	-d '{"password":"TestPassw0rd!x"}' "$base/api/login")" = "200" ] \
	&& pass "正确密码 → 200 并下发会话" || fail "正确密码登录失败"

[ "$(code -b "$tmp/jar" -X POST "$base/api/restart")" = "400" ] \
	&& pass "已登录但缺 X-DSH-Admin 头 → 400（CSRF 防线）" || fail "CSRF 校验未生效"

c="$(code -b "$tmp/jar" -X POST -H 'X-DSH-Admin: 1' "$base/api/restart")"
[ "$c" = "502" ] && pass "鉴权通过、无 docker socket → 502（说明确实走到 Docker 调用）" \
	|| fail "预期 502，实际 $c"

# 会话是无状态 HMAC：登出靠清除客户端 cookie
logout_hdr="$(curl -s -D - -o /dev/null -b "$tmp/jar" -X POST -H 'X-DSH-Admin: 1' "$base/api/logout")"
case "$logout_hdr" in
*"dsh_admin="*"Max-Age=0"* | *"dsh_admin="*"max-age=0"*) pass "登出清除了会话 cookie" ;;
*) fail "登出未清除 cookie：$logout_hdr" ;;
esac

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
