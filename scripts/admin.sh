#!/usr/bin/env bash
# DSH Docker 管理面板的安装/管理逻辑，由 dshm source。
#
#   ./dshm admin install
#   ./dshm admin url | password | status | logs
#   ./dshm admin uninstall
#
# 面板是一个**静态二进制，直接跑在宿主机上**（不额外起容器）：
#   - 有 root/可 sudo：装到 /usr/local/bin + /etc/dsh-admin，用 systemd 常驻、开机自启；
#   - 没有 root：装到 ~/.local/bin + ~/.config/dsh-admin，用 pidfile 后台运行（不随开机自启）。
#
# 这样 dsh 容器始终碰不到 docker.sock，面板是唯一持有它的组件。
#
# 调用方（dshm）需已提供：hdr/info/ok/warn/die、read_secret/SECRET、
# env_value、is_root、PROJECT_DIR/CONTAINER。

ADMIN_SERVICE=dsh-admin

admin_help() {
	cat <<EOF

${B}dshm admin${RST} — 安装/管理 DSH Docker 管理面板（宿主进程，不额外起容器）

  ${B}./dshm admin install${RST}     安装（有 root 用 /usr/local/bin + systemd；
                             没有 root 就装 ~/.local/bin + pidfile，不需要 sudo）
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

# ── 安装位置：有 root 走系统目录，没有就走用户目录 ─────────────────────────

admin_bindir() {
	if [ -w /usr/local/bin ] 2>/dev/null || is_root; then
		printf '%s' /usr/local/bin
	elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
		printf '%s' /usr/local/bin
	else
		printf '%s' "${HOME}/.local/bin"
	fi
}

admin_confdir() {
	case "$(admin_bindir)" in
	/usr/local/bin) printf '%s' /etc/dsh-admin ;;
	*) printf '%s' "${HOME}/.config/dsh-admin" ;;
	esac
}

admin_has_systemd() {
	command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

admin_can_systemd() {
	admin_has_systemd && { is_root || { command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; }; }
}

# ── 安装 / 卸载 ─────────────────────────────────────────────────────────────

admin_install() {
	local src bin_dir conf_dir bin cfg port bind unit
	src="$(admin_locate_bin)" || die "找不到 dsh-admin 二进制（可用 DSH_ADMIN_BIN 指定，或安装 go / 放开网络后重试）"
	bin_dir="$(admin_bindir)"
	conf_dir="$(admin_confdir)"
	bin="$bin_dir/dsh-admin"
	cfg="$conf_dir/config.json"
	port="$(env_value DSH_ADMIN_PORT 3090)"
	bind="$(env_value DSH_ADMIN_BIND 127.0.0.1)"

	ADMIN_BIN_PATH="$src"
	admin_ask_password

	hdr "安装面板二进制"
	if [ -w "$bin_dir" ] || is_root; then
		mkdir -p "$bin_dir"
		install -m 0755 "$src" "$bin"
	elif command -v sudo >/dev/null 2>&1; then
		sudo mkdir -p "$bin_dir" "$conf_dir"
		sudo install -m 0755 "$src" "$bin"
	else
		mkdir -p "$bin_dir" 2>/dev/null || die "无法写入 $bin_dir"
		install -m 0755 "$src" "$bin" 2>/dev/null || die "无法写入 $bin_dir"
	fi
	ok "已安装：$bin"
	# 后续要调面板二进制算哈希；若装到系统目录但当前非 root，用源二进制即可
	ADMIN_BIN_PATH="$src"

	hdr "写入面板配置"
	# 目录可能还不存在，先建（免 root 时就是 ~/.config/dsh-admin）
	mkdir -p "$conf_dir" 2>/dev/null || true
	if [ -w "$conf_dir" ] || is_root; then
		admin_write_config "$cfg" "${bind}:${port}" /var/run/docker.sock "$CONTAINER" \
			"$PROJECT_DIR" "$(admin_detect_compose_project)"
	elif command -v sudo >/dev/null 2>&1; then
		# 目录归 root 时：先在当前用户可写处生成，再 sudo 放进去，避免权限纠缠
		local staging
		staging="$(mktemp)"
		admin_write_config "$staging" "${bind}:${port}" /var/run/docker.sock "$CONTAINER" \
			"$PROJECT_DIR" "$(admin_detect_compose_project)"
		sudo mkdir -p "$conf_dir"
		sudo install -m 0600 "$staging" "$cfg"
		rm -f "$staging"
	else
		die "无法写入 $conf_dir"
	fi
	ok "配置：$cfg（权限 600）"

	hdr "启动面板"
	if admin_can_systemd; then
		unit="/etc/systemd/system/dsh-admin.service"
		tmp="$(mktemp)"
		cat >"$tmp" <<EOF
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
			install -m 0644 "$tmp" "$unit"
			systemctl daemon-reload
			systemctl enable --now dsh-admin
		else
			sudo install -m 0644 "$tmp" "$unit"
			sudo systemctl daemon-reload
			sudo systemctl enable --now dsh-admin
		fi
		rm -f "$tmp"
		ok "已注册 systemd 服务 dsh-admin（开机自启）"
	else
		# 无 systemd（或没有权限）：用 pidfile 后台跑。免 root 场景走的就是这条。
		if [ -f "$conf_dir/dsh-admin.pid" ] && kill -0 "$(cat "$conf_dir/dsh-admin.pid")" 2>/dev/null; then
			kill "$(cat "$conf_dir/dsh-admin.pid")" 2>/dev/null || true
			sleep 0.3
		fi
		setsid "$bin_dir/dsh-admin" -config "$cfg" >>"$conf_dir/dsh-admin.log" 2>&1 &
		echo $! >"$conf_dir/dsh-admin.pid"
		ok "已在后台启动（无 systemd；pidfile：$conf_dir/dsh-admin.pid）"
		warn "这种方式不会随开机自启；需要自启请加进 crontab 或改用有 root 的 systemd 部署"
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
	local bin_dir conf_dir pid
	bin_dir="$(admin_bindir)"
	conf_dir="$(admin_confdir)"
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
	pid="$conf_dir/dsh-admin.pid"
	if [ -f "$pid" ]; then
		kill "$(cat "$pid")" 2>/dev/null || true
		rm -f "$pid"
	fi
	if [ -w "$bin_dir" ] || is_root; then
		rm -f "$bin_dir/dsh-admin"
	elif command -v sudo >/dev/null 2>&1; then
		sudo rm -f "$bin_dir/dsh-admin" 2>/dev/null || true
	fi
	ok "已停止并移除面板二进制（配置保留在 $conf_dir，不需要可自行删除）"
}

# ── 其它子命令 ──────────────────────────────────────────────────────────────

admin_url() {
	local host_cfg listen
	host_cfg="$(admin_confdir)/config.json"
	if [ -f "$host_cfg" ]; then
		listen="$(sed -n 's/.*"listen"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$host_cfg" | head -1)"
		if [ -n "$listen" ]; then
			admin_print_url "${listen%%:*}" "${listen##*:}"
			return 0
		fi
	fi
	info "尚未安装管理面板（先运行 ./dshm admin install）"
}

