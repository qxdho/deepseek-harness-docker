#!/usr/bin/env bash
# .env 配置项的读写、命名迁移，以及「有默认值就直接采用」的配置逻辑。
#
# 键名约定（改名前请先读这里）：
#   * 本项目自己的配置一律 DSH_ 前缀，构建期参数也一样；
#   * 宿主侧路径用 _HOST 结尾，容器侧路径用 _CONTAINER 结尾；
#   * 上游 dsh 自己的变量（DSH_HOME、DSH_HOST、DSH_PORT、DSH_PERMISSION_MODE、
#     DSH_TELEMETRY_DISABLED 等）由镜像和 compose 注入，不写进 .env。
#
# 被 install.sh / dshm 复用；可单独测试：scripts/test-env-config.sh
#
# 调用方需先定义：hdr / ok / warn / die（输出函数）。
# 可选覆盖：ENV_FILE（默认 .env）、INTERACTIVE=0|1（默认按 stdin 是否 tty 推断）。

: "${ENV_FILE:=.env}"
if [ -z "${INTERACTIVE:-}" ]; then
	if [ -t 0 ]; then INTERACTIVE=1; else INTERACTIVE=0; fi
fi

# ── 键名迁移 ────────────────────────────────────────────────────────────────
# 新名=旧名。历史上这几个键命名不统一（宿主/容器不分、缺前缀），改名后老 .env
# 里的旧键要能继续用：读的时候回退到旧键，启动时再就地改名。
LEGACY_KEYS="DSH_HTTP_PORT=PROXY_PORT
DSH_WORKSPACE_HOST=DSH_WORKSPACE
DSH_HOME_CONTAINER=DSH_HOME
DSH_AUTH_TOTP=DSH_TOTP
DSH_AUTH_GATE_VERSION=AUTH_GATE_VERSION
DSH_DEV_TOOLS=DEV_TOOLS"

# legacy_key_of 新键名 → 旧键名（没有则输出空）
legacy_key_of() {
	local pair
	for pair in $LEGACY_KEYS; do
		case "$pair" in "$1="*) printf '%s' "${pair#*=}"; return 0 ;; esac
	done
	return 0
}

# env_value_new 新键名 [默认值] —— 新键优先，其次旧键，最后默认值。
# 给那些「不启动容器、只读配置」的命令用，保证迁移还没跑时也能读到用户的值。
env_value_new() {
	local v old
	v="$(get_env "$1")"
	if [ -z "$v" ]; then
		old="$(legacy_key_of "$1")"
		[ -z "$old" ] || v="$(get_env "$old")"
	fi
	printf '%s' "${v:-$2}"
}

# 把 .env 里存在的旧键改名为新键（值不变）。新键已有值时以新键为准，并删掉旧键，
# 避免同一个配置出现两个来源。ENV_FILE 不可写时只告警，不阻断命令。
migrate_legacy_keys() {
	local pair old new val
	for pair in $LEGACY_KEYS; do
		old="${pair#*=}"
		new="${pair%%=*}"
		has_key "$old" || continue
		val="$(get_env "$old")"
		if [ -n "$(get_env "$new")" ]; then
			unset_env "$old" 2>/dev/null || {
				warn "请手工删除 ${ENV_FILE} 里的 ${old}（已有 ${new}）"
				continue
			}
			warn "${old} 与 ${new} 同时存在，已删除旧键 ${old}"
			continue
		fi
		if set_env "$new" "$val" 2>/dev/null && unset_env "$old" 2>/dev/null; then
			ok "配置项改名：${old} → ${new}（值不变）"
		else
			warn "无法改写 ${ENV_FILE}（权限不足？），请手工把 ${old} 改名为 ${new}"
		fi
	done
	return 0
}

# ── 隐藏输入 + 星号回显 ─────────────────────────────────────────────────────
# 用法：read_secret "提示文字"  → 结果在变量 SECRET 里。
# 放在这里是因为 install.sh 与 dshm 都需要；以前两边各抄一份，改一处忘一处。
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

