#!/usr/bin/env bash
#
# dsh-docker v2 容器入口。
#
#   1. 检查数据目录 / 工作区是否可写
#   2. 需要时从镜像播种 web profile（含 dsh-web-startup-auth）
#   3. 启动前预置管理员账号（$DSH_HOME/web-auth.json）
#   4. 直接启动 dsh，监听 0.0.0.0:3080（由 dsh-web-startup-auth 替换 startup）
#
# 登录、会话、API/WebSocket 门禁全部由 dsh-web-startup-auth 在 dsh 进程内完成。
set -euo pipefail

umask 0022

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

: "${DSH_HOME:=/dsh}"
: "${DSH_HOST:=0.0.0.0}"
: "${DSH_PORT:=3080}"
: "${DSH_AUTH_USER:=admin}"
: "${DSH_COOKIE_SECURE:=0}"
: "${DSH_PUBLIC_HOST:=}"

SEED=/opt/dsh-seed
PROFILE="$DSH_HOME/profiles/web"
WORKSPACE="${DSH_WORKSPACE_CONTAINER:-/workspace}"
HOST_HINT="${DSH_HOME_HOST:-<DSH_HOME_HOST>}"

# ── 0. 基本目录 ────────────────────────────────────────────────────────────
if ! mkdir -p "$DSH_HOME/profiles" 2>/dev/null; then
  owner="$(stat -c '%U:%G (%a)' "$DSH_HOME" 2>/dev/null || echo '未知')"
  log "ERROR: 数据目录 ${DSH_HOME} 不可写（属主 ${owner}，当前用户 $(id -un) $(id -u):$(id -g)）"
  log "        它是 bind mount，属主由宿主机决定。在宿主机执行："
  log "          sudo chown -R $(id -u):$(id -g) ${HOST_HINT}"
  exit 1
fi

rm -rf /tmp/npm-cache 2>/dev/null || true
mkdir -p /tmp/npm-cache 2>/dev/null || true

# 磁盘余量预检：插件/NPM 缓存写满后 dsh 会 ENOSPC 崩溃，表象很难定位。
DISK_MIN_MB="${DSH_DISK_MIN_MB:-256}"
disk_free_mb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4 / 1024)}'; }
for mount in "$DSH_HOME" "$WORKSPACE"; do
  free_mb="$(disk_free_mb "$mount" 2>/dev/null || true)"
  case "$free_mb" in '' | *[!0-9]*) continue ;; esac
  if [ "$free_mb" -lt "$DISK_MIN_MB" ]; then
    log "ERROR: $mount 所在磁盘仅剩 ${free_mb}MB（阈值 ${DISK_MIN_MB}MB）"
    log "        清理：docker exec <容器> du -xh ${DSH_HOME} --max-depth=2 | sort -h | tail -15"
    exit 1
  fi
done

# ── 1. 工作区 ──────────────────────────────────────────────────────────────
# 工作区不可写时降级到数据目录下的 .workspace，避免 restart 策略无限重拉。
WORKSPACE_STRICT="${DSH_WORKSPACE_STRICT:-0}"
FALLBACK_WORKSPACE="${DSH_HOME}/.workspace"
workspace_ok=0
mkdir -p "$WORKSPACE" 2>/dev/null || true
if ( : >"${WORKSPACE}/.dsh-write-test" ) 2>/dev/null; then
  workspace_ok=1
  rm -f "${WORKSPACE}/.dsh-write-test" 2>/dev/null || true
fi
if [ "$workspace_ok" != "1" ]; then
  owner="$(stat -c '%U:%G (%a)' "$WORKSPACE" 2>/dev/null || echo '未知')"
  log "ERROR: 工作区 ${WORKSPACE} 不可写（属主 ${owner}，当前用户 $(id -un) $(id -u):$(id -g)）"
  log "        在宿主机执行：sudo chown -R $(id -u):$(id -g) <DSH_WORKSPACE_HOST>"
  if [ "$WORKSPACE_STRICT" = "1" ]; then exit 1; fi
  mkdir -p "$FALLBACK_WORKSPACE"
  if ! ( : >"${FALLBACK_WORKSPACE}/.dsh-write-test" ) 2>/dev/null; then
    die "退路 ${FALLBACK_WORKSPACE} 也不可写"
  fi
  rm -f "${FALLBACK_WORKSPACE}/.dsh-write-test" 2>/dev/null || true
  log "工作区降级：改用 ${FALLBACK_WORKSPACE}"
  cd "$FALLBACK_WORKSPACE"
  WORKSPACE="$FALLBACK_WORKSPACE"
