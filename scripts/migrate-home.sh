#!/usr/bin/env bash
# 旧版把 dsh 的数据根（DSH_HOME）放在命名卷里（compose 建的卷名是
# <项目名>_dsh-home），新版改为宿主 bind 挂载。这里实现「把旧卷内容搬到
# DSH_HOME_HOST」，由 install.sh 与 dshm 共用，避免两处各写一份搬运逻辑。
#
# 调用方需先定义输出函数 hdr/info/ok/warn/die，并 source scripts/env-config.sh
# （需要 env_value）。依赖命令：docker。
#
# 安全约定：
#   * 源卷一律只读挂载，复制过程不修改、结束后也不删除原卷；
#   * 目标目录非空就绝不写入（返回 2），避免覆盖用户已有数据；
#   * 仍有容器挂着旧卷时，只停「看起来就是本项目」的容器，其他容器不动。

# 旧卷名：compose 建的是 <项目名>_dsh-home，也有人手工建 dsh-home
legacy_dsh_home_volume() {
	command -v docker >/dev/null 2>&1 || return 0
	docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '(^|_)dsh-home$' | head -n1 || true
}

# 目录为空（不存在也算空）
dest_is_empty() {
	[ -d "$1" ] || return 0
	# **读不了不算空**：`ls` 失败（权限/IO）时它的输出也是空的，若直接判"空"，
	# 后面那道「目标非空就不写」的唯一护栏就失效了，root 身份的 docker 会把旧卷
	# 数据灌进一个可能已有数据的目录。所以读取失败一律按「非空」处理（fail-closed），
	# 宁可让用户手工确认，也不能猜。
	ls -A "$1" >/dev/null 2>&1 || return 1
	[ -z "$(ls -A "$1")" ]
}

# 当前仍挂载该卷的容器 id
containers_using_volume() {
	docker ps -q --filter "volume=$1" 2>/dev/null || true
}

# 停掉仍在使用旧卷的本项目容器。全是自己的容器返回 0，遇到别人的容器返回 1
# （调用方据此跳过迁移，而不是把别人的容器停了）。
stop_own_containers_using_volume() {
	local vol="$1" id name image
	for id in $(containers_using_volume "$vol"); do
		name="$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's|^/||')"
		image="$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null)"
		case "${name:-}:${image:-}" in
		dsh:* | qxdho-dsh:* | *:dsh | *:dsh:* | *:*deepseek-harness-docker*)
			warn "停止仍挂着旧卷的容器 ${name}（${image}）"
			docker stop "$id" >/dev/null 2>&1 || true
			;;
		*)
			warn "容器 ${name:-$id}（${image:-未知镜像}）仍在使用旧卷，未自动停止"
			return 1
			;;
		esac
	done
	return 0
}