# 读取一个键。去掉一层包裹的引号，和 preflight 的解析保持一致。
# 读 .env 里某个键的值。`<文件>` 可选，默认 $ENV_FILE —— 带上文件参数是为了让
# preflight.sh（它对任意临时 .env 做检查）也能复用同一份实现。
#
# **允许行首空白**：Compose 自己的 .env 解析就接受 `  KEY=value`，我们若只认 `^KEY=`
# 就会出现"preflight 读到 1111、env_value 读到空并用默认 1000"这种分歧 ——
# 检查通过但容器以错误的 uid 启动。统一到这里之后两边结果必然一致。
get_env() {
	local key="$1" file="${2:-${ENV_FILE:-}}" v
	[ -n "$file" ] && [ -f "$file" ] || { printf '%s' ""; return 0; }
	v="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -n1 || true)"
	[ -n "$v" ] || { printf '%s' ""; return 0; }
	v="${v#*=}"
	case "$v" in
	\"*\") v="${v#\"}"; v="${v%\"}" ;;
	\'*\') v="${v#\'}"; v="${v%\'}" ;;
	esac
	printf '%s' "$v"
}

# 读一个键，为空时返回默认值（dshm 里大量使用）
env_value() {
	local v
	v="$(get_env "$1")"
	printf '%s' "${v:-$2}"
}

# 把 .env 里的历史默认值对齐到当前默认值。install.sh 与 dshm service up 都会调用。
#
# 唯一的规则：容器内数据目录还是旧默认 /home/node/.dsh → 改成 /dsh。这里只改
# **容器内路径**（DSH_HOME_CONTAINER），宿主一侧的 DSH_HOME_HOST 不动，所以不会
# 搬动任何数据，只是让挂载点与默认值/文档一致（旧值会让 dshm 里的路径对不上）。
#
# 工作区**不跟随**数据目录：DSH_WORKSPACE_HOST 与 DSH_HOME_HOST 是两条独立的绝对
# 路径，由使用者自己配。跟随曾经做过，但它无法区分「没写过」和「写成了默认值」，
# 会把用户明确指定的 /dsh/workspace 改掉。
normalize_defaults() {
	local home
	home="$(env_value_new DSH_HOME_CONTAINER /dsh)"
	if [ "$home" = "/home/node/.dsh" ]; then
		set_env DSH_HOME_CONTAINER "/dsh"
		ok "DSH_HOME_CONTAINER 由旧默认 /home/node/.dsh 改为当前默认 /dsh（宿主目录不变）"
	fi
}

# 键是否存在（哪怕值为空）。
# `^[[:space:]]*` 与 get_env 保持一致 —— 不一致会让"有缩进的键"在 get_env 里能读到、
# 在 has_key 里却判为不存在（migrate_legacy_keys 会因此静默跳过改名）。
has_key() {
	grep -qE "^[[:space:]]*$1=" "$ENV_FILE" 2>/dev/null
}

# ── 生效配置汇总 ────────────────────────────────────────────────────────────
# 配置项多，静默跳过会让用户不知道最终跑的是什么。install.sh 与 dshm service up
# 读取完配置后调用这里，把实际生效的值列出来（等于默认值时标注「默认」）。
summary_line() { # KEY 说明 默认值
	local key="$1" label="$2" default="$3" v note
	v="$(env_value_new "$key" "$default")"
	if [ -z "$v" ]; then
		note="（空）"
	elif [ "$v" = "$default" ]; then
		note="（默认）"
	else
		note="（已改）"
	fi
	printf '    %s：%s=%s %s\n' "$label" "$key" "$v" "$note"
}

# 密码只报「已设置 / 未设置」，绝不回显
summary_secret() { # KEY 说明
	local v
	v="$(env_value_new "$1" "")"
	if [ -n "$v" ]; then
		printf '    %s：%s=已设置（不显示）\n' "$2" "$1"
	else
		printf '    %s：%s=未设置\n' "$2" "$1"
	fi
}

config_summary() {
	hdr "生效配置"
	summary_line DSH_HTTP_PORT "宿主访问端口" "3080"
	summary_line DSH_BIND "宿主监听地址" "127.0.0.1"
	summary_line DSH_HOME_HOST "数据目录（宿主）" "/dsh"
	summary_line DSH_HOME_CONTAINER "数据目录（容器）" "/dsh"
	summary_line DSH_WORKSPACE_HOST "工作区（宿主）" "/dsh/workspace"
	summary_line DSH_WORKSPACE_CONTAINER "工作区（容器）" "/workspace"
	printf '    容器运行身份：DSH_UID:DSH_GID=%s:%s\n' \
		"$(env_value DSH_UID 1000)" "$(env_value DSH_GID 1000)"
	summary_line DSH_AUTH_USER "登录用户" "admin"
	summary_secret DSH_AUTH_PASSWORD "登录密码"
	summary_line DSH_AUTH_TOTP "两步验证" "optional"
	summary_line DSH_COOKIE_SECURE "Cookie Secure" "0"
	summary_line DSH_PUBLIC_HOST "登录页域名" ""
	summary_line DSH_IMAGE "镜像" "ghcr.io/qxdho/deepseek-harness-docker:latest"
	summary_line DSH_ADMIN_DIR "管理面板目录" "/dsh-manager"
	info "改配置：编辑 ${ENV_FILE} 后执行 ./dshm service up（restart 不重读）"
	info "各项含义：见 .env.example 注释，或 ./dshm help"
}

# 写回一个键。值通过环境变量传给 awk —— 用 `awk -v v=...` 会把值里的
# 反斜杠序列当转义处理（`a\b` 会写成退格符），密码里带 \ 就再也登不进去。
# 原子地重写 .env，并保住权限与符号链接。
#
# 直接 `mktemp`（落在 /tmp）再 `mv` 有三个问题，都已实测：
#   1. 跨文件系统时 mv 退化成"复制+删除"，非原子，中途失败会留下截断的 .env；
#   2. mktemp 的 0600 会被带过来，原来 640 的 .env 被改成 600 —— root 跑过一次
#      install.sh 的项目目录里，普通用户之后就读不到了；
#   3. .env 若是符号链接（指向别处的真实配置），mv 会用普通文件**替换掉软链**，
#      真实文件仍是旧内容 —— secrets 被静默断开。
#
# 做法：临时文件放在 .env 同目录（同文件系统，mv 是原子 rename），解析软链后写真实
# 路径，并把原权限/属主带到新文件上。
#
# 注意过滤器的传参方式：本函数接收**命令与它的参数**（如 awk '程序'），
# 不能用 `"$filter"` 把整串当一个命令 —— 那样 awk 会把程序文本当成文件名而报 Usage。
rewrite_env_atomic() { # <命令> [参数…]
	local target dir tmp mode owner
	target="$ENV_FILE"
	if [ -L "$target" ]; then
		local link
		link="$(readlink -f "$target" 2>/dev/null || true)"
		[ -n "$link" ] && target="$link"
	fi
	dir="$(dirname "$target")"
	# 先记权限/属主，必须在建临时文件之前读，否则读到的是 mktemp 的 600
	if [ -e "$target" ]; then
		mode="$(stat -c '%a' "$target" 2>/dev/null || echo 600)"
		owner="$(stat -c '%u:%g' "$target" 2>/dev/null || true)"
	else
		mode=600
		owner=""
	fi
	tmp="$(mktemp "${dir}/.env.tmp.XXXXXX" 2>/dev/null)" || return 1
	if ! cat "$target" 2>/dev/null | "$@" >"$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	chmod "$mode" "$tmp" 2>/dev/null || true
	[ -n "$owner" ] && chown "$owner" "$tmp" 2>/dev/null || true
	if ! mv "$tmp" "$target"; then
		rm -f "$tmp"
		return 1
	fi
	return 0
}

set_env() {
	local k="$1" v="$2"
	# 正则 `^[[:space:]]*k=` 与 get_env/has_key 一致：否则 `.env` 里写成
	# `  DSH_HTTP_PORT=3080` 时，get_env 读到 3080、set_env 却新加一行 ——
	# "写进去了但读到的还是旧值"，看起来像没生效。
	K="$k" V="$v" rewrite_env_atomic awk '
		BEGIN { d=0; k=ENVIRON["K"]; v=ENVIRON["V"] }
		$0 ~ ("^[[:space:]]*" k "=") { print k "=" v; d=1; next }
		{ print }
		END { if (!d) print k "=" v }
	'
}

unset_env() {
	local k="$1"
	K="$k" rewrite_env_atomic awk '$0 !~ ("^[[:space:]]*" ENVIRON["K"] "=")'
}

# 示例文件里的占位符等同于「未配置」
env_is_placeholder() {
	case "$1" in
	"" | "请换成至少14位且含大小写/数字/符号的强密码") return 0 ;;
	esac
	return 1
}

