#!/usr/bin/env bash
#
# 容器入口。
#
#   1. 保证 $DSH_HOME/profiles/web 存在（空卷 / bind mount 时从镜像内的预置 profile 播种）
#   2. 按环境变量写 dsh-auth-gate 的配置覆盖
#   3. 首次启动时创建管理员账号（密码来自 DSH_AUTH_PASSWORD）
#   4. 启动 dsh（仅回环监听），等就绪
#   5. 前台启动对外代理（Host/Origin 改写为回环 + HTML 注入），自身成为主进程
#
# 登录 / 会话 / TOTP / launch-token 桥接全部由 dsh-auth-gate 在 dsh 进程内完成。
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

: "${DSH_HOME:=/home/node/.dsh}"
: "${DSH_HOST:=127.0.0.1}"
: "${DSH_PORT:=3079}"
: "${PROXY_PORT:=3080}"
: "${DSH_AUTH_USER:=admin}"
: "${DSH_TOTP:=optional}"          # off | optional | required
: "${DSH_COOKIE_SECURE:=0}"        # 通过 HTTPS 访问时设为 1
: "${DSH_PUBLIC_HOST:=}"           # 登录页显示的域名（反代改写 Host 时建议设置）
: "${DSH_CLIENT_IP_HEADER:=x-forwarded-for}"

SEED=/opt/dsh-seed
PROFILE="$DSH_HOME/profiles/web"
WEB_LOG=/tmp/dsh-web.log
WORKSPACE=/workspace

mkdir -p "$DSH_HOME/profiles"

# /workspace 通常是 bind mount，属主由宿主机决定，镜像里的 chown 会被它遮蔽。
# 若宿主目录是 root 创建的（dockerd 自动创建源目录时就会这样），容器里的
# node(1000) 就写不进去。宿主侧由 scripts/preflight.sh 兜底；这里再兜一层。
#
# 关键：检测到不可写时**不能直接 exit 1**。compose 用的是
# restart: unless-stopped，非 0 退出会被无限重拉，用户看到的现象是
# 「docker 一直重启、网页打不开」，比带病运行还糟。所以这里退回到容器内可写的
# 持久目录继续启动，让 UI 先能用，同时用醒目日志暴露宿主工作区不可用。
# 需要旧的 fail-fast 行为时设 DSH_WORKSPACE_STRICT=1。
WORKSPACE_STRICT="${DSH_WORKSPACE_STRICT:-0}"
FALLBACK_WORKSPACE="${DSH_HOME}/workspace"

workspace_ok=0
mkdir -p "$WORKSPACE" 2>/dev/null || true
if ( : >"${WORKSPACE}/.dsh-write-test" ) 2>/dev/null; then
  workspace_ok=1
  rm -f "${WORKSPACE}/.dsh-write-test" 2>/dev/null || true
fi

if [ "$workspace_ok" != "1" ]; then
  ws_owner="$(stat -c '%U:%G (%a)' "$WORKSPACE" 2>/dev/null || echo '未知')"
  log "ERROR: /workspace 不可写（属主 ${ws_owner}，当前用户 $(id -un) $(id -u):$(id -g)）"
  log "        /workspace 是 bind mount，属主由宿主机决定，镜像里的 chown 会被遮蔽。"
  log "        在宿主机上二选一："
  log "          A. sudo chown -R 1000:1000 <宿主机上 DSH_WORKSPACE 指向的目录>"
  log "          B. 换成一个你自己拥有的目录："
  log "             mkdir -p \"\$HOME/dsh-workspace\""
  log "             echo \"DSH_WORKSPACE=\$HOME/dsh-workspace\" >> .env"
  log "             docker compose down && docker compose up -d   # 必须 down+up，restart 不生效"
  if [ "$WORKSPACE_STRICT" = "1" ]; then
    exit 1
  fi
  mkdir -p "$FALLBACK_WORKSPACE"
  if ! ( : >"${FALLBACK_WORKSPACE}/.dsh-write-test" ) 2>/dev/null; then
    rm -f "${FALLBACK_WORKSPACE}/.dsh-write-test" 2>/dev/null || true
    die "退路 ${FALLBACK_WORKSPACE} 也不可写，无法启动（要恢复「不可写就退出」设 DSH_WORKSPACE_STRICT=1）"
  fi
  rm -f "${FALLBACK_WORKSPACE}/.dsh-write-test" 2>/dev/null || true
  log ""
  log "======================================================================"
  log " 工作区降级：宿主 /workspace 不可写，本次改用容器内目录启动"
  log "   ${FALLBACK_WORKSPACE}"
  log " agent 的文件会写在这里（随 dsh_home 持久卷保留），不会出现在"
  log " 宿主机 DSH_WORKSPACE 指向的目录下。"
  log " 按上面的 A 或 B 修好后执行 docker compose down && up -d 即可切回。"
  log "======================================================================"
  log ""
  cd "$FALLBACK_WORKSPACE"
fi

# ── 1. 播种 profile ─────────────────────────────────────────────────────────
if [ ! -f "$PROFILE/package.json" ]; then
  [ -d "$SEED/profiles/web" ] || die "镜像内缺少预置 profile：$SEED/profiles/web"
  log "从镜像播种 web profile（含 dsh-auth-gate）"
  rm -rf "$PROFILE"
  cp -a "$SEED/profiles/web" "$PROFILE"
