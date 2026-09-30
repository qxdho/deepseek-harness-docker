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

: "${DSH_HOME:=/dsh}"
: "${DSH_HOST:=127.0.0.1}"
: "${DSH_PORT:=3079}"
: "${PROXY_PORT:=3080}"
: "${DSH_AUTH_USER:=admin}"
: "${DSH_AUTH_TOTP:=optional}"          # off | optional | required
: "${DSH_COOKIE_SECURE:=0}"        # 通过 HTTPS 访问时设为 1
: "${DSH_PUBLIC_HOST:=}"           # 登录页显示的域名（反代改写 Host 时建议设置）
: "${DSH_CLIENT_IP_HEADER:=x-forwarded-for}"

SEED=/opt/dsh-seed
PROFILE="$DSH_HOME/profiles/web"
WEB_LOG=/tmp/dsh-web.log
WORKSPACE="${DSH_WORKSPACE_CONTAINER:-/workspace}"

# 数据目录通常也是 bind mount：宿主上由 dockerd 以 root 自动创建、或部署者用 root
# 跑过的话，容器内的 uid 连 profiles 都建不出来。这里给一条能直接照做的诊断，
# 而不是丢一句 `mkdir: Permission denied`（病因在宿主机属主，报错点却在容器里）。
if ! mkdir -p "$DSH_HOME/profiles" 2>/dev/null; then
  ws_owner="$(stat -c '%U:%G (%a)' "$DSH_HOME" 2>/dev/null || echo '未知')"
  log "ERROR: 数据目录 ${DSH_HOME} 不可写（属主 ${ws_owner}，当前用户 $(id -un) $(id -u):$(id -g)）"
  log "        它是 bind mount，属主由宿主机决定。在宿主机上二选一："
  log "          A. sudo mkdir -p <DSH_HOME_HOST> && sudo chown -R $(id -u):$(id -g) <DSH_HOME_HOST>"
  log "          B. 把 .env 的 DSH_HOME_HOST / DSH_WORKSPACE_HOST 换到你自己的目录，再 ./dshm service up"
  exit 1
fi

# 插件安装的 npm 缓存落在 /tmp/npm-cache（见 Dockerfile），不写进持久卷；每次启动
# 清掉，重启即可回收这部分空间，也避免缓存无限增长把磁盘写满。
rm -rf /tmp/npm-cache 2>/dev/null || true

# ── 磁盘空间预检 ────────────────────────────────────────────────────────────
# 装插件会把依赖写进 profile/node_modules、把 npm 缓存写进 $HOME/.npm，很容易把
# 卷/磁盘塞满。满了之后的表象是 ENOSPC、dsh 起来又退出、代理只刷 ECONNREFUSED，
# 离病因十万八千里。这里提前报出来并给出清理命令。
DISK_MIN_MB="${DSH_DISK_MIN_MB:-256}"
disk_free_mb() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4 / 1024)}'
}
for mount in "$DSH_HOME" "$WORKSPACE"; do
  free_mb="$(disk_free_mb "$mount" 2>/dev/null || true)"
  case "$free_mb" in '' | *[!0-9]*) continue ;; esac
  if [ "$free_mb" -lt "$DISK_MIN_MB" ]; then
    log "ERROR: $mount 所在磁盘仅剩 ${free_mb}MB（阈值 ${DISK_MIN_MB}MB）"
    log "        装插件 / npm 缓存写满磁盘后，会 ENOSPC，dsh 起来又退出、代理刷 ECONNREFUSED。"
    log "        清理（在宿主机执行）："
    log "          docker exec <容器> sh -c 'du -xh ${DSH_HOME} --max-depth=2 | sort -h | tail -15'"
    log "          docker exec <容器> rm -rf ${DSH_HOME}/.npm    # npm 下载缓存"
    log "          docker system prune -a                            # 镜像 / 构建缓存"
    log "        或把 Docker 数据目录换到更大的盘上。"
  fi
