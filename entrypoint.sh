#!/usr/bin/env bash
#
# dsh 容器入口：先拉起 dsh（回环监听），等就绪后启动对外代理。
#
# 与 smanx 实现的差异（都是踩过的坑）：
#   1. 日志用 `tail -F`（--follow=name --retry）而不是 `tail -f`。
#      `-f` 在文件还不存在时会立刻报错退出（smanx 的日志里就留下了
#      "tail: cannot open ... No such file or directory"），导致 dsh 自身
#      日志再也看不到。-F 会等文件出现并自动重试。
#   2. 用 `exec` 让代理成为主进程，信号直接可达，不必手动 trap 转发。
#      dsh 作为子进程，由代理崩溃/退出时一并带走。
set -euo pipefail

DSH_HOST="${DSH_HOST:-127.0.0.1}"
DSH_PORT="${DSH_PORT:-3079}"
PROXY_PORT="${PROXY_PORT:-3080}"
WEB_LOG="${DSH_WEB_LOG:-/tmp/dsh-web.log}"

# dsh 的 /api 信任栅栏只接受回环地址与显式声明的 trustedHosts。
# 因为代理保留原始 Host，浏览器带过来的 authority 必须在这里被信任，
# 否则页面能打开但所有 API 调用都会被 403。
TRUSTED_HOSTS="${DSH_TRUSTED_HOSTS:-}"

# ── 1. 启动 dsh（仅回环）────────────────────────────────────────────────────
# 官方禁止 --host 0.0.0.0；这里保持默认的 127.0.0.1，由代理对外。
set -- web --port "$DSH_PORT" --no-open

if [ -n "$TRUSTED_HOSTS" ]; then
  # 空格分隔的 authority 列表，逐个追加 --trusted-host
  for authority in $TRUSTED_HOSTS; do
    set -- "$@" --trusted-host "$authority"
  done
fi

echo "[dsh] 启动：dsh $*"
dsh "$@" >"$WEB_LOG" 2>&1 &
DSH_PID=$!

# -F: 文件不存在时等待并重试，解决首启竞态
tail -F "$WEB_LOG" 2>/dev/null &
TAIL_PID=$!

cleanup() {
  echo "[dsh] 收到退出信号，停止子进程 ..."
  kill "$DSH_PID" "$TAIL_PID" 2>/dev/null || true
  wait "$DSH_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── 2. 等待 dsh 就绪 ────────────────────────────────────────────────────────
echo "[dsh] 等待就绪 (http://${DSH_HOST}:${DSH_PORT}/) ..."
ready=0
for _ in $(seq 1 120); do
  if node -e "
    fetch('http://${DSH_HOST}:${DSH_PORT}/', { redirect: 'manual' })
      .then(() => process.exit(0))
      .catch(() => process.exit(1));
  " 2>/dev/null; then
    ready=1
    break
  fi
  # dsh 若已退出，立即失败而不是干等 120 秒
  if ! kill -0 "$DSH_PID" 2>/dev/null; then
    echo "[dsh] 错误：dsh 进程已退出，日志尾部：" >&2
    tail -n 30 "$WEB_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done

if [ "$ready" != "1" ]; then
  echo "[dsh] 错误：dsh 120 秒内未就绪，日志尾部：" >&2
  tail -n 30 "$WEB_LOG" >&2 || true
  exit 1
fi
echo "[dsh] dsh 就绪 (pid $DSH_PID)"

# ── 3. 启动代理（前台，成为主进程）──────────────────────────────────────────
echo "[proxy] 启动：0.0.0.0:${PROXY_PORT} -> http://${DSH_HOST}:${DSH_PORT}"
cd /app/proxy
exec node index.js