fi
if [ ! -f "$PROFILE/node_modules/dsh-auth-gate/lib/cli.js" ]; then
  die "profile 里没有 dsh-auth-gate，请重建镜像或执行 dsh plugin --profile web add dsh-auth-gate"
fi

# ── 2. 写插件配置（每次启动按环境变量刷新）──────────────────────────────────
cookie_secure=false
[ "$DSH_COOKIE_SECURE" = "1" ] && cookie_secure=true
case "$DSH_TOTP" in off | optional | required) ;; *) die "DSH_TOTP 只能是 off/optional/required" ;; esac

cat >"$PROFILE/cordis.patch.yml" <<EOF
# 由容器 entrypoint 依据环境变量生成，请改 .env 而不是改这里。
- id: dsh-auth-gate
  config:
    mode: password
    totp: "${DSH_TOTP}"
    cookieSecure: ${cookie_secure}
    clientIpHeader: "${DSH_CLIENT_IP_HEADER}"
    trustedProxyCidrs: ["127.0.0.0/8"]
EOF
if [ -n "$DSH_PUBLIC_HOST" ]; then
  printf '    publicHost: "%s"\n' "$DSH_PUBLIC_HOST" >>"$PROFILE/cordis.patch.yml"
fi

# ── 3. 首次创建管理员 ───────────────────────────────────────────────────────
if [ ! -s "$DSH_HOME/auth/users.yaml" ]; then
  [ -n "${DSH_AUTH_PASSWORD:-}" ] || die "首次启动必须设置 DSH_AUTH_PASSWORD（复制 .env.example 为 .env）"
  log "创建管理员用户 '${DSH_AUTH_USER}'"
  if ! printf '%s\n' "$DSH_AUTH_PASSWORD" \
    | DSH_HOME="$DSH_HOME" node "$PROFILE/node_modules/dsh-auth-gate/lib/cli.js" \
        user add "$DSH_AUTH_USER" --admin --password-stdin; then
    die "创建管理员失败：密码需至少 14 位，且同时包含大写、小写、数字、特殊符号；用户名只能用小写字母/数字等合法字符"
  fi
  chmod 600 "$DSH_HOME/auth/users.yaml" 2>/dev/null || true
else
  log "检测到已有用户文件，跳过创建（改密码：docker exec -it <容器> dsh-auth-user passwd <用户名>）"
fi

# ── 4. 启动 dsh（仅回环）────────────────────────────────────────────────────
: >"$WEB_LOG"
log "启动 dsh: dsh --profile web --host $DSH_HOST --port $DSH_PORT --no-open"
dsh --profile web --host "$DSH_HOST" --port "$DSH_PORT" --no-open >"$WEB_LOG" 2>&1 &
DSH_PID=$!
tail -F "$WEB_LOG" >&2 &
TAIL_PID=$!

cleanup() {
  log "退出中，停止子进程"
  # 代理是最后启动的，先停它，避免它继续对外转发一个正在关闭的后端。
  [ -n "${PROXY_PID:-}" ] && kill "$PROXY_PID" 2>/dev/null || true
  kill "$DSH_PID" "$TAIL_PID" 2>/dev/null || true
  wait "$DSH_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "等待 dsh 就绪…"
for i in $(seq 1 180); do
  if ! kill -0 "$DSH_PID" 2>/dev/null; then
    log "dsh 已退出，日志尾部："
    tail -n 30 "$WEB_LOG" >&2 || true
    exit 1
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://${DSH_HOST}:${DSH_PORT}/" || true)"
  case "$code" in 200 | 302 | 401) break ;; esac
  if [ "$i" = "180" ]; then
    log "dsh 180 秒内未就绪，日志尾部："
    tail -n 30 "$WEB_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done

# 记录一次性 launch URL（排障 / 原生模式用；正常访问由插件自动桥接，无需手贴）
grep -oE "http://${DSH_HOST}:[0-9]+/\?token=[A-Za-z0-9_-]+" "$WEB_LOG" | head -n1 \
  >"$DSH_HOME/web-launch-url.txt" 2>/dev/null || true
chmod 600 "$DSH_HOME/web-launch-url.txt" 2>/dev/null || true

# ── 5. 前台启动代理 ─────────────────────────────────────────────────────────
#
# 这里**故意不用 exec**。用 exec 的话 shell 被 node 取代，上面注册的 cleanup trap
# 随之失效：docker stop 发的 SIGTERM 只会到达代理进程，而它不管 dsh 子进程，
# 于是 dsh 变成孤儿，stop 要熬满 stop_grace_period(20s) 再被 SIGKILL。
#
# 保持 shell 作为监督者：tini(PID 1) 把 SIGTERM 转发给本脚本 → trap 命中 →
# 一次性收掉 dsh、tail 和代理。用 `wait` 常驻并返回代理的退出码。
log "启动代理: 0.0.0.0:${PROXY_PORT} -> http://${DSH_HOST}:${DSH_PORT}"
cd /app/proxy
node index.js &
PROXY_PID=$!
wait "$PROXY_PID"
