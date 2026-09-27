#!/usr/bin/env bash
# 工作区权限回归测试（需要 docker，会被 CI 与 smoke-test.sh 调用）。
#
#   ./scripts/smoke-workspace.sh <镜像名>     例如 dsh-test:smoke
#
# 复现并验证当初漏测的那条路径：
#   宿主 /workspace 目录属主是 root（dockerd 自动创建 bind mount 源目录时的
#   真实状态）→ 容器里的 node(1000) 写不进去 → agent 报
#   `EACCES: permission denied, mkdir '/workspace/xxx'`。
#
# 这里用 `--tmpfs /workspace:mode=0755` 而不是 chmod 宿主目录：tmpfs 的根属主
# 一定是 root，所以无论测试脚本自己是不是 root（CI 里就是）都能造出「非 root
# 用户不可写」的状态 —— 用 chmod 的话 root 会绕过权限位，测试会假通过。
set -euo pipefail

IMAGE="${1:-dsh-test:smoke}"
NAME="dsh-ws-$$"
LOGIN_PASS='SmokePass-1234!'
PASS=0
FAIL=0

ok() { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

cleanup() {
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	docker volume rm dsh-ws-smoke-vol >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_exit() {
	# 等容器进入 exited（最多 ~30s），打印退出码
	local i
	for i in $(seq 1 30); do
		if ! docker inspect --format '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true; then
			docker inspect --format '{{.State.ExitCode}}' "$NAME"
			return 0
		fi
		sleep 1
	done
	echo "still-running"
}

echo "== A. /workspace 不可写时必须明确报错退出（而不是静默带病启动）=="
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
	--tmpfs /workspace:rw,mode=0755 \
	-e DSH_AUTH_USER=admin \
	-e DSH_AUTH_PASSWORD="$LOGIN_PASS" \
	"$IMAGE" >/dev/null

code="$(wait_exit)"
if [ "$code" = "1" ]; then
	ok "容器以退出码 1 失败（快速失败生效）"
else
	bad "期望退出码 1，实际 $code"
fi

logs="$(docker logs "$NAME" 2>&1 || true)"
case "$logs" in
*"不可写"*) ok "日志给出「不可写」诊断" ;;
*) bad "日志缺少诊断信息" ;;
esac
case "$logs" in
*chown*) ok "日志含 chown 修复提示" ;;
*) bad "日志缺少 chown 提示" ;;
esac
case "$logs" in
*DSH_WORKSPACE*) ok "日志含「换个目录」替代方案" ;;
*) bad "日志缺少替代方案" ;;
esac
# 关键：不能等到 agent 干活时才失败。报错必须发生在启动早期。
case "$logs" in
*"启动 dsh"*) bad "报错发生在启动之后，说明检查位置太晚" ;;
*) ok "报错发生在启动 dsh 之前" ;;
esac

echo "== B. /workspace 可写时正常启动并真的能写 =="
# 命名卷会由 Docker 用镜像内 /workspace 的属主初始化 —— 正是生产环境里
# 「用户自己建好目录」的那条正常路径。
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
	-v dsh-ws-smoke-vol:/workspace \
	-e DSH_AUTH_USER=admin \
	-e DSH_AUTH_PASSWORD="$LOGIN_PASS" \
	"$IMAGE" >/dev/null

status=starting
for i in $(seq 1 72); do
	status="$(docker inspect --format '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo unknown)"
	[ "$status" = "healthy" ] && break
	if [ "$i" = "72" ]; then
		docker logs "$NAME" 2>&1 | tail -30 || true
		bad "容器未 healthy（当前：$status）"
	fi
	sleep 5
done
[ "$status" = "healthy" ] && ok "可写工作区下容器 healthy"

if docker exec "$NAME" sh -c 'mkdir -p /workspace/sub && echo hi > /workspace/sub/f && cat /workspace/sub/f' >/dev/null 2>&1; then
	ok "容器内 node 用户能在 /workspace 建目录并写入"
else
	bad "容器内 node 用户无法写入 /workspace"
	docker exec "$NAME" id 2>&1 || true
fi

# 探测用的临时文件不应残留
if docker exec "$NAME" test -e /workspace/.dsh-write-test 2>/dev/null; then
	bad "entrypoint 的探测文件残留在 /workspace"
else
	ok "探测文件已清理"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