# migrate_legacy_home [auto|explicit]
#   0 = 已迁移
#   1 = 没有旧命名卷，无需迁移
#   2 = 目标目录已有数据，不动
#   3 = auto 模式下放弃（旧卷被别的容器占用 / 建不了目录 / 复制失败）
# explicit 模式下，上述失败原因一律 die（命令是用户主动敲的，要给出明确结论）。
migrate_legacy_home() {
	local mode="${1:-auto}" dest vol cu cg
	dest="$(env_value DSH_HOME_HOST /dsh)"
	vol="$(legacy_dsh_home_volume)"
	[ -n "$vol" ] || return 1
	dest_is_empty "$dest" || return 2

	hdr "迁移旧版数据卷"
	info "检测到旧版命名卷 ${vol}（旧版把数据放在卷里，新版改为宿主目录）"
	info "目标：${dest}（源卷只读挂载，不修改也不删除原卷）"

	if [ -n "$(containers_using_volume "$vol")" ] && ! stop_own_containers_using_volume "$vol"; then
		if [ "$mode" = "explicit" ]; then
			die "请先停止上述容器，再执行 ./dshm migrate"
		fi
		warn "已跳过自动迁移；确认这些容器可以停掉后执行 ./dshm migrate"
		return 3
	fi

	if ! mkdir -p "$dest" 2>/dev/null; then
		if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
			if ! sudo mkdir -p "$dest"; then
				[ "$mode" = "explicit" ] && die "无法创建 ${dest}"
				warn "无法创建 ${dest}，已跳过自动迁移"
				return 3
			fi
		else
			if [ "$mode" = "explicit" ]; then
				die "无法创建 ${dest}
      默认 /dsh 在根目录下，需要 sudo；也可以把 .env 的 DSH_HOME_HOST 改成你自己的目录"
			fi
			warn "无法创建 ${dest}（默认 /dsh 需要 sudo；可在 .env 里把 DSH_HOME_HOST 改成你自己的目录）"
			warn "已跳过自动迁移；数据结构不变，按上面提示改完再执行 ./dshm service up"
			return 3
		fi
	fi

	# 先拷到目标目录**旁边**的临时目录，成功后再改名进去。
	#
	# 为什么不能直接写目标目录：tar 失败时目标里已经留了半份数据，而下次运行会因为
	# 「目标非空」直接跳过（dest_is_empty 判定），用户拿到的是一份半迁移的数据目录、
	# 且提示写着「原数据未改动，可重试」（源确实没动，但目标已经是半成品）。
	# 用临时目录 + 改名后，失败时目标仍保持原样，重试也仍然是「空 → 可以迁移」。
	local tmp_dest="${dest}.migrating.$$"
	rm -rf "$tmp_dest"
	mkdir -p "$tmp_dest" || return 3
	if ! docker run --rm --user 0:0 \
		-v "${vol}:/from:ro" -v "${tmp_dest}:/to" alpine:3.21 \
		sh -c 'set -o pipefail 2>/dev/null; cd /from && tar cf - . | (cd /to && tar xf -)'; then
		rm -rf "$tmp_dest" 2>/dev/null || true
		if [ "$mode" = "explicit" ]; then
			die "迁移失败（源卷 ${vol}）；原数据与目标目录均未改动，可重试"
		fi
		warn "迁移失败（源卷 ${vol}）；原数据与目标目录均未改动，可重试 ./dshm migrate"
		return 3
	fi
	# 目标此刻被 dest_is_empty 保证过是空的（或不存在），改名是原子的
	if [ -e "$dest" ]; then
		rmdir "$dest" 2>/dev/null || true
	fi
	if ! mv "$tmp_dest" "$dest" 2>/dev/null; then
		rm -rf "$tmp_dest" 2>/dev/null || true
		[ "$mode" = "explicit" ] && die "迁移的数据无法落位到 ${dest}；原数据未改动"
		warn "迁移的数据无法落位到 ${dest}；原数据未改动"
		return 3
	fi

	cu="$(env_value DSH_UID 1000)"
	cg="$(env_value DSH_GID 1000)"
	# 属主修复：docker 是以 root 写的，所以拷出来的文件属主是 root。
	#   * 需要 root 才能改属主；不是 root 时**必须**确认有没有免密 sudo ——
	#     原来只判 `command -v sudo`，需要密码时 `sudo chown` 会卡在密码提示上
	#     （非交互调用直接挂住）。
	#   * 改完要**校验**，失败就明确失败：属主不对的话容器起不来，那时再报错就晚了。
	#   * 有些目标目录本来就属于正确 uid，不需要改，所以先判后改。
	owner_ok() {
		local o
		o="$(stat -c '%u:%g' "$1" 2>/dev/null || echo "")"
		[ "$o" = "${cu}:${cg}" ]
	}
	if ! owner_ok "$dest"; then
		if [ "$(id -u)" = "0" ]; then
			chown -R "${cu}:${cg}" "$dest" 2>/dev/null || true
		elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
			sudo -n chown -R "${cu}:${cg}" "$dest" 2>/dev/null || true
		else
			warn "数据已迁移，但无法把 ${dest} 的属主改成 ${cu}:${cg}（需要 root 或免密 sudo）。"
			info "请手工执行：sudo chown -R ${cu}:${cg} ${dest}"
			info "属主不对的话容器会因无法写入而反复重启。"
			return 3
		fi
		if ! owner_ok "$dest"; then
			warn "改属主后 ${dest} 仍不是 ${cu}:${cg}，容器可能起不来。"
			info "请手工执行：sudo chown -R ${cu}:${cg} ${dest}"
			return 3
		fi
	fi

	ok "旧卷数据已迁移：${vol} → ${dest}"
	info "旧卷保留在原处；确认新版正常后可删除：docker volume rm ${vol}"
	return 0
}

# 启动前调用：只有「存在旧卷」且「目标目录为空」时才自动迁移，其余情况不干预。
auto_migrate_legacy_home() {
	migrate_legacy_home auto || true
	return 0
}