# ── 校验器：返回 0 通过；返回 1 时已打印原因（调用方会重新询问）──────────────
env_validate_password() {
	local pw="$1" missing=""
	[ "${#pw}" -ge 14 ] || missing="${missing} 至少14位;"
	printf '%s' "$pw" | grep -q '[A-Z]' || missing="${missing} 大写字母;"
	printf '%s' "$pw" | grep -q '[a-z]' || missing="${missing} 小写字母;"
	printf '%s' "$pw" | grep -q '[0-9]' || missing="${missing} 数字;"
	printf '%s' "$pw" | grep -q '[^A-Za-z0-9]' || missing="${missing} 特殊符号;"
	if [ -n "$missing" ]; then
		warn "密码不合规，缺少：${missing}"
		return 1
	fi
	return 0
}

env_validate_username() {
	case "$1" in
	'' | *[!a-z0-9._-]*)
		warn "用户名只能用小写字母、数字、点、下划线、连字符"
		return 1
		;;
	esac
	return 0
}

env_validate_port() {
	case "$1" in '' | *[!0-9]*) warn "端口必须是数字"; return 1 ;; esac
	if [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null; then
		return 0
	fi
	warn "端口需在 1-65535 之间"
	return 1
}

env_validate_bind() {
	case "$1" in 127.0.0.1 | 0.0.0.0 | localhost) return 0 ;; esac
	warn "只支持 127.0.0.1（仅本机）或 0.0.0.0（局域网可访问）"
	return 1
}

