#!/usr/bin/env bash
# 一条命令部署。
#
#   ./install.sh
#
# 步骤：生成 .env（若缺失）→ 逐项检查配置（有默认值的直接采用，只有必填且无默认
#       值的才询问）→ 拉 GHCR 镜像（拉不到就本地构建）→ 旧命名卷数据迁移（仅旧版
#       升级时需要）→ 准备宿主工作区（属主/可写性预检）→ 启动 → 等待健康 → 打印访问地址。
set -euo pipefail
# 定位脚本所在目录（不是 cwd），这样从任何地方调用都能找到同目录的 scripts/。
here="$(cd "$(dirname "$0")" && pwd)"

# ── 输出样式 ────────────────────────────────────────────────────────────────
# 与 dshm、scripts/release.sh 共用同一份实现（scripts/log.sh）。
# 以前这里逐字抄了一遍颜色与 hdr/info/ok/warn/die —— 改一处必然漏另一处。
#
# **必须先 source 再用 die**：source 之前 die 还不存在，cd 一旦失败会报
# `die: command not found`（退出码 127），把真正的原因盖掉。
. "$here/scripts/log.sh"

cd "$here" || die "无法进入脚本所在目录：$here"

command -v docker >/dev/null 2>&1 || die "未安装 docker"
docker compose version >/dev/null 2>&1 || die "未安装 docker compose v2"

[ -f .env ] || { cp .env.example .env; ok "已生成 .env"; }

# 配置项读写 + 「空则询问、非空跳过」逻辑 + 隐藏输入 read_secret
# （可单测：scripts/test-env-config.sh）
# shellcheck source=scripts/env-config.sh
. ./scripts/env-config.sh
# 旧命名卷 → 宿主目录的自动迁移（与 dshm 共用同一份实现）
# shellcheck source=scripts/migrate-home.sh
. ./scripts/migrate-home.sh

# ── 1. 配置项：有默认值的直接采用，只有必填且无默认值的才询问 ───────────────
hdr "检查 .env 配置项"
# 先做键名迁移：老 .env 里的 PROXY_PORT / DSH_WORKSPACE / DSH_HOME 等旧键
# 改成新名字（值不变），后面统一按新键读写。
migrate_legacy_keys
ensure_password
ensure_env DSH_AUTH_USER "登录用户名" "admin" 0 env_validate_username
ensure_env DSH_HTTP_PORT "对外端口" "3080" 0 env_validate_port
ensure_env DSH_BIND "监听地址（127.0.0.1=仅本机，0.0.0.0=局域网可访问）" "127.0.0.1" 0 env_validate_bind
ensure_env DSH_WORKSPACE_HOST "工作区目录（宿主，挂到容器）" "/dsh/workspace" 0 ""
ensure_env DSH_WORKSPACE_CONTAINER "容器内工作区路径" "/workspace" 0 env_validate_abspath
ensure_env DSH_HOME_HOST "dsh 数据目录（宿主，bind 挂到容器）" "/dsh" 0 ""
ensure_env DSH_HOME_CONTAINER "容器内 dsh 数据目录" "/dsh" 0 env_validate_abspath
ensure_env DSH_AUTH_TOTP "两步验证（off/optional/required）" "optional" 0 env_validate_totp

# 历史默认值对齐（只处理容器内数据目录的旧默认 /home/node/.dsh）
normalize_defaults

# 把最终生效的配置列出来：静默跳过会让用户不知道跑的是什么
config_summary

# ── 2. 拉镜像，失败则本地构建 ───────────────────────────────────────────────
hdr "获取镜像"
if docker compose pull; then
	ok "已拉取镜像"
else
	warn "拉取失败（可能是私有包），改为本地构建（首次较慢）"
	docker compose build
fi

# ── 3. 旧版命名卷 → 宿主目录（仅第一次升级会真正执行，之后目标非空即跳过）──
auto_migrate_legacy_home

# ── 4. 准备宿主工作区 ───────────────────────────────────────────────────────
# 必须在 docker compose up 之前：源目录不存在时是 dockerd（root）替你建的，
# 容器里的 node(1000) 就写不进去。提前建好，属主就是当前用户。
hdr "准备工作区"
# shellcheck source=scripts/preflight.sh
. ./scripts/preflight.sh
if ! check_workspace "$PWD" auto 1; then
	die "工作区未就绪，请按上面的提示处理后重试"
fi
ok "工作区就绪：${DSH_WORKSPACE_DIR}"

# ── 5. 启动 ─────────────────────────────────────────────────────────────────
hdr "启动服务"
docker compose up -d

# ── 6. 等健康 ───────────────────────────────────────────────────────────────
hdr "等待服务就绪"
# 实现在 scripts/env-config.sh，与 dshm 共用同一份。此前这里内联了一版，
# docker inspect 首次失败就会 exit 1 —— 而容器刚创建时 daemon 还在注册、这一下
# inspect 失败很常见，会把正常的慢启动直接报成失败。
if ! wait_container_healthy qxdho-dsh "docker compose logs --tail 60 qxdho-dsh" 5 72; then
	die "服务未在预期时间内健康；查看日志：./dshm service logs"
fi
ok "服务已就绪"

port="$(env_value_new DSH_HTTP_PORT 3080)"
bind="$(get_env DSH_BIND)"; bind="${bind:-127.0.0.1}"

hdr "部署完成"
printf '    登录用户：%s\n' "$(get_env DSH_AUTH_USER | grep . || echo admin)"
if [ "$bind" = "0.0.0.0" ]; then
	printf '    访问地址：%shttp://<服务器IP>:%s/%s\n' "$B" "$port" "$RST"
else
	printf '    容器只绑定了 127.0.0.1，请在宿主机反代到 %s127.0.0.1:%s%s\n' "$B" "$port" "$RST"
	printf '    想先用 IP 直接访问测试：把 .env 的 DSH_BIND 改成 0.0.0.0，再执行 ./install.sh\n'
fi
printf '\n    常用命令：%s./dshm service status%s   %s./dshm service logs%s   %s./dshm auth password%s\n' \
	"$B" "$RST" "$B" "$RST" "$B" "$RST"
printf '    全部命令：%s./dshm help%s\n\n' "$B" "$RST"
