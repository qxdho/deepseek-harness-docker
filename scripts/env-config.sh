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

# 把 .env 里的历史默认值对齐到当前默认值。install.sh 与 dshm service up 都会调用。
#
#   1) 数据目录换了、工作区还停在 /dsh/workspace → 工作区跟着数据目录走。
#      compose 里工作区默认值写死为 /dsh/workspace，只能在这里对齐，否则只改
#      DSH_HOME_HOST 会留下一个 /dsh/workspace —— 在宿主上多半是 root 建的、
#      容器写不进去的目录。
#   2) 容器内数据目录还是旧默认 /home/node/.dsh → 改成 /dsh。这里只改**容器内
#      路径**，宿主一侧的 DSH_HOME_HOST 不动，所以不会搬动任何数据，只是让挂载点
#      与文档/默认值保持一致（旧值会让 dshm、文档命令里的路径对不上）。
normalize_defaults() {
	local home_host ws home
	home_host="$(get_env DSH_HOME_HOST)"
	ws="$(get_env DSH_WORKSPACE)"
	if [ -n "$home_host" ] && [ "$home_host" != "/dsh" ] && [ "$ws" = "/dsh/workspace" ]; then
		set_env DSH_WORKSPACE "${home_host}/workspace"
		ok "DSH_WORKSPACE 跟随数据目录改为 ${home_host}/workspace"
	fi
	home="$(get_env DSH_HOME)"
	if [ "$home" = "/home/node/.dsh" ]; then
		set_env DSH_HOME "/dsh"
		ok "DSH_HOME 由旧默认 /home/node/.dsh 改为当前默认 /dsh（宿主目录不变）"
	fi
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
			ok "${key} 已配置，跳过"
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