env_validate_totp() {
	case "$1" in off | optional | required) return 0 ;; esac
	warn "只能是 off / optional / required"
	return 1
}

# ── 等待容器健康 ────────────────────────────────────────────────────────────
# wait_container_healthy <容器名> [日志命令] [每次等待秒数] [最大轮数]
#
# install.sh 与 dshm 共用这一份实现。此前两处各写一遍，语义已经漂移：install.sh
# 版本在 docker inspect **首次失败**时就判死退出，而容器刚创建、daemon 正忙的那一
# 下 inspect 失败是很常见的瞬时错误，会把正常的慢启动直接报成失败。这里统一取更
# 稳的语义：
#   * inspect 失败 → 连续 6 次才放弃（每次间隔 sleep）
#   * running != true、或 health 为 dead/restarting → 立即放弃（真的在崩溃重启）
#   * health=unhealthy 不立即放弃：它可能只是暂时（依赖启动中的服务），等满超时
#     再看，最终仍不健康则由调用方报错 —— 这样不会把慢启动误判为失败
#   * 每约 10 秒打一行进度，并回显已等秒数
#
# 依赖默认值：调用方通常已定义 warn（本仓库的 install.sh 与 dshm 都定义了），但这里
# 给出回退实现，避免调用方漏定义时提示整条消失 —— 曾经因为这个契约没写明，测试里
# 没定义 warn，失败提示就静默丢了。
#
# 用显式全局变量而不是 `declare -F warn` 判断：本函数可能被放在命令替换（子 shell）
# 里调用，那样定义的回退函数不会传播回父 shell，每次调用都要重判一次。
WAIT_HEALTHY_WARN_READY=""
wait_container_healthy() {
	local name="$1" logcmd="${2:-}"
	local interval="${3:-5}" rounds="${4:-72}"
	local status running out fails=0 elapsed=0 last=-10
	logcmd="${logcmd:-docker logs --tail 40 $name}"
	if [ -z "$WAIT_HEALTHY_WARN_READY" ]; then
		WAIT_HEALTHY_WARN_READY=1
		if ! declare -F warn >/dev/null 2>&1; then
			warn() { printf '    ! %s\n' "$*" >&2; }
		fi
	fi

	for _ in $(seq 1 "$rounds"); do
		if ! out="$(docker inspect --format '{{.State.Running}} {{.State.Health.Status}}' "$name" 2>/dev/null)"; then
			fails=$((fails + 1))
			if [ "$fails" -ge 6 ]; then
				warn "读不到容器状态（docker inspect 连续失败），不再等待"
				return 1
			fi
			sleep "$interval"
			elapsed=$((elapsed + interval))
			continue
		fi
		fails=0
		read -r running status <<<"$out"
		running="${running:-unknown}"
		# 没配 healthcheck 时 Health 段为空，取值会得到空串
		status="${status:-unknown}"
		[ "$status" = "healthy" ] && return 0

		if [ "$running" != "true" ]; then
			warn "容器没有在运行（running=${running} health=${status}），不再等待"
			$logcmd 2>&1 || true
			return 1
		fi
		case "$status" in
		dead | restarting)
			warn "容器状态异常（${status}），不再等待"
			$logcmd 2>&1 || true
			return 1
			;;
		esac

		if [ $((elapsed - last)) -ge 10 ]; then
			printf '    等待就绪… %ss（%s）\n' "$elapsed" "$status"
			last="$elapsed"
		fi
		sleep "$interval"
		elapsed=$((elapsed + interval))
	done

	warn "容器未在预期时间内健康（当前：${status:-unknown}）"
	$logcmd 2>&1 || true
	return 1
}

