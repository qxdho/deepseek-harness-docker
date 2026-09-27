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

echo "== A. /workspace 不可写时降级启动（默认行为，不能无限重启）=="
# 默认不是 exit 1：compose 用的是 restart: unless-stopped，非 0 退出会被无限重拉，
# 用户看到的是「docker 一直重启、网页打不开」，比带病运行更糟。默认应降级到
# $DSH_HOME/workspace 继续启动，UI 可用 + 日志里一条醒目横幅。
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
	--tmpfs /workspace:rw,mode=0755 \
	-e DSH_AUTH_USER=admin \
	-e DSH_AUTH_PASSWORD="$LOGIN_PASS" \
	"$IMAGE" >/dev/null

# 判定「没有退出」：给它足够时间跑完启动流程，仍在跑或已 healthy 都算降级成功。
degraded_ok=0
status=starting
for i in $(seq 1 60); do
	if ! docker inspect --format '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true; then
		status="exited($(docker inspect --format '{{.State.ExitCode}}' "$NAME" 2>/dev/null))"
		break
	fi
	status="$(docker inspect --format '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo unknown)"
	[ "$status" = "healthy" ] && {
		degraded_ok=1
		break
	}
	sleep 2
done
if [ "$degraded_ok" = "1" ]; then
	ok "容器未退出，已降级并 healthy"
else
	bad "容器没有降级成功（状态：$status）"
	docker logs "$NAME" 2>&1 | tail -20 || true
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
# 降级必须把「工作区换到哪」讲清楚，否则用户会以为文件写到了宿主目录
case "$logs" in
*"降级"*) ok "日志有降级横幅" ;;
*) bad "日志缺少降级横幅" ;;
esac
# 降级目录建在 $DSH_HOME 下，随 dsh_home 卷持久化
if docker exec "$NAME" test -d /home/node/.dsh/workspace 2>/dev/null; then
	ok "降级目录 \$DSH_HOME/workspace 已创建"
else
	bad "降级目录没有创建"
fi

echo "== A2. DSH_WORKSPACE_STRICT=1 恢复 fail-fast =="
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
	--tmpfs /workspace:rw,mode=0755 \
	-e DSH_WORKSPACE_STRICT=1 \
	-e DSH_AUTH_USER=admin \
	-e DSH_AUTH_PASSWORD="$LOGIN_PASS" \
	"$IMAGE" >/dev/null

code="$(wait_exit)"
if [ "$code" = "1" ]; then
	ok "严格模式下以退出码 1 失败"
else
	bad "严格模式期望退出码 1，实际 $code"
fi
logs="$(docker logs "$NAME" 2>&1 || true)"
case "$logs" in
*"启动 dsh"*) bad "严格模式的报错发生在启动之后，检查位置太晚" ;;
*) ok "严格模式在启动 dsh 之前就退出" ;;
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
