#!/usr/bin/env bash
# DSH Docker 管理面板的安装/管理逻辑，由 dshm source。
#
#   ./dshm admin install
#   ./dshm admin url | password | status | logs
#   ./dshm admin uninstall
#
# 面板是一个**静态二进制，直接跑在宿主机上**（不额外起容器）：
# 二进制、配置、pidfile、日志都在同一个目录（默认 /dsh-manager，可用 DSH_ADMIN_DIR 改）：
#   - 有 root/可 sudo：systemd 常驻、开机自启；
#   - 没有 root：装到你自己拥有的目录（如 $HOME/dsh-manager），pidfile 后台运行。
#
# 这样 dsh 容器始终碰不到 docker.sock，面板是唯一持有它的组件。
#
# 调用方（dshm）需已提供：hdr/info/ok/warn/die、read_secret/SECRET、
# env_value、is_root、PROJECT_DIR/CONTAINER。

ADMIN_SERVICE=dsh-admin

admin_help() {
	cat <<EOF

${B}dshm admin${RST} — 安装/管理 DSH Docker 管理面板（宿主进程，不额外起容器）

  ${B}./dshm admin install${RST}     安装（默认目录 /dsh-manager；可用 DSH_ADMIN_DIR 改。
                             有 root 用 systemd 常驻，没有就装你自己目录 + pidfile）
  ${B}./dshm admin url${RST}         打印面板地址
  ${B}./dshm admin password${RST}    修改面板密码
  ${B}./dshm admin status${RST}      面板运行状态
  ${B}./dshm admin logs${RST}        面板日志
  ${B}./dshm admin uninstall${RST}   停止并移除面板

${DIM}面板只调固定几个 Docker Engine 接口，独立密码 + 会话 cookie，默认只监听 127.0.0.1。${RST}
${DIM}注意：管理面板持有 docker.sock，等于宿主 root，请勿对公网直接暴露。${RST}

EOF
}

# ── 找到可用的 dsh-admin 二进制 ─────────────────────────────────────────────

admin_arch() {
	case "$(uname -m)" in
	x86_64 | amd64) printf '%s' amd64 ;;
	aarch64 | arm64) printf '%s' arm64 ;;
	armv7l) printf '%s' armv7 ;;
	*) printf '%s' unknown ;;
	esac
}

