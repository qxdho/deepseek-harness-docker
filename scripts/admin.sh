#!/usr/bin/env bash
# DSH Docker 管理面板的安装/管理逻辑，由 dshm source。
#
#   ./dshm admin install [--host|--container]
#   ./dshm admin uninstall [--host|--container|--all]
#   ./dshm admin url | password | status | logs | help
#
# 两种形态：
#   host      —— 静态二进制 + systemd(或 pidfile)。dsh 容器摸不到 docker.sock，
#                安全性最好；需要 root/sudo 才能装到 /usr/local/bin 并常驻。
#   container —— compose profile "admin" 里的独立小容器。免 root，跟 dsh 一起管理，
#                dsh 容器同样不挂 socket（只有这个面板容器挂）。
#
# 调用方（dshm）需已提供：hdr/info/ok/warn/die、read_secret/SECRET、
# env_value/set_env、require_docker/require_env、is_root/cli_dir、
# PROJECT_DIR/ENV_FILE/CONTAINER。

ADMIN_CONTAINER=qxdho-admin
ADMIN_SERVICE=dsh-admin
ADMIN_DEFAULT_IMAGE=ghcr.io/qxdho/deepseek-harness-docker-admin:latest
ADMIN_CONFIG_REL=admin/config.json

admin_help() {
	cat <<EOF

${B}dshm admin${RST} — 安装/管理 DSH Docker 管理面板

  ${B}./dshm admin install${RST}              安装（交互选择宿主 or 容器）
  ${B}./dshm admin install --host${RST}       安装到宿主机（完整功能，安全性最好）
  ${B}./dshm admin install --container${RST}  安装到容器（免 root，随 compose 管理）
  ${B}./dshm admin url${RST}                  打印面板地址
  ${B}./dshm admin password${RST}             修改面板密码
  ${B}./dshm admin status${RST}               面板运行状态
  ${B}./dshm admin logs${RST}                 面板日志
  ${B}./dshm admin uninstall${RST} [--host|--container|--all]

${DIM}面板只调固定几个 Docker Engine 接口，独立密码 + 会话 cookie，默认只监听 127.0.0.1。${RST}
${DIM}注意：管理面板持有 docker.sock，等于宿主 root，请勿对公网直接暴露。${RST}

EOF
}

# ── 找到可用的 dsh-admin 二进制 / 镜像 ───────────────────────────────────────

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

# ── 生成配置 ────────────────────────────────────────────────────────────────

# ADMIN_RUN_MODE=bin|docker；对应 ADMIN_BIN_PATH / ADMIN_IMAGE
admin_hash_password() {
	if [ "$ADMIN_RUN_MODE" = "bin" ]; then
		"$ADMIN_BIN_PATH" -hash
	else
		docker run --rm -i --entrypoint /dsh-admin "$ADMIN_IMAGE" -hash
	fi
}

admin_gen_secret() {
	if [ "$ADMIN_RUN_MODE" = "bin" ]; then
		"$ADMIN_BIN_PATH" -gen-secret
	else
		docker run --rm --entrypoint /dsh-admin "$ADMIN_IMAGE" -gen-secret
	fi
}

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

# admin_write_config 路径 listen socket container
admin_write_config() {
	local path="$1" listen="$2" socket="$3" container="$4" hash secret tmp
	hash="$(printf '%s' "$SECRET" | admin_hash_password)" || die "计算口令哈希失败"
	secret="$(admin_gen_secret)" || die "生成会话密钥失败"
	[ -n "$hash" ] && [ -n "$secret" ] || die "生成配置失败（面板二进制/镜像不可用）"
	mkdir -p "$(dirname "$path")"
	tmp="$(mktemp)"
	cat >"$tmp" <<EOF
{
  "listen": "${listen}",
  "container": "${container}",
  "socket": "${socket}",
  "password_hash": "${hash}",
  "session_secret": "${secret}",
  "audit_log": ""
}
EOF
	mv "$tmp" "$path"
	chmod 600 "$path"
}

# ── host 形态 ───────────────────────────────────────────────────────────────

admin_host_bindir() {
	if [ -w /usr/local/bin ] 2>/dev/null || is_root; then
		printf '%s' /usr/local/bin
	elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
		printf '%s' /usr/local/bin
	else
		printf '%s' "${HOME}/.local/bin"
	fi
}

admin_host_confdir() {
	case "$(admin_host_bindir)" in
	/usr/local/bin) printf '%s' /etc/dsh-admin ;;
	*) printf '%s' "${HOME}/.config/dsh-admin" ;;
	esac
}

