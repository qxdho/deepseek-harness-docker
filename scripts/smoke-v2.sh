#!/usr/bin/env bash
# v2 镜像冒烟：dsh + dsh-web-startup-auth，无代理。
#
#   ./scripts/smoke-v2.sh <镜像名>
set -euo pipefail

IMAGE="${1:-dsh-v2:smoke}"
NAME="dsh-v2-smoke-$$"
PORT="${SMOKE_PORT:-18082}"
USER_NAME="admin"
PASSWORD='SmokePass-1234!'
HOST_NAME="smoke.local"
. "$(dirname "$0")/test-lib.sh"

jar="$(mktemp)"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -f "$jar"; }
trap cleanup EXIT

echo "== 启动 v2 容器 =="
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
	-p "127.0.0.1:${PORT}:3080" \
	-e DSH_AUTH_USER="$USER_NAME" \
	-e DSH_AUTH_PASSWORD="$PASSWORD" \
	-e DSH_PUBLIC_HOST="$HOST_NAME" \
	-e DSH_AUTH_TOTP=off \
	"$IMAGE" >/dev/null

echo "== 等 healthy =="
status=starting
for i in $(seq 1 180); do
	status="$(docker inspect --format '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo unknown)"
	[ "$status" = "healthy" ] && break
	if [ "$i" = "60" ]; then
		docker logs "$NAME" 2>&1 | tail -60 || true
		bad "容器未 healthy（当前：$status）"
		run_tests
		exit 1
	fi
	sleep 1
done
ok "容器 healthy"

BASE="http://127.0.0.1:${PORT}"

echo "== 登录入口 =="
code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/login" || true)"
[ "$code" = "200" ] && ok "/login = 200" || bad "/login 期望 200，实际 $code"

echo "== 未登录拦截 =="
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${HOST_NAME}" -H 'Sec-Fetch-Mode: navigate' "$BASE/" || true)"
case "$code" in 302 | 303) ok "外部 Host 未登录 / = $code" ;; *) bad "外部 Host 未登录 / 期望 302/303，实际 $code" ;; esac

# 登录页之外的受保护 API：未登录不能返回 200。
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${HOST_NAME}" "$BASE/api/session/list" || true)"
case "$code" in 401 | 403 | 302 | 303) ok "未登录受保护 API = $code" ;; *) bad "未登录受保护 API 期望 401/403/302，实际 $code" ;; esac

echo "== 预置账号登录 =="
code="$(curl -s -c "$jar" -o /dev/null -w '%{http_code}' \
	-H "Host: ${HOST_NAME}" -H 'Content-Type: application/json' \
	--data "{\"username\":\"${USER_NAME}\",\"password\":\"${PASSWORD}\"}" \
	"$BASE/api/auth/login" || true)"
[ "$code" = "200" ] && ok "登录 = 200" || bad "登录期望 200，实际 $code"

code="$(curl -s -b "$jar" -o /dev/null -w '%{http_code}' -H "Host: ${HOST_NAME}" "$BASE/api/auth/status" || true)"
[ "$code" = "200" ] && ok "登录后 status = 200" || bad "登录后 status 期望 200，实际 $code"

echo "== 账号文件与插件 =="
docker exec "$NAME" sh -c 'test -s "${DSH_HOME:-/home/node/.dsh}/web-auth.json"' && ok "web-auth.json 已生成" || bad "缺少 web-auth.json"
docker exec "$NAME" sh -c 'test -f "${DSH_HOME:-/home/node/.dsh}/profiles/web/node_modules/dsh-web-startup-auth/lib/auth.js"' \
	&& ok "dsh-web-startup-auth 已进 profile" || bad "profile 缺少 dsh-web-startup-auth"
if docker logs "$NAME" 2>&1 | grep -q 'TypeError\|did not activate'; then
	bad "日志里仍有插件加载错误"
else
	ok "日志无 TypeError / did not activate"
fi

echo "== 重启后账号保留 =="
docker restart "$NAME" >/dev/null
for i in $(seq 1 120); do
	code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/login" 2>/dev/null || true)"
	[ "$code" = "200" ] && break
	sleep 1
done
code="$(curl -s -c "$jar" -o /dev/null -w '%{http_code}' \
	-H "Host: ${HOST_NAME}" -H 'Content-Type: application/json' \
	--data "{\"username\":\"${USER_NAME}\",\"password\":\"${PASSWORD}\"}" \
	"$BASE/api/auth/login" || true)"
[ "$code" = "200" ] && ok "重启后仍可登录" || bad "重启后登录失败（HTTP $code）"

if [ "$FAIL" != "0" ]; then
	echo
	echo "== 失败诊断：容器日志（末 100 行）=="
	docker logs "$NAME" 2>&1 | tail -100 || true
fi

run_tests