done

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
FALLBACK_WORKSPACE="${DSH_HOME}/.workspace"

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
  log "          A. sudo chown -R 1000:1000 <宿主机上 DSH_WORKSPACE_HOST 指向的目录>"
  log "          B. 在 .env 里把 DSH_WORKSPACE_HOST 改成一个绝对路径（Compose 不展开 ~ 和 \$HOME）："
  log "             root 部署：DSH_WORKSPACE_HOST=/dsh/workspace"
  log "             普通用户：DSH_WORKSPACE_HOST=/home/你的用户名/dsh-workspace"
  log "             改完执行 docker compose down && docker compose up -d   # 必须 down+up，restart 不生效"
  if [ "$WORKSPACE_STRICT" = "1" ]; then
    exit 1
  fi
  # 这里显式判断：set -e 下 mkdir 失败会直接退出，只剩一句 mkdir 的报错，
  # 用户看不到下面「退路也不可写」的说明。
  if ! mkdir -p "$FALLBACK_WORKSPACE" 2>/dev/null; then
    die "退路目录 ${FALLBACK_WORKSPACE} 创建失败，无法启动（要恢复「不可写就退出」设 DSH_WORKSPACE_STRICT=1）"
  fi
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
  log " 宿主机 DSH_WORKSPACE_HOST 指向的目录下。"
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

# pnpm 把 store 位置记在 node_modules/.modules.yaml，运行期每次装插件都拿它跟当前
# 环境算出的位置比对，不一致就报 ERR_PNPM_UNEXPECTED_STORE 拒绝安装。
#
# 记录的是构建期的绝对路径，而 profile 会被复制进数据卷、路径必然不同；旧镜像还会
# 记成 /root/.local/share/pnpm/store（构建期 HOME=/root）。所以直接删除：pnpm 下一次
# 装插件时会按当时的环境（.env 定义的 DSH_HOME/HOME）重新计算并写回。插件本体不受
# 影响，也不影响「首次装插件无需联网」。
#
# 这里不比较路径，因为要复刻 pnpm 的优先级（XDG_DATA_HOME 优先于 HOME）容易算错，
# 而删掉本来就是我们要的结果 —— 新镜像构建时已删除该文件，此处对存量卷是幂等的。
PROFILE_MODULES_YAML="$PROFILE/node_modules/.modules.yaml"
if [ -f "$PROFILE_MODULES_YAML" ]; then
  log "清理 profile 里过期的 pnpm store 记账，改为按当前数据目录重新计算"
  rm -f "$PROFILE_MODULES_YAML"
fi

# dsh 会校验 profile 插件行的 peer 依赖。profile 存在持久卷里，可能是旧镜像播种的
# （或者中途跑过 npm，把手工加的软链当 extraneous 删了），于是 peer 缺失/悬空，dsh
# 打印 disabling profile plugin row "storage-domain" … ENOENT … package.json 之后
# web 直接起不来，代理只会报一堆 socket hang up。这里每次启动按当前镜像里 dsh 的
# 实际安装位置补齐，幂等，不关心卷是哪个版本播种的。
DSH_PKG=/usr/local/lib/node_modules/@deepseek-ai/dsh
peer_dir() {
  local peer="$1" d
  for d in \
    "$DSH_PKG/node_modules/@deepseek-ai/$peer" \
    "$DSH_PKG/node_modules/$peer" \
    "/usr/local/lib/node_modules/@deepseek-ai/$peer"; do
    if [ -f "$d/package.json" ]; then
      printf '%s' "$d"
      return 0
    fi
  done
  return 1
}
mkdir -p "$PROFILE/node_modules/@deepseek-ai"
for peer in dsh-storage-domain cordis; do
  src="$(peer_dir "$peer" || true)"
  if [ -z "$src" ]; then
    log "警告：镜像里找不到 peer 依赖 $peer，profile 可能无法加载（重建镜像可修复）"
    continue
  fi
  dst="$PROFILE/node_modules/@deepseek-ai/$peer"
  if [ ! -f "$dst/package.json" ]; then
    log "补齐 profile peer 依赖：$peer -> $src"
    rm -rf "$dst" 2>/dev/null || true
    if ! ln -sfn "$src" "$dst" 2>/dev/null || [ ! -f "$dst/package.json" ]; then
      log "ERROR: 无法创建 peer 软链 $peer（目标 $src）"
      log "        常见原因是磁盘写满（ENOSPC）；磁盘一满，dsh 起来后也会退出。"
    fi
  fi
