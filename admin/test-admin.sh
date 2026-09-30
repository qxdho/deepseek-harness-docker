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

# 命令台：用一个假的 dshm 验证「拆参数 → 直接 exec」，不碰真实 docker
proj="$tmp/proj"
mkdir -p "$proj"
cat >"$proj/dshm" <<'STUB'
#!/usr/bin/env bash
echo "ARGS:$*"
STUB
chmod +x "$proj/dshm"

cat >"$tmp/config.json" <<EOF
{"listen":"127.0.0.1:${port}","container":"qxdho-dsh","socket":"/nonexistent/docker.sock",
 "password_hash":"${hash}","session_secret":"${secret}","audit_log":"",
 "project_dir":"${proj}","compose_project":"demo","allow_exec":true}
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

[ "$(code -b "$tmp/jar" -X POST "$base/api/restart")" = "403" ] \
	&& pass "已登录但缺 X-DSH-Admin 头 → 403（CSRF 防线）" || fail "CSRF 校验未生效"

# 启停必须交给 dshm，而不是面板自己调 Docker。
#
# 以前这里断言「无 docker socket → 502（说明确实走到 Docker 调用）」。但那条契约
# 本身就是坏的：面板直连 Docker 会绕过 dshm 的启动前预检，改了 .env 之后点「重启」
# 看着成功、实际毫无变化（见 DESIGN.md 第 9 节）。现在面板一律调 dshm，于是：
#   * socket 指向不存在也无所谓 —— 面板根本不碰它
#   * 断言换成「假 dshm 真的收到了 service restart」以及「dshm 失败时面板不装成功」
out="$(curl -s -b "$tmp/jar" -X POST -H 'X-DSH-Admin: 1' "$base/api/restart")"
case "$out" in
*"ARGS:service restart"*) pass "重启已委托给 dshm（拿到 service restart）" ;;
*) fail "重启没有走 dshm：$out" ;;
esac

# dshm 失败时面板必须报错，不能假装成功
cat >"$proj/dshm" <<'STUB'
#!/usr/bin/env bash
echo "dshm 失败了" >&2
exit 1
STUB
chmod +x "$proj/dshm"
c="$(code -b "$tmp/jar" -X POST -H 'X-DSH-Admin: 1' "$base/api/restart")"
[ "$c" = "502" ] && pass "dshm 退出码非 0 → 502（不假装成功）" || fail "dshm 失败时应 502，实际 $c"

# 还原可用桩：后面的命令台用例还要用它
cat >"$proj/dshm" <<'STUB'
#!/usr/bin/env bash
echo "ARGS:$*"
STUB
chmod +x "$proj/dshm"

# ── 命令台 ──────────────────────────────────────────────────────────────────
[ "$(code -b "$tmp/jar" "$base/api/commands")" = "200" ] \
	&& pass "/api/commands 200" || fail "/api/commands 异常"

exec_line() {
	curl -s -b "$tmp/jar" -X POST -H 'X-DSH-Admin: 1' -H 'Content-Type: application/json' \
		-d "{\"line\":\"$1\"}" "$base/api/exec"
}
out="$(exec_line 'service status')"
case "$out" in
*"ARGS:service status"*) pass "命令台按白名单执行 dshm（参数原样传递）" ;;
*) fail "命令台输出异常：$out" ;;
esac
out="$(exec_line 'dshm version update 0.1.8')"
case "$out" in
*"ARGS:version update 0.1.8"*) pass "带 dshm 前缀与参数也能执行" ;;
*) fail "带前缀执行异常：$out" ;;
esac
[ "$(code -b "$tmp/jar" -X POST -H 'X-DSH-Admin: 1' -H 'Content-Type: application/json' \
	-d '{"line":"rm -rf /"}' "$base/api/exec")" = "400" ] \
	&& pass "非白名单命令被拒（400）" || fail "非白名单命令未被拒"
[ "$(code -b "$tmp/jar" -X POST -H 'X-DSH-Admin: 1' -H 'Content-Type: application/json' \
	-d '{"line":"service status; id"}' "$base/api/exec")" = "400" ] \
	&& pass "分号不会变成命令分隔符（400）" || fail "注入未被拒"
[ "$(code -b "$tmp/jar" -X POST -H 'X-DSH-Admin: 1' -H 'Content-Type: application/json' \
	-d '{"line":"auth password"}' "$base/api/exec")" = "400" ] \
	&& pass "交互命令被拒（400）" || fail "交互命令未被拒"

# 会话是无状态 HMAC：登出靠清除客户端 cookie
logout_hdr="$(curl -s -D - -o /dev/null -b "$tmp/jar" -X POST -H 'X-DSH-Admin: 1' "$base/api/logout")"
case "$logout_hdr" in
*"dsh_admin="*"Max-Age=0"* | *"dsh_admin="*"max-age=0"*) pass "登出清除了会话 cookie" ;;
*) fail "登出未清除 cookie：$logout_hdr" ;;
esac

# ── config.json 生成：路径里的 " 和 \ 必须转义 ───────────────────────────────
# admin_write_config 在 scripts/admin.sh 里，由 install.sh/dshm 调用；这里直接
# source 它，用当前构建出的二进制算哈希，验证生成的 JSON 面板能读进去。
weird="$tmp/we\"ird\\dir"
mkdir -p "$weird" "$tmp/adm2"
cfg2="$tmp/config2.json"
env2="$tmp/env2"
cfg2_port=$((port + 1))
(
	cd "$HERE/.."
	export ENV_FILE="$env2"
	printf 'DSH_ADMIN_DIR=%s\n' "$tmp/adm2" >"$env2"
	B= DIM= GRN= RED= YEL= RST=
	hdr() { :; }
	ok() { :; }
	warn() { :; }
	info() { :; }
	die() {
		echo "$*" >&2
		exit 1
	}
	# shellcheck source=scripts/env-config.sh
	. ./scripts/env-config.sh
	# shellcheck source=scripts/admin.sh
	. ./scripts/admin.sh
	ADMIN_BIN_PATH="$BIN"
	SECRET='TestPassw0rd!x'
	PROJECT_DIR="$weird"
	admin_write_config "$cfg2" "127.0.0.1:${cfg2_port}" /nonexistent/docker.sock qxdho-dsh "$weird" demo
) || fail "admin_write_config 执行失败"

if [ -s "$cfg2" ]; then
	pass "生成了 config.json"
else
	fail "没有生成 config.json"
fi
case "$(cat "$cfg2" 2>/dev/null)" in
*'we\"ird'*) pass "路径里的引号已转义" ;;
*) fail "引号未转义：$(cat "$cfg2" 2>/dev/null)" ;;
esac

# 转义正确的最终证据：面板能把它解析起来并正常响应（解析失败会直接退出）
"$BIN" -config "$cfg2" >"$tmp/cfg2.log" 2>&1 &
cfg2_pid=$!
cfg2_up=0
for _ in $(seq 1 50); do
	curl -fsS -o /dev/null "http://127.0.0.1:${cfg2_port}/" 2>/dev/null && {
		cfg2_up=1
		break
	}
	sleep 0.1
done
kill "$cfg2_pid" 2>/dev/null || true
wait "$cfg2_pid" 2>/dev/null || true
if [ "$cfg2_up" = "1" ]; then
	pass "含引号/反斜杠路径的 config.json 可被面板解析并服务"
else
	fail "面板未能用生成的 config.json 起来：$(cat "$tmp/cfg2.log")"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
