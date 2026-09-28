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
	[ -z "$(ls -A "$1" 2>/dev/null)" ]
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
			die "请先停止上述容器，再执行 ./dshm service migrate-home"
		fi
		warn "已跳过自动迁移；确认这些容器可以停掉后执行 ./dshm service migrate-home"
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

	if ! docker run --rm --user 0:0 \
		-v "${vol}:/from:ro" -v "${dest}:/to" alpine:3.21 \
		sh -c 'cd /from && tar cf - . | (cd /to && tar xf -)'; then
		[ "$mode" = "explicit" ] && die "迁移失败（源卷 ${vol}）；原数据未改动，可重试"
		warn "迁移失败（源卷 ${vol}）；原数据未改动，可重试 ./dshm service migrate-home"
		return 3
	fi

	cu="$(env_value DSH_UID 1000)"
	cg="$(env_value DSH_GID 1000)"
	if [ "$(id -u)" = "0" ]; then
		chown -R "${cu}:${cg}" "$dest" 2>/dev/null || true
	elif command -v sudo >/dev/null 2>&1; then
		sudo chown -R "${cu}:${cg}" "$dest" 2>/dev/null || true
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