# 容器内的挂载点：必须是绝对路径，且不能带空格/引号/冒号。
# 这些值会被 Compose 原样拼进短语法挂载串 `源:目标`，空值或相对路径会让 dockerd
# 报 "invalid mount path: '' mount path must be absolute"，冒号还会把挂载串切错。
env_validate_abspath() {
	case "$1" in
	/*) ;;
	*)
		warn "必须是绝对路径（以 / 开头）"
		return 1
		;;
	esac
	case "$1" in
	*[!A-Za-z0-9._/@+-]*)
		warn "路径里不能有空格、引号或冒号"
		return 1
		;;
	esac
	return 0
}

# ── 空则写入默认值、非空跳过 ────────────────────────────────────────────────
# ensure_env KEY 说明 [默认值] [可选=1] [校验函数]
#
# 设计目标：有默认值的项一律不提问。默认值就是推荐值，让用户逐个回车确认只会
# 增加出错机会（历史上就有人在这类提示里填出了不该用的路径）。因此：
#   * 已有合法值        → 跳过
#   * 未配置 + 有默认值 → 直接写入默认值，交互模式下也不询问
#   * 已有值不合规      → 有默认值就改用默认值并告警；没有默认值才重新询问/报错
#   * 未配置 + 可选项   → 跳过
#   * 未配置 + 必填无默认值 → 交互模式询问；非交互模式报错（fail-closed）
ensure_env() {
	local key="$1" label="$2" default="${3:-}" optional="${4:-0}" validator="${5:-}"
	local cur value
	cur="$(get_env "$key")"

	if [ -n "$cur" ] && ! env_is_placeholder "$cur"; then
		if [ -z "$validator" ] || "$validator" "$cur"; then
			ok "${key}=${cur}（已配置，跳过）"
			return 0
		fi
		if [ -n "$default" ]; then
			warn "${key} 的当前值不合规，改用默认值：${default}"
			set_env "$key" "$default"
			return 0
		fi
		if [ "$INTERACTIVE" != "1" ]; then
			die "${key} 的当前值不合规，请在 ${ENV_FILE} 里修正后重试"
		fi
		warn "${key} 的当前值不合规，请重新输入"
	else
		if [ -n "$default" ]; then
			set_env "$key" "$default"
			ok "${key} 未配置，使用默认值：${default}"
			return 0
		fi
		if [ "$optional" = "1" ]; then
			ok "${key} 未配置，可选，跳过"
			return 0
		fi
		if [ "$INTERACTIVE" != "1" ]; then
			die "${key} 未配置且当前为非交互模式；请在 ${ENV_FILE} 里设置后重试"
		fi
	fi

	# 只有「必填且没有默认值」才需要用户输入
	while :; do
		printf '    %s：' "$label"
		IFS= read -r value || value=""
		if [ -z "$value" ]; then
			warn "$label 不能为空"
			continue
		fi
		[ -z "$validator" ] || "$validator" "$value" || continue
		break
	done
	set_env "$key" "$value"
	ok "${key} 已写入 ${ENV_FILE}"
}

# 密码需要隐藏输入 + 二次确认，单独处理
ensure_password() {
	local cur p1 p2
	cur="$(get_env DSH_AUTH_PASSWORD)"
	if [ -n "$cur" ] && ! env_is_placeholder "$cur"; then
		ok "DSH_AUTH_PASSWORD 已配置，跳过（改密码：./dshm auth password）"
		return 0
	fi
	if [ "$INTERACTIVE" != "1" ]; then
		die "DSH_AUTH_PASSWORD 为空且当前为非交互模式；请在 ${ENV_FILE} 里设置后重试"
	fi
	hdr "设置登录密码"
	printf '    规则：至少 14 位，且包含%s大写 / 小写 / 数字 / 特殊符号%s\n' "${B:-}" "${RST:-}"
	while :; do
		# read_secret 由本文件提供；测试里可以覆盖它以喂入固定密码
		read_secret "    新密码："
		p1="$SECRET"
		read_secret "    再输一次确认："
		p2="$SECRET"
		if [ "$p1" != "$p2" ]; then
			warn "两次输入不一致，请重新输入"
			continue
		fi
		env_validate_password "$p1" || continue
		break
	done
	set_env DSH_AUTH_PASSWORD "$p1"
	chmod 600 "$ENV_FILE" 2>/dev/null || true
	ok "DSH_AUTH_PASSWORD 已写入 ${ENV_FILE}"
}
