#!/usr/bin/env bash
# 冒烟测试：在 Docker 主机（或 CI runner）上真实起容器，验证登录闭环。
#
#   ./scripts/smoke-test.sh <镜像名>         例如 dsh-test:smoke
#   ./scripts/smoke-test.sh                  默认本地构建 dsh-test:smoke
set -euo pipefail

IMAGE="${1:-dsh-test:smoke}"
NAME="dsh-smoke-$$"
PORT="${SMOKE_PORT:-18080}"
LOGIN_USER="admin"
LOGIN_PASS='SmokePass-1234!'
. "$(dirname "$0")/test-lib.sh"

jar="$(mktemp)"; page="$(mktemp)"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -f "$jar" "$page"; }
trap cleanup EXIT

if [ "$IMAGE" = "dsh-test:smoke" ]; then
	echo "== 本地构建 $IMAGE =="
	docker build -t "$IMAGE" .
fi

echo "== 启动容器 =="
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
	-p "127.0.0.1:${PORT}:3080" \
	-e DSH_AUTH_USER="$LOGIN_USER" \
	-e DSH_AUTH_PASSWORD="$LOGIN_PASS" \
	-e DSH_AUTH_TOTP=off \
	"$IMAGE" >/dev/null

echo "== 等健康 =="
status=starting
for i in $(seq 1 72); do
	status="$(docker inspect --format '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo unknown)"
	[ "$status" = "healthy" ] && break
	if [ "$i" = "72" ]; then
		docker logs "$NAME" 2>&1 | tail -50 || true
		echo "容器未 healthy（当前：$status）"
		exit 1
	fi
	sleep 5
done
ok "容器 healthy"

BASE="http://127.0.0.1:${PORT}"

echo "== 未登录行为 =="
code="$(curl -s -H 'Accept: text/html' -o /dev/null -w '%{http_code}' "$BASE/")"
[ "$code" = "302" ] && ok "GET / -> 302" || bad "GET / 期望 302，实际 $code"

loc="$(curl -s -H 'Accept: text/html' -D - -o /dev/null "$BASE/" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')"
case "$loc" in *"/auth/login"*) ok "未登录跳转登录页（$loc）" ;; *) bad "未跳转登录页：$loc" ;; esac

code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/auth/login")"
[ "$code" = "200" ] && ok "登录页返回 200" || bad "登录页期望 200，实际 $code"

echo "== 登录闭环（含 launch token 自动桥接）=="
code="$(curl -s -L -c "$jar" -b "$jar" -H 'Accept: text/html' -o "$page" -w '%{http_code}' \
	--data-urlencode "username=$LOGIN_USER" --data-urlencode "password=$LOGIN_PASS" \
	"$BASE/auth/login")"
[ "$code" = "200" ] && ok "登录并跟随跳转后 200" || bad "登录后期望 200，实际 $code"
grep -q '__DSH_BOOT__' "$page" && ok "拿到 dsh 应用页面" || bad "页面不含 __DSH_BOOT__"
grep -q 'dsh-forward-inject' "$page" && ok "代理注入生效（randomUUID/ownsHost）" || bad "未发现代理注入"

echo "== 会话保持 =="
code="$(curl -s -b "$jar" -H 'Accept: text/html' -o /dev/null -w '%{http_code}' "$BASE/")"
[ "$code" = "200" ] && ok "带会话再访问 200" || bad "带会话期望 200，实际 $code"

echo "== 未认证 API 被拒 =="
code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data '{}' "$BASE/api/nonexistent")"
case "$code" in 401 | 403 | 404) ok "未认证 POST /api -> $code" ;; *) bad "未认证 /api 异常：$code" ;; esac

echo "== 响应头合法性（严格中间代理要求）=="
# Nginx 等严格代理会拒绝同时带 Content-Length 与 Transfer-Encoding 的响应（502）。
# curl 对此宽容，所以这里用裸 socket 检查，防止回归。
if docker exec "$NAME" node -e '
const net = require("net");
const s = net.connect(3080, "127.0.0.1", () => {
  s.write("GET /auth/login HTTP/1.1\r\nHost: smoke.local\r\nConnection: close\r\n\r\n");
});
let buf = "";
s.on("data", (d) => (buf += d));
s.on("end", () => {
  const head = buf.split("\r\n\r\n")[0].toLowerCase();
  const cl = /^content-length:/m.test(head);
  const te = /^transfer-encoding:/m.test(head);
  if (cl && te) {
    console.error("both content-length and transfer-encoding present");
    process.exit(1);
  }
  console.log("headers ok (content-length=" + cl + ", transfer-encoding=" + te + ")");
});
s.on("error", (e) => { console.error(e.message); process.exit(1); });
'; then
	ok "登录页响应头合法（没有同时带 Content-Length 和 Transfer-Encoding）"
else
	bad "登录页响应头同时带 Content-Length 和 Transfer-Encoding（Nginx 会 502）"
fi

# 工作区权限回归：默认 `docker run` 容器里 /workspace 是 root 属主，只读。
# 这正是宿主上「bind mount 源目录被 dockerd 以 root 自动创建」时的状态，
# 由独立的 smoke-workspace.sh 检查（它需要自己控制挂载方式）。
if [ -x "$(dirname "$0")/smoke-workspace.sh" ]; then
	echo
	echo "== 工作区权限回归 =="
	if "$(dirname "$0")/smoke-workspace.sh" "$IMAGE"; then
		ok "工作区权限回归通过"
	else
		bad "工作区权限回归失败"
	fi
fi

# pnpm store 记账回归：镜像不能烤进 storeDir 记录，否则用户第一次装插件必然报
# ERR_PNPM_UNEXPECTED_STORE。此前没有任何测试覆盖「装插件」这条路径，所以这个
# bug 溜进了发布镜像。
if [ -x "$(dirname "$0")/smoke-plugin.sh" ]; then
	echo
	echo "== 插件安装回归 =="
	if "$(dirname "$0")/smoke-plugin.sh" "$IMAGE"; then
		ok "插件安装回归通过"
	else
		bad "插件安装回归失败"
	fi
fi

echo
run_tests