admin_host_install() {
	local src bin_dir conf_dir bin cfg port bind unit
	src="$(admin_locate_bin)" || die "找不到 dsh-admin 二进制（可用 DSH_ADMIN_BIN 指定，或安装 go / 放开网络后重试）"
	bin_dir="$(admin_host_bindir)"
	conf_dir="$(admin_host_confdir)"
	bin="$bin_dir/dsh-admin"
	cfg="$conf_dir/config.json"
	port="$(env_value DSH_ADMIN_PORT 3090)"
	bind="$(env_value DSH_ADMIN_BIND 127.0.0.1)"

	ADMIN_RUN_MODE=bin
	ADMIN_BIN_PATH="$src"
	admin_ask_password

	hdr "安装面板二进制"
	mkdir -p "$bin_dir" 2>/dev/null || true
	if [ -w "$bin_dir" ] || is_root; then
		install -m 0755 "$src" "$bin"
	else
		command -v sudo >/dev/null 2>&1 || die "无法写入 $bin_dir"
		sudo mkdir -p "$bin_dir" "$conf_dir"
		sudo install -m 0755 "$src" "$bin"
	fi
	ok "已安装：$bin"

	hdr "写入面板配置"
	admin_write_config "$cfg" "${bind}:${port}" /var/run/docker.sock "$CONTAINER"
	ok "配置：$cfg（权限 600）"

	hdr "启动面板"
	if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] &&
		{ is_root || sudo -n true 2>/dev/null; }; then
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
		setsid "$bin" -config "$cfg" >>"$conf_dir/dsh-admin.log" 2>&1 &
		echo $! >"$conf_dir/dsh-admin.pid"
		ok "已在后台启动（无 systemd，pidfile：$conf_dir/dsh-admin.pid）"
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

admin_host_uninstall() {
	local bin_dir conf_dir pid
	bin_dir="$(admin_host_bindir)"
	conf_dir="$(admin_host_confdir)"
	if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
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
	else
		sudo rm -f "$bin_dir/dsh-admin" 2>/dev/null || true
	fi
	ok "已停止并移除面板二进制（配置保留在 $conf_dir，不需要可自行删除）"
}

# ── container 形态 ──────────────────────────────────────────────────────────

admin_container_image() { env_value DSH_ADMIN_IMAGE "$ADMIN_DEFAULT_IMAGE"; }

admin_container_install() {
	local port bind image
	require_docker; require_env
	port="$(env_value DSH_ADMIN_PORT 3090)"
	bind="$(env_value DSH_ADMIN_BIND 127.0.0.1)"
	image="$(admin_container_image)"

	hdr "准备面板镜像"
	if ! docker image inspect "$image" >/dev/null 2>&1; then
		if [ -d "$PROJECT_DIR/admin" ] && docker compose build "$ADMIN_SERVICE"; then
			ok "已本地构建 $ADMIN_SERVICE"
		elif docker compose pull "$ADMIN_SERVICE"; then
			ok "已拉取镜像"
		else
			die "既无法本地构建也拉不到面板镜像（检查 ./admin 或网络）"
		fi
	fi

	ADMIN_RUN_MODE=docker
	ADMIN_IMAGE="$image"
	admin_ask_password

	hdr "写入面板配置"
	# 容器内监听 0.0.0.0，宿主侧由 ports 绑定控制
	admin_write_config "$PROJECT_DIR/$ADMIN_CONFIG_REL" "0.0.0.0:3090" /var/run/docker.sock "$CONTAINER"
	ok "配置：$ADMIN_CONFIG_REL（权限 600）"

	hdr "启用 compose profile"
	set_env COMPOSE_PROFILES admin
	set_env DSH_ADMIN_PORT "$port"
	set_env DSH_ADMIN_BIND "$bind"
	ok "已写入 .env：COMPOSE_PROFILES=admin"

	hdr "启动面板容器"
	docker compose up -d "$ADMIN_SERVICE"
	admin_print_url "$bind" "$port"
}

admin_container_uninstall() {
	require_docker
	docker compose rm -sf "$ADMIN_SERVICE" >/dev/null 2>&1 || true
	rm -f "$PROJECT_DIR/$ADMIN_CONFIG_REL"
	# 关掉 profile（保留端口设置）
	if [ -f "$ENV_FILE" ]; then
		grep -q '^COMPOSE_PROFILES=admin' "$ENV_FILE" && set_env COMPOSE_PROFILES ""
	fi
	ok "已移除面板容器与配置"
}

