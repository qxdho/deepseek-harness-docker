#!/usr/bin/env bash
# 一条命令部署。
#
#   ./install.sh
#
# 步骤：生成 .env（若缺失）→ 询问一次登录密码 → 拉 GHCR 镜像（拉不到就本地构建）
#       → 准备宿主工作区（属主/可写性预检）→ 启动 → 等待健康 → 打印访问地址。
set -euo pipefail
cd "$(dirname "$0")"

# ── 输出样式 ────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
	B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; RST=$'\033[0m'
else
	B=; DIM=; GRN=; RED=; YEL=; RST=
fi
hdr() { printf '\n%s==> %s%s\n' "$B" "$*" "$RST"; }
ok() { printf '    %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '    %s!%s %s\n' "$YEL" "$RST" "$*"; }
die() { printf '\n%s错误：%s%s\n\n' "$RED" "$*" "$RST" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "未安装 docker"
docker compose version >/dev/null 2>&1 || die "未安装 docker compose v2"

# ── 隐藏输入 + 星号回显 ─────────────────────────────────────────────────────
SECRET=""
read_secret() {
	local prompt="$1" ch
	SECRET=""
	printf '%s' "$prompt"
	if [ ! -t 0 ]; then
		IFS= read -rs SECRET || true
		printf '\n'
		return
	fi
	while IFS= read -rs -n1 ch; do
		case "$ch" in "" | $'\n' | $'\r') break ;; esac
		if [ "$ch" = $'\x7f' ] || [ "$ch" = $'\b' ]; then
			if [ -n "$SECRET" ]; then
				SECRET="${SECRET%?}"
				printf '\b \b'
			fi
			continue
		fi
		SECRET+="$ch"
		printf '*'
	done
	SECRET="${SECRET%$'\r'}"
	printf '\n'
}

check_password() {
	local pw="$1" missing=""
	[ "${#pw}" -ge 14 ] || missing="${missing} 至少14位;"
	printf '%s' "$pw" | grep -q '[A-Z]' || missing="${missing} 大写字母;"
	printf '%s' "$pw" | grep -q '[a-z]' || missing="${missing} 小写字母;"
	printf '%s' "$pw" | grep -q '[0-9]' || missing="${missing} 数字;"
	printf '%s' "$pw" | grep -q '[^A-Za-z0-9]' || missing="${missing} 特殊符号;"
	[ -z "$missing" ] || die "密码不合规，缺少：${missing}"
}

[ -f .env ] || { cp .env.example .env; ok "已生成 .env"; }

get_env() { grep -E "^$1=" .env 2>/dev/null | tail -n1 | cut -d= -f2- || true; }
set_env() {
	local k="$1" v="$2" tmp
	tmp="$(mktemp)"
	awk -v k="$k" -v v="$v" 'BEGIN{d=0} $0 ~ "^" k "=" {print k "=" v; d=1; next} {print} END{if(!d) print k "=" v}' .env >"$tmp"
	mv "$tmp" .env
}

# ── 1. 登录密码 ─────────────────────────────────────────────────────────────
pw="$(get_env DSH_AUTH_PASSWORD)"
if [ -z "$pw" ] || [ "$pw" = "请换成至少14位且含大小写/数字/符号的强密码" ]; then
	hdr "设置登录密码"
	printf '    规则：至少 14 位，且包含%s大写 / 小写 / 数字 / 特殊符号%s\n' "$B" "$RST"
	p1=""; p2=""
	while :; do
		read_secret "    新密码："
		p1="$SECRET"
		read_secret "    再输一次确认："
		p2="$SECRET"
		# 非交互模式（管道/CI）下 stdin 耗尽会一直读到空串，p1 != p2 永远成立，
		# 这个循环会无限打转。检测到空输入就明确报错退出，别让调用方挂住。
		if [ ! -t 0 ] && { [ -z "$p1" ] || [ -z "$p2" ]; }; then
			die "非交互模式下读取密码失败（输入为空或已到 EOF）；请在 .env 里直接设置 DSH_AUTH_PASSWORD 后重试"
		fi
		if [ "$p1" != "$p2" ]; then
			warn "两次输入不一致，请重新输入"
			continue
		fi
		check_password "$p1"
		break
	done
	pw="$p1"
	set_env DSH_AUTH_PASSWORD "$pw"
	chmod 600 .env 2>/dev/null || true
	ok "密码已写入 .env（登录用户名：$(get_env DSH_AUTH_USER | grep . || echo admin)）"
else
	ok ".env 里已有密码，跳过（要改密码用 ./dshm pw）"
fi

# ── 2. 拉镜像，失败则本地构建 ───────────────────────────────────────────────
hdr "获取镜像"
if docker compose pull; then
	ok "已拉取镜像"
else
	warn "拉取失败（可能是私有包），改为本地构建（首次较慢）"
	docker compose build
fi

# ── 3. 准备宿主工作区 ───────────────────────────────────────────────────────
# 必须在 docker compose up 之前：源目录不存在时是 dockerd（root）替你建的，
# 容器里的 node(1000) 就写不进去。提前建好，属主就是当前用户。
hdr "准备工作区"
# shellcheck source=scripts/preflight.sh
. ./scripts/preflight.sh
if ! check_workspace "$PWD" auto 1; then
	die "工作区未就绪，请按上面的提示处理后重试"
fi
ok "工作区就绪：${DSH_WORKSPACE_DIR}"

# ── 4. 启动 ─────────────────────────────────────────────────────────────────
hdr "启动服务"
docker compose up -d

# ── 5. 等健康 ───────────────────────────────────────────────────────────────
hdr "等待服务就绪"
healthy=0
elapsed=0
last=-10
for _ in $(seq 1 72); do
	# 一次 inspect 同时取运行状态与健康状态，别为了两行信息调两次 docker。
	read -r running s <<<"$(docker inspect \
		--format '{{.State.Running}} {{.State.Health.Status}}' qxdho-dsh 2>/dev/null || echo 'false unknown')"
	if [ "$s" = "healthy" ]; then
		healthy=1
		break
	fi
	# 容器已经退出/在重启循环里，再等下去没意义 —— 直接给日志。
	if [ "$running" != "true" ] || [ "$s" = "unhealthy" ] || [ "$s" = "restarting" ]; then
		printf '    容器状态异常（running=%s health=%s），下面是日志尾部：\n\n' "$running" "$s"
		docker compose logs --tail 60 qxdho-dsh || true
		exit 1
	fi
	if [ $((elapsed - last)) -ge 10 ]; then
		printf '    等待就绪… %ss（%s）\n' "$elapsed" "$s"
		last="$elapsed"
	fi
	sleep 5
	elapsed=$((elapsed + 5))
done
if [ "$healthy" != "1" ]; then
	printf '    未在预期时间内健康（当前：%s），下面是日志尾部：\n\n' "$s"
	docker compose logs --tail 60 qxdho-dsh || true
	exit 1
fi
ok "服务已健康（用时约 ${elapsed}s）"

port="$(get_env PROXY_PORT)"; port="${port:-3080}"
bind="$(get_env DSH_BIND)"; bind="${bind:-127.0.0.1}"

hdr "部署完成"
printf '    登录用户：%s\n' "$(get_env DSH_AUTH_USER | grep . || echo admin)"
if [ "$bind" = "0.0.0.0" ]; then
	printf '    访问地址：%shttp://<服务器IP>:%s/%s\n' "$B" "$port" "$RST"
else
	printf '    容器只绑定了 127.0.0.1，请在宿主机反代到 %s127.0.0.1:%s%s\n' "$B" "$port" "$RST"
	printf '    想先用 IP 直接访问测试：把 .env 的 DSH_BIND 改成 0.0.0.0，再执行 ./install.sh\n'
fi
printf '\n    常用命令：%s./dshm status%s   %s./dshm logs%s   %s./dshm pw%s\n\n' \
	"$B" "$RST" "$B" "$RST" "$B" "$RST"