admin_status() {
	local conf pid
	if admin_has_systemd && systemctl list-unit-files dsh-admin.service >/dev/null 2>&1; then
		systemctl --no-pager status dsh-admin 2>&1 | head -12 || true
		return
	fi
	conf="$(admin_confdir)/dsh-admin.pid"
	if [ -f "$conf" ] && kill -0 "$(cat "$conf")" 2>/dev/null; then
		pid="$(cat "$conf")"
		info "运行中（pid ${pid}）"
	else
		info "未在运行"
	fi
}

admin_logs() {
	tail -n 100 "$(admin_confdir)/dsh-admin.log" 2>/dev/null || info "（暂无日志）"
}

admin_password() {
	ADMIN_BIN_PATH="$(admin_locate_bin)" || die "找不到 dsh-admin 二进制"
	admin_ask_password
	admin_write_config "$(admin_confdir)/config.json" \
		"$(env_value DSH_ADMIN_BIND 127.0.0.1):$(env_value DSH_ADMIN_PORT 3090)" \
		/var/run/docker.sock "$CONTAINER" "$PROJECT_DIR" "$(admin_detect_compose_project)"
	if admin_has_systemd; then
		systemctl restart dsh-admin 2>/dev/null || sudo systemctl restart dsh-admin 2>/dev/null || true
	else
		local conf pid
		conf="$(admin_confdir)"
		if [ -f "$conf/dsh-admin.pid" ]; then
			kill "$(cat "$conf/dsh-admin.pid")" 2>/dev/null || true
			setsid "$(admin_bindir)/dsh-admin" -config "$conf/config.json" >>"$conf/dsh-admin.log" 2>&1 &
			echo $! >"$conf/dsh-admin.pid"
		fi
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
			die "已移除容器版面板：宿主模式在没有 root 时会装到 ~/.local/bin 并用 pidfile 运行，不需要 sudo"
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