# ── 其它子命令 ──────────────────────────────────────────────────────────────

admin_url() {
	local host_cfg listen
	host_cfg="$(admin_host_confdir)/config.json"
	if [ -f "$PROJECT_DIR/$ADMIN_CONFIG_REL" ] || grep -q '^COMPOSE_PROFILES=admin' "$ENV_FILE" 2>/dev/null; then
		admin_print_url "$(env_value DSH_ADMIN_BIND 127.0.0.1)" "$(env_value DSH_ADMIN_PORT 3090)"
		return 0
	fi
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
	if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files dsh-admin.service >/dev/null 2>&1; then
		systemctl --no-pager status dsh-admin 2>&1 | head -12 || true
	elif [ -f "$PROJECT_DIR/$ADMIN_CONFIG_REL" ]; then
		require_docker
		docker ps -a --filter "name=$ADMIN_CONTAINER" --format '{{.Names}}  {{.Status}}'
	else
		local conf pid
		conf="$(admin_host_confdir)/dsh-admin.pid"
		[ -f "$conf" ] && info "pid $(cat "$conf")（运行中：$(kill -0 "$(cat "$conf")" 2>/dev/null && echo 是 || echo 否)）" || info "未发现运行中的面板"
	fi
}

admin_logs() {
	if [ -f "$PROJECT_DIR/$ADMIN_CONFIG_REL" ]; then
		require_docker
		docker logs --tail 100 "$ADMIN_CONTAINER" 2>&1 || true
	else
		tail -n 100 "$(admin_host_confdir)/dsh-admin.log" 2>/dev/null || info "（暂无日志）"
	fi
}

admin_password() {
	admin_ask_password
	if [ -f "$PROJECT_DIR/$ADMIN_CONFIG_REL" ]; then
		ADMIN_RUN_MODE=docker
		ADMIN_IMAGE="$(admin_container_image)"
		admin_write_config "$PROJECT_DIR/$ADMIN_CONFIG_REL" "0.0.0.0:3090" /var/run/docker.sock "$CONTAINER"
		docker compose up -d --force-recreate "$ADMIN_SERVICE"
		ok "面板密码已更新，容器已重建"
	else
		admin_write_config "$(admin_host_confdir)/config.json" \
			"$(env_value DSH_ADMIN_BIND 127.0.0.1):$(env_value DSH_ADMIN_PORT 3090)" \
			/var/run/docker.sock "$CONTAINER"
		if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
			systemctl restart dsh-admin 2>/dev/null || sudo systemctl restart dsh-admin 2>/dev/null || true
		fi
		ok "面板密码已更新（已重写配置；非 systemd 部署请手动重启面板进程）"
	fi
}

# ── 交互入口 ────────────────────────────────────────────────────────────────

admin_choose_mode() {
	if [ ! -t 0 ]; then
		printf '%s' container
		return 0
	fi
	local ans
	printf '    安装到哪？  %s1%s 宿主机（完整功能，推荐）   %s2%s 容器（免 root）\n' "$B" "$RST" "$B" "$RST"
	printf '    选择 [1/2]（默认 1）：'
	IFS= read -r ans || ans=""
	case "$ans" in
	2 | c | container) printf '%s' container ;;
	*) printf '%s' host ;;
	esac
}

# dshm admin <sub> [args]
admin_dispatch() {
	local sub="${1:-help}"
	shift || true
	case "$sub" in
	install)
		case "${1:-}" in
		--host | -H) admin_host_install ;;
		--container | -c) admin_container_install ;;
		"") case "$(admin_choose_mode)" in
			host) admin_host_install ;;
			container) admin_container_install ;;
			esac ;;
		*) die "未知参数：$1（用 --host 或 --container）" ;;
		esac
		;;
	uninstall | remove)
		case "${1:-}" in
		--host) admin_host_uninstall ;;
		--container) admin_container_uninstall ;;
		--all | "")
			admin_host_uninstall || true
			admin_container_uninstall || true
			;;
		*) die "未知参数：$1" ;;
		esac
		;;
	url | address) admin_url ;;
	password | pw) admin_password ;;
	status) admin_status ;;
	logs | log) admin_logs ;;
	help | -h | --help | "") admin_help ;;
	*) die "未知子命令：admin $sub（运行 ./dshm admin help）" ;;
	esac
}