fi

: "${HOME:=/workspace}"
if ! mkdir -p "$HOME" 2>/dev/null; then
  log "警告：HOME=$HOME 不可写；目录选择器和插件缓存可能异常"
fi

# ── 2. 播种 profile ────────────────────────────────────────────────────────
# v1 的 profile 带 dsh-auth-gate，会和 v2 的 startup 插件冲突：备份后重播。
if [ -f "$PROFILE/package.json" ] && grep -q 'dsh-auth-gate' "$PROFILE/package.json"; then
  backup="${PROFILE}.v1-backup-$(date -u +%Y%m%dT%H%M%SZ)"
  log "检测到 v1 登录插件 profile，备份到 ${backup} 后重播 v2 profile"
  mv "$PROFILE" "$backup"
fi

if [ ! -f "$PROFILE/package.json" ]; then
  [ -d "$SEED/profiles/web" ] || die "镜像内缺少预置 profile：$SEED/profiles/web"
  log "从镜像播种 web profile（dsh-web-startup-auth）"
  tmp="${PROFILE}.seeding.$$"
  rm -rf "$tmp"
  if ! cp -a "$SEED/profiles/web" "$tmp"; then
    rm -rf "$tmp"
    die "播种 profile 失败（磁盘满？）"
  fi
  if [ ! -f "$tmp/node_modules/dsh-web-startup-auth/lib/auth.js" ]; then
    rm -rf "$tmp"
    die "播种出来的 profile 缺少 dsh-web-startup-auth"
  fi
  rm -rf "$PROFILE"
  mv "$tmp" "$PROFILE" || { rm -rf "$tmp"; die "profile 落位失败"; }
fi

if [ ! -f "$PROFILE/node_modules/dsh-web-startup-auth/lib/auth.js" ]; then
  die "profile 里没有 dsh-web-startup-auth，请重建镜像"
fi

# dsh 首次登录默认在 <Documents>/deepseek-harness 建工作区；容器里没有 Documents。
# 给 workspace-controller 显式指定挂载点，避免“无法创建默认工作区”。
ensure_workspace_config() {
  local patch="$PROFILE/cordis.patch.yml"
  if grep -q 'documentsDirectory' "$patch" 2>/dev/null; then
    return 0
  fi
  if [ -f "$patch" ]; then
    sed -i '/^\[\]$/d' "$patch"
    printf '\n- id: workspace-controller\n  config:\n    documentsDirectory: "%s"\n' "$WORKSPACE" >>"$patch"
  else
    printf -- '- id: workspace-controller\n  config:\n    documentsDirectory: "%s"\n' "$WORKSPACE" >"$patch"
  fi
  log "配置默认工作区：$WORKSPACE"
}
ensure_workspace_config

# pnpm 构建期记录的 store 绝对路径进入数据卷后必然失配。
rm -f "$PROFILE/node_modules/.modules.yaml"

# ── 3. 预置管理员 ──────────────────────────────────────────────────────────
# 必须在 dsh 启动前完成，否则远程第一个访问者可以注册成管理员。
if [ ! -s "$DSH_HOME/web-auth.json" ]; then
  [ -n "${DSH_AUTH_PASSWORD:-}" ] || die "首次启动必须设置 DSH_AUTH_PASSWORD"
  log "预置管理员账号 '${DSH_AUTH_USER}'"
  node /app/scripts/seed-auth.mjs || die "预置管理员失败（密码至少 14 位）"
else
  log "检测到已有 web-auth.json，跳过管理员预置"
fi

# ── 4. 启动 dsh ────────────────────────────────────────────────────────────
case "${DSH_AUTH_TOTP:-off}" in
off | optional) ;;
required) die "v2 的 dsh-web-startup-auth 不支持 TOTP；请把 DSH_AUTH_TOTP 改为 off/optional 或保留 v1" ;;
*) die "DSH_AUTH_TOTP 只能是 off/optional/required" ;;
esac

args=(web --host "$DSH_HOST" --port "$DSH_PORT" --no-open)
if [ -n "$DSH_PUBLIC_HOST" ]; then
  scheme=http
  [ "$DSH_COOKIE_SECURE" = "1" ] && scheme=https
  args+=(--trusted-host "$DSH_PUBLIC_HOST" --public-url "${scheme}://${DSH_PUBLIC_HOST}/")
  log "对外地址：${scheme}://${DSH_PUBLIC_HOST}/（HTTPS 反代请给 Cookie 补 Secure）"
fi

log "启动 dsh: ${DSH_HOST}:${DSH_PORT}"
exec dsh "${args[@]}"
