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

mkdir -p "$DSH_HOME/profiles" /workspace

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
  printf '%s\n' "$DSH_AUTH_PASSWORD" \
    | DSH_HOME="$DSH_HOME" node "$PROFILE/node_modules/dsh-auth-gate/lib/cli.js" \
        user add "$DSH_AUTH_USER" --admin --password-stdin
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
  kill "$DSH_PID" "$TAIL_PID" 2>/dev/null || true
  wait "$DSH_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "等待 dsh 就绪（首次启动可能要 1-2 分钟）..."
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
log "启动代理: 0.0.0.0:${PROXY_PORT} -> http://${DSH_HOST}:${DSH_PORT}"
cd /app/proxy
exec node index.js