# 优先：环境变量指定 → 仓库内已构建 → PATH → 本地 go 构建 → Releases 下载
admin_locate_bin() {
	local candidate="$PROJECT_DIR/admin/dsh-admin" arch url
	if [ -n "${DSH_ADMIN_BIN:-}" ] && [ -x "$DSH_ADMIN_BIN" ]; then
		printf '%s' "$DSH_ADMIN_BIN"
		return 0
	fi
	[ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
	if command -v dsh-admin >/dev/null 2>&1; then
		command -v dsh-admin
		return 0
	fi
	if command -v go >/dev/null 2>&1; then
		info "用本机 Go 构建 dsh-admin…" >&2
		if (cd "$PROJECT_DIR/admin" && go build -trimpath -ldflags='-s -w' -o dsh-admin .) >&2; then
			[ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
		fi
	fi
	arch="$(admin_arch)"
	if [ "$arch" != "unknown" ] && command -v curl >/dev/null 2>&1; then
		url="https://github.com/qxdho/deepseek-harness-docker/releases/latest/download/dsh-admin-linux-${arch}"
		info "从 Releases 下载 ${url}" >&2
		if curl -fsSL -o "$candidate" "$url" && chmod +x "$candidate"; then
			printf '%s' "$candidate"
			return 0
		fi
		rm -f "$candidate"
	fi
	return 1
}

# ── 口令与会话密钥（都交给面板二进制算，dshm 只负责拼配置）─────────────────

admin_hash_password() { "$ADMIN_BIN_PATH" -hash; }
admin_gen_secret() { "$ADMIN_BIN_PATH" -gen-secret; }

admin_ask_password() {
	local pw=""
	if [ -n "${DSH_ADMIN_PASSWORD:-}" ]; then
		SECRET="$DSH_ADMIN_PASSWORD"
	fi
	if [ -z "${SECRET:-}" ]; then
		[ -t 0 ] || die "非交互模式下请用 DSH_ADMIN_PASSWORD 提供面板密码"
		while :; do
			read_secret "  面板密码（至少 12 位）："
			pw="$SECRET"
			if [ "${#pw}" -lt 12 ]; then
				warn "至少 12 位"
				continue
			fi
			read_secret "  再输一次确认："
			[ "$pw" = "$SECRET" ] || { warn "两次输入不一致"; continue; }
			break
		done
		SECRET="$pw"
	fi
	[ "${#SECRET}" -ge 12 ] || die "面板密码至少 12 位"
}

# admin_write_config 路径 listen socket container [project_dir] [compose_project]
admin_write_config() {
	local path="$1" listen="$2" socket="$3" container="$4"
	local project_dir="${5:-$PROJECT_DIR}" compose_project="${6:-}"
	local hash secret tmp
	hash="$(printf '%s' "$SECRET" | admin_hash_password)" || die "计算口令哈希失败"
	secret="$(admin_gen_secret)" || die "生成会话密钥失败"
	[ -n "$hash" ] && [ -n "$secret" ] || die "生成配置失败（面板二进制不可用）"
	mkdir -p "$(dirname "$path")"
	tmp="$(mktemp)"
	cat >"$tmp" <<EOF
{
  "listen": "${listen}",
  "container": "${container}",
  "socket": "${socket}",
  "password_hash": "${hash}",
  "session_secret": "${secret}",
  "audit_log": "",
  "project_dir": "${project_dir}",
  "compose_project": "${compose_project}",
  "allow_exec": true
}
EOF
	mv "$tmp" "$path"
	chmod 600 "$path"
}

# 当前 compose 项目名。带上它，命令台里的 `dshm service …` 才会作用到同一个
# compose 项目（项目名默认取目录 basename，目录改名/软链后会对不上）。
admin_detect_compose_project() {
	command -v docker >/dev/null 2>&1 || return 0
	docker inspect "$CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true
}

# ── 安装位置 ────────────────────────────────────────────────────────────────
#
# 二进制、配置、pidfile、日志全部放同一个目录，默认 /dsh-manager。
# 想换地方就设 DSH_ADMIN_DIR（例如 $HOME/dsh-manager，免 sudo）。
# 注意：默认 /dsh-manager 在根目录下，首次创建需要 sudo。
admin_dir() {
	local d
	d="$(env_value DSH_ADMIN_DIR /dsh-manager)"
	case "$d" in
	"~") d="$HOME" ;;
	"~/"*) d="$HOME/${d#\~/}" ;;
	/*) ;;
	*) d="$PROJECT_DIR/${d#./}" ;;
	esac
	printf '%s' "$d"
}

admin_has_systemd() {
	command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

admin_can_systemd() {
	admin_has_systemd && { is_root || { command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; }; }
}

# ── 安装 / 卸载 ─────────────────────────────────────────────────────────────

admin_install() {
	local src dir bin cfg unit port bind staging
	src="$(admin_locate_bin)" || die "找不到 dsh-admin 二进制（可用 DSH_ADMIN_BIN 指定，或安装 go / 放开网络后重试）"
	dir="$(admin_dir)"
	bin="$dir/dsh-admin"
	cfg="$dir/config.json"
	port="$(env_value DSH_ADMIN_PORT 3090)"
	bind="$(env_value DSH_ADMIN_BIND 127.0.0.1)"

	ADMIN_BIN_PATH="$src"
	admin_ask_password

	hdr "安装面板到 ${dir}"
	# 默认 /dsh-manager 在根目录下，首次创建要 sudo；没有 root 就换 DSH_ADMIN_DIR
	if ! mkdir -p "$dir" 2>/dev/null; then
		if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
			sudo mkdir -p "$dir"
		else
			die "无法创建 ${dir}
      默认 /dsh-manager 在根目录下，需要 sudo。
      没有 root 的话，在 .env 里加一行：DSH_ADMIN_DIR=\$HOME/dsh-manager，再重试"
		fi
	fi
	if [ -w "$dir" ]; then
		install -m 0755 "$src" "$bin"
	else
		sudo install -m 0755 "$src" "$bin"
	fi
	ok "二进制：$bin"

	hdr "写入面板配置"
	# 目录归 root 时：先在可写处生成，再 sudo 放进去，避免权限纠缠
	if [ -w "$dir" ]; then
		admin_write_config "$cfg" "${bind}:${port}" /var/run/docker.sock "$CONTAINER" \
			"$PROJECT_DIR" "$(admin_detect_compose_project)"
	else
		staging="$(mktemp)"
		admin_write_config "$staging" "${bind}:${port}" /var/run/docker.sock "$CONTAINER" \
			"$PROJECT_DIR" "$(admin_detect_compose_project)"
		sudo install -m 0600 "$staging" "$cfg"
		rm -f "$staging"
	fi
	ok "配置：$cfg（权限 600）"

	hdr "启动面板"
	if admin_can_systemd; then
		# unit 必须放 systemd 会扫描的目录；里面用绝对路径，二进制放哪都行
		unit="/etc/systemd/system/dsh-admin.service"
		staging="$(mktemp)"
		cat >"$staging" <<EOF
[Unit]
Description=DSH Docker admin panel
After=network.target docker.service

[Service]
ExecStart=${bin} -config ${cfg}
Restart=on-failure
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
		if is_root; then
			install -m 0644 "$staging" "$unit"
			systemctl daemon-reload
			systemctl enable --now dsh-admin
		else
			sudo install -m 0644 "$staging" "$unit"
			sudo systemctl daemon-reload
			sudo systemctl enable --now dsh-admin
		fi
		rm -f "$staging"
		ok "已注册 systemd 服务 dsh-admin（开机自启）"
	elif [ -w "$dir" ]; then
		# 无 systemd（或没有权限）：pidfile 后台跑（免 root 场景走这条）
		if [ -f "$dir/dsh-admin.pid" ] && kill -0 "$(cat "$dir/dsh-admin.pid")" 2>/dev/null; then
			kill "$(cat "$dir/dsh-admin.pid")" 2>/dev/null || true
			sleep 0.3
		fi
		setsid "$bin" -config "$cfg" >>"$dir/dsh-admin.log" 2>&1 &
		echo $! >"$dir/dsh-admin.pid"
		ok "已在后台启动（无 systemd；pidfile：$dir/dsh-admin.pid）"
		warn "这种方式不会随开机自启；要自启请用有 root 的 systemd 部署"
	else
		die "${dir} 归 root，且没有可用的 systemd。
      把 .env 的 DSH_ADMIN_DIR 设成你自己的目录（如 \$HOME/dsh-manager）再重试"
	fi
	admin_print_url "$bind" "$port"
}

admin_print_url() {
	local bind="$1" port="$2"
	hdr "面板地址"
	if [ "$bind" = "0.0.0.0" ]; then
		printf '    %shttp://<服务器IP>:%s/%s\n' "$B" "$port" "$RST"
	else
		printf '    %shttp://127.0.0.1:%s/%s\n' "$B" "$port" "$RST"
		printf '    远程访问用 SSH 隧道：%sssh -L %s:127.0.0.1:%s user@服务器%s\n' "$DIM" "$port" "$port" "$RST"
	fi
}

admin_uninstall() {
	local dir pid
	dir="$(admin_dir)"
	if admin_has_systemd; then
		if is_root; then
			systemctl disable --now dsh-admin 2>/dev/null || true
			rm -f /etc/systemd/system/dsh-admin.service
			systemctl daemon-reload 2>/dev/null || true
		elif command -v sudo >/dev/null 2>&1; then
			sudo systemctl disable --now dsh-admin 2>/dev/null || true
			sudo rm -f /etc/systemd/system/dsh-admin.service
			sudo systemctl daemon-reload 2>/dev/null || true
		fi
	fi
	pid="$dir/dsh-admin.pid"
	if [ -f "$pid" ]; then
		kill "$(cat "$pid")" 2>/dev/null || true
		rm -f "$pid"
	fi
	if [ -w "$dir" ]; then
		rm -f "$dir/dsh-admin"
	elif command -v sudo >/dev/null 2>&1; then
		sudo rm -f "$dir/dsh-admin" 2>/dev/null || true
	fi
	ok "已停止并移除二进制；配置保留在 $dir/config.json（不需要可自行删掉整个 ${dir}）"
}

# ── 其它子命令 ──────────────────────────────────────────────────────────────

admin_url() {
	local cfg listen
	cfg="$(admin_dir)/config.json"
	if [ -f "$cfg" ]; then
		listen="$(sed -n 's/.*"listen"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | head -1)"
		if [ -n "$listen" ]; then
			admin_print_url "${listen%%:*}" "${listen##*:}"
			return 0
		fi
	fi
	info "尚未安装管理面板（先运行 ./dshm admin install）"
}

admin_status() {
	local dir pid
	dir="$(admin_dir)"
	if admin_has_systemd && systemctl list-unit-files dsh-admin.service >/dev/null 2>&1; then
		systemctl --no-pager status dsh-admin 2>&1 | head -12 || true
		return
	fi
	if [ -f "$dir/dsh-admin.pid" ] && kill -0 "$(cat "$dir/dsh-admin.pid")" 2>/dev/null; then
		pid="$(cat "$dir/dsh-admin.pid")"
		info "运行中（pid ${pid}，目录 ${dir}）"
	else
		info "未在运行（安装目录：${dir}）"
	fi
}

admin_logs() {
	tail -n 100 "$(admin_dir)/dsh-admin.log" 2>/dev/null || info "（暂无日志）"
}

admin_password() {
	local dir staging
	dir="$(admin_dir)"
	ADMIN_BIN_PATH="$(admin_locate_bin)" || die "找不到 dsh-admin 二进制"
	admin_ask_password
	_set() {
		admin_write_config "$1" \
			"$(env_value DSH_ADMIN_BIND 127.0.0.1):$(env_value DSH_ADMIN_PORT 3090)" \
			/var/run/docker.sock "$CONTAINER" "$PROJECT_DIR" "$(admin_detect_compose_project)"
	}
	if [ -w "$dir" ]; then
		_set "$dir/config.json"
	else
		staging="$(mktemp)"
		_set "$staging"
		sudo install -m 0600 "$staging" "$dir/config.json"
		rm -f "$staging"
	fi
	if admin_has_systemd; then
		systemctl restart dsh-admin 2>/dev/null || sudo systemctl restart dsh-admin 2>/dev/null || true
	elif [ -f "$dir/dsh-admin.pid" ]; then
		kill "$(cat "$dir/dsh-admin.pid")" 2>/dev/null || true
		setsid "$dir/dsh-admin" -config "$dir/config.json" >>"$dir/dsh-admin.log" 2>&1 &
		echo $! >"$dir/dsh-admin.pid"
	fi
	ok "面板密码已更新"
}

# ── 入口 ────────────────────────────────────────────────────────────────────

# dshm admin <sub> [args]
admin_dispatch() {
	local sub="${1:-help}"
	shift || true
	case "$sub" in
	install)
		case "${1:-}" in
		"" | --host | -H) admin_install ;;
		--container | -c)
			die "已移除容器版面板：宿主模式装到 DSH_ADMIN_DIR（默认 /dsh-manager），不需要额外容器"
			;;
		*) die "未知参数：$1（本命令不再接受参数）" ;;
		esac
		;;
	uninstall | remove) admin_uninstall ;;
	url | address) admin_url ;;
	password | pw) admin_password ;;
	status) admin_status ;;
	logs | log) admin_logs ;;
	help | -h | --help | "") admin_help ;;
	*) die "未知子命令：admin $sub（运行 ./dshm admin help）" ;;
	esac
}
