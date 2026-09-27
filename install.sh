#!/usr/bin/env bash
# 一条命令部署。
#
#   ./install.sh
#
# 它会：生成 .env（若缺失）→ 询问一次登录密码 → 拉取 GHCR 镜像（拉不到就本地构建）
#       → 启动 → 等待健康 → 打印访问地址。
set -euo pipefail
cd "$(dirname "$0")"

die() { printf 'install: ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "未安装 docker"
docker compose version >/dev/null 2>&1 || die "未安装 docker compose v2"

[ -f .env ] || { cp .env.example .env; echo "已生成 .env"; }

get_env() { grep -E "^$1=" .env 2>/dev/null | tail -n1 | cut -d= -f2- || true; }
set_env() {
	local k="$1" v="$2" tmp
	tmp="$(mktemp)"
	awk -v k="$k" -v v="$v" 'BEGIN{d=0} $0 ~ "^" k "=" {print k "=" v; d=1; next} {print} END{if(!d) print k "=" v}' .env >"$tmp"
	mv "$tmp" .env
}

# 1. 登录密码
pw="$(get_env DSH_AUTH_PASSWORD)"
if [ -z "$pw" ] || [ "$pw" = "请换成至少12位的强密码" ]; then
	printf '请设置登录密码（至少 12 位，输入不回显）：'
	read -rs pw
	echo
	[ "${#pw}" -ge 12 ] || die "密码太短，至少 12 位"
	set_env DSH_AUTH_PASSWORD "$pw"
	chmod 600 .env 2>/dev/null || true
	echo "密码已写入 .env（用户名为 $(get_env DSH_AUTH_USER)，默认 admin）"
fi

# 2. 拉镜像，失败则本地构建
echo "== 拉取镜像 =="
if ! docker compose pull; then
	echo "== 拉取失败（可能是私有包），改为本地构建 =="
	docker compose build
fi

# 3. 启动
echo "== 启动 =="
docker compose up -d

# 4. 等健康
echo "== 等待健康检查（首次启动可能要 1-2 分钟）=="
for i in $(seq 1 72); do
	s="$(docker inspect --format '{{.State.Health.Status}}' dsh 2>/dev/null || echo unknown)"
	[ "$s" = "healthy" ] && break
	if [ "$i" = "72" ]; then
		echo "未在预期时间内 healthy（当前：$s），日志："
		docker compose logs --tail 60 dsh || true
		exit 1
	fi
	sleep 5
done

port="$(get_env PROXY_PORT)"; port="${port:-3080}"
bind="$(get_env DSH_BIND)"; bind="${bind:-127.0.0.1}"

echo
echo "✅ 部署完成"
echo "   登录用户：$(get_env DSH_AUTH_USER | grep . || echo admin)"
if [ "$bind" = "0.0.0.0" ]; then
	echo "   访问：http://<服务器IP>:${port}/"
else
	echo "   容器目前只绑 127.0.0.1。请在宿主机反代到 127.0.0.1:${port}（并设 DSH_COOKIE_SECURE=1）。"
	echo "   想先直接访问测试：把 .env 的 DSH_BIND 改成 0.0.0.0，再执行 ./install.sh"
fi
