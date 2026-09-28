#!/usr/bin/env bash
# .env 配置项的读写，以及「为空则询问、已有值则跳过」的交互逻辑。
#
# 被 install.sh / dshm 复用；可单独测试：scripts/test-env-config.sh
#
# 调用方需先定义：hdr / ok / warn / die（输出函数）。
# 可选覆盖：ENV_FILE（默认 .env）、INTERACTIVE=0|1（默认按 stdin 是否 tty 推断）。

: "${ENV_FILE:=.env}"
if [ -z "${INTERACTIVE:-}" ]; then
	if [ -t 0 ]; then INTERACTIVE=1; else INTERACTIVE=0; fi
fi

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
get_env() {
	local v
	v="$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
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

# 数据目录换了、工作区还停在旧默认时，让工作区跟着走。
# compose 里工作区的默认值写死为 /dsh/workspace，只能在这里对齐，否则
# 只改 DSH_HOME_HOST 会留下一个 /dsh/workspace —— 在宿主上多半是 root 建的、
# 容器写不进去的目录。install.sh 和 dshm service up 都会调用。
sync_workspace_default() {
	local home_host ws
	home_host="$(get_env DSH_HOME_HOST)"
	ws="$(get_env DSH_WORKSPACE)"
	[ -n "$home_host" ] || return 0
	[ "$home_host" != "/dsh" ] || return 0
	[ "$ws" = "/dsh/workspace" ] || return 0
	set_env DSH_WORKSPACE "${home_host}/workspace"
	ok "DSH_WORKSPACE 跟随数据目录改为 ${home_host}/workspace"
}

# 写回一个键。值通过环境变量传给 awk —— 用 `awk -v v=...` 会把值里的
# 反斜杠序列当转义处理（`a\b` 会写成退格符），密码里带 \ 就再也登不进去。
set_env() {
	local k="$1" v="$2" tmp
	tmp="$(mktemp)"
	K="$k" V="$v" awk '
		BEGIN { d=0; k=ENVIRON["K"]; v=ENVIRON["V"] }
		$0 ~ ("^" k "=") { print k "=" v; d=1; next }
		{ print }
		END { if (!d) print k "=" v }
	' "$ENV_FILE" >"$tmp"
	mv "$tmp" "$ENV_FILE"
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

# ── 空则询问、非空跳过 ──────────────────────────────────────────────────────
# ensure_env KEY 说明 [默认值] [可选=1] [校验函数]
# 已有非空值（且不是示例占位符）直接跳过；交互模式下才询问。
ensure_env() {
	local key="$1" label="$2" default="${3:-}" optional="${4:-0}" validator="${5:-}"
	local cur value
	cur="$(get_env "$key")"
	if [ -n "$cur" ] && ! env_is_placeholder "$cur"; then
		# 已有值也要过一遍校验：否则写错的 PROXY_PORT=abc / DSH_BIND=foo
		# 会被"已配置，跳过"悄悄放过去。
		if [ -z "$validator" ] || "$validator" "$cur"; then
			ok "${key} 已配置，跳过"
			return 0
		fi
		if [ "$INTERACTIVE" != "1" ]; then
			die "${key} 的当前值不合规，请在 ${ENV_FILE} 里修正后重试"
		fi
		warn "${key} 的当前值不合规，请重新输入"
	elif [ "$INTERACTIVE" != "1" ]; then
		if [ -n "$default" ]; then
			set_env "$key" "$default"
			ok "${key} 未配置，非交互模式使用默认值：${default}"
			return 0
		fi
		if [ "$optional" = "1" ]; then
			ok "${key} 未配置，可选，跳过"
			return 0
		fi
		die "${key} 未配置且当前为非交互模式；请在 ${ENV_FILE} 里设置后重试"
	fi
	while :; do
		printf '    %s' "$label"
		[ -n "$default" ] && printf '（默认 %s）' "$default"
		printf '：'
		IFS= read -r value || value=""
		value="${value:-$default}"
		if [ -z "$value" ]; then
			if [ "$optional" = "1" ]; then
				ok "${key} 留空，跳过"
				return 0
			fi
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