done

# ── 2. 写插件配置（每次启动按环境变量刷新）──────────────────────────────────
cookie_secure=false
[ "$DSH_COOKIE_SECURE" = "1" ] && cookie_secure=true
case "$DSH_AUTH_TOTP" in off | optional | required) ;; *) die "DSH_AUTH_TOTP 只能是 off/optional/required" ;; esac

cat >"$PROFILE/cordis.patch.yml" <<EOF
# 由容器 entrypoint 依据环境变量生成，请改 .env 而不是改这里。
- id: dsh-auth-gate
  config:
    mode: password
    totp: "${DSH_AUTH_TOTP}"
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
  log "检测到已有用户文件，跳过创建（改密码：在宿主机执行 ./dshm auth password）"
fi

# ── 3b. 私密文件权限自检 ────────────────────────────────────────────────────
# dsh 的 credentials 插件要求 .credentials.yaml「不能被 owner 以外的人读到」
# （源码里的判定是 mode & 0o077 == 0），否则直接拒绝启动：
#     credentials-local: /dsh/.credentials.yaml is readable beyond its owner (mode 777)
# 这种文件多半是从旧命名卷搬过来的，或者在宿主上被 chmod -R 777 过。容器里再遇上
# 就只能重启循环，所以每次启动前统一收紧一次（幂等，只改权限不动内容）。
tighten() { # <文件> <说明>
  [ -e "$1" ] || return 0
  local mode
  mode="$(stat -c '%a' "$1" 2>/dev/null || echo '')"
  [ -n "$mode" ] || return 0
  # 末两位是 00 就说明没有 group/other 权限位（600/400/700/100… 都算合规），
  # 与 dsh 的判定 mode & 0o077 == 0 一致；其余（640、777、1777…）一律收紧。
  [ "${mode: -2}" = "00" ] && return 0
  if chmod 600 "$1" 2>/dev/null; then
    log "已收紧 $2 权限：${1}（${mode} → $(stat -c '%a' "$1" 2>/dev/null || echo '?')）"
  else
    log "WARN: 无法收紧 $2 权限（${1} 当前 ${mode}），dsh 会拒绝启动；"
    log "      请在宿主机执行： sudo chmod 600 <DSH_HOME_HOST>${1#${DSH_HOME}}"
  fi
}
tighten "$DSH_HOME/.credentials.yaml" "凭据文件"
tighten "$DSH_HOME/settings.yaml" "设置文件"
tighten "$DSH_HOME/auth/users.yaml" "登录用户文件"
chmod 700 "$DSH_HOME/auth" 2>/dev/null || true

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

# 同时监督 dsh 和代理：只 wait 代理的话，dsh 中途挂掉无人察觉，代理会一直对外
# 转发一个死掉的后端，日志只剩刷屏的 ECONNREFUSED，真正的死因（比如 ENOSPC）被淹没。
# dsh 先退出就把它的日志尾部打出来并让容器退出（trap 收掉代理），重启策略会带着
# 现场重来。
set +e
wait -n "$DSH_PID" "$PROXY_PID"
status=$?
set -e
if ! kill -0 "$DSH_PID" 2>/dev/null; then
  log "dsh 已退出（status $status），dsh 日志尾部："
  tail -n 30 "$WEB_LOG" >&2 || true
else
  log "代理已退出（status $status），停止容器"
fi
exit "$status"
