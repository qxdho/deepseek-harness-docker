#!/usr/bin/env bash
# 部署前预检：确保 DSH_WORKSPACE 指向的宿主目录存在，且容器内的 node 用户
# （uid/gid 1000）真的能写。
#
# 为什么必须有这一步
# ------------------
# docker-compose.yml 里 `- ${DSH_WORKSPACE:-./workspace}:/workspace` 是 bind mount。
# 两个后果：
#
#   1. bind mount 会完全遮蔽镜像内 /workspace 的属主。Dockerfile 里那句
#      `chown -R node:node /workspace` 在运行时等于没写。
#   2. 源目录不存在时，是 dockerd（root）替你创建的，属主为 root:root 0755。
#
# 于是容器里的 node(1000) 写不进去，构建时或 agent 干活时才蹦一句
# `EACCES: permission denied, mkdir '/workspace/xxx'` —— 报错点离病因十万八千里。
# 所以在这里提前检查并给出可执行的修复方法。
#
# 用法：由 install.sh / dshm 在启动容器前 source 调用
#   check_workspace <项目目录> [是否可提权: auto|never] [是否自动修复:1|0]
#
# 返回：
#   0  工作区已就绪
#   1  未就绪（已打印修复方法）
#   2  .env 缺失

# 从 .env 读一个键。只认形如 KEY=value 的行，忽略注释。
env_file_value() {
	local file="$1" key="$2" line
	[ -f "$file" ] || return 0
	line="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -n1 || true)"
	[ -n "$line" ] || return 0
	line="${line#*=}"
	# 去掉一层包裹的引号
	case "$line" in
	\"*\") line="${line#\"}"; line="${line%\"}" ;;
	\'*\') line="${line#\'}"; line="${line%\'}" ;;
	esac
	printf '%s' "$line"
}

# 进入项目目录后，${DSH_WORKSPACE} 的相对路径与 docker compose 的解析一致
# （compose 以 --project-directory，默认是 compose 文件所在目录为准）。
absolute_workspace_path() {
	local project_dir="$1" raw="$2" expanded
	[ -n "$raw" ] || raw="./workspace"
	# 支持 ~ 写法
	case "$raw" in
	"~") expanded="$HOME" ;;
	"~/"*) expanded="$HOME/${raw#\~/}" ;;
	*) expanded="$raw" ;;
	esac
	case "$expanded" in
	/*) printf '%s' "$expanded" ;;
	*) printf '%s/%s' "${project_dir%/}" "${expanded#./}" ;;
	esac
}

# 容器里的 agent 以哪个 uid/gid 运行。
#
# 默认 1000:1000（镜像 `USER node`）。可用 DSH_UID/DSH_GID 覆盖，docker-compose.yml
# 里有对应的 `user: "${DSH_UID:-1000}:${DSH_GID:-1000}"` —— 这两处必须成对存在，
# 否则就是「预检按 A 判断、容器按 B 运行」的假通过（这个 bug 曾经出现过）。
#
# 取值优先读 .env，与 DSH_WORKSPACE 一致：项目所有配置都在 .env 里，而
# `sudo ./install.sh` 之类不会把 .env 导进 shell 环境。shell 环境变量作为回退，
# 便于测试直接覆盖。
#
# 第一个参数是要读的 .env 路径；省略则用 $DSH_ENV_FILE 或当前目录的 .env。
# 调用方**必须**显式传入自己项目的 .env —— 靠全局变量传会漏（函数被单独调用时
# 就会去读当前工作目录的 .env，静默拿到错误的 uid）。
container_uid() {
	local ef="${1:-${DSH_ENV_FILE:-.env}}" v
	v="$(env_file_value "$ef" DSH_UID)"
	printf '%s' "${v:-${DSH_UID:-1000}}"
}
container_gid() {
	local ef="${1:-${DSH_ENV_FILE:-.env}}" v
	v="$(env_file_value "$ef" DSH_GID)"
	printf '%s' "${v:-${DSH_GID:-1000}}"
}

# 目录对指定 uid:gid 是否有写权限 —— 只看权限位，与「当前是谁」无关。
#
# 为什么不能只用「当前用户能不能写」来判断：部署者常常是 root（sudo ./install.sh、
# root 的 VPS、1Panel 等）。root 建的 ./workspace 是 root:root 0755 —— root 写得进，
# 容器里的 node(uid 1000) 写不进。若拿当前用户的写测试当结论，就会给出假通过，
# 随后容器 entrypoint 退出、restart 策略把它拉进无限重启。
# 目录对指定 uid:gid 是否有写权限 —— 只看权限位，与「当前是谁」无关。
#
# 目录要能写入，需要同时具备**写位和执行位**（进入目录需要 x）。只查写位会把
# mode 0200 这类目录误判为可写，实际上连 cd 都进不去。所以两边都要查。
#
# 为什么不能只用「当前用户能不能写」来判断：部署者常常是 root（sudo ./install.sh、
# root 的 VPS、1Panel 等）。root 建的 ./workspace 是 root:root 0755 —— root 写得进，
# 容器里的 node(uid 1000) 写不进。若拿当前用户的写测试当结论，就会给出假通过，
# 随后容器 entrypoint 退出、restart 策略把它拉进无限重启。
perm_for_uid() {
	local dir="$1" want_uid="$2" want_gid="$3"
	local o_uid o_gid mode m u g o
	o_uid="$(stat -c '%u' "$dir" 2>/dev/null)" || return 1
	o_gid="$(stat -c '%g' "$dir" 2>/dev/null)" || return 1
	mode="$(stat -c '%a' "$dir" 2>/dev/null)" || return 1
	mode="${mode: -3}" # 去掉 setuid/setgid/sticky 位
	m=$((10#$mode))
	u=$(((m / 100) % 10))
	g=$(((m / 10) % 10))
	o=$((m % 10))
	if [ "$want_uid" = "$o_uid" ]; then
		[ $((u & 3)) -eq 3 ]
	elif [ "$want_gid" = "$o_gid" ]; then
		[ $((g & 3)) -eq 3 ]
	else
		[ $((o & 3)) -eq 3 ]
	fi
}

# 容器 uid 能否写这个目录。若当前用户恰好就是该 uid，用真实写入验证（能识别 ACL）；
# 否则用权限位推断 —— 当前用户不是容器用户时，他的写测试结论没有意义。
# 参数：<目录> <项目 .env 路径>
container_can_write() {
	local dir="$1" ef="$2" cu cg
	cu="$(container_uid "$ef")"; cg="$(container_gid "$ef")"
	if [ "$(id -u)" = "$cu" ]; then
		( : >"${dir}/.dsh-write-test" ) 2>/dev/null
		return $?
	fi
	perm_for_uid "$dir" "$cu" "$cg"
}

# 工作区（bind mount）检查：返回 0 = 已就绪或已修复，1 = 有问题
check_workspace_dir() {
	local project_dir="$1" allow_elevate="$2" auto_fix="$3"
	local env_file="$project_dir/.env" raw dir uid gid mode ver cu cg as_admin fixok
	local elevate="" fixcmd

	raw="$(env_file_value "$env_file" DSH_WORKSPACE)"
	dir="$(absolute_workspace_path "$project_dir" "$raw")"
	# 解析结果对外可见，调用方要显示路径时用它 —— 别再用各自的 .env 解析器
	# 重算一遍（引号、~ 的处理容易不一致，会显示成错误的路径）。
	DSH_WORKSPACE_DIR="$dir"

	# 1) 先保证目录存在。此刻创建 = 属主是当前宿主用户，最理想 —— 但只有当
	#    当前宿主用户就是容器内 uid 时才成立，见第 2 步。
	if ! mkdir -p "$dir" 2>/dev/null; then
		printf '%s\n' "无法创建工作区目录：${dir}" >&2
		printf '%s\n' "（检查上级目录权限，或用 DSH_WORKSPACE 指定一个你能写的目录）" >&2
		return 1
	fi

	cu="$(container_uid "$env_file")"; cg="$(container_gid "$env_file")"

	# 2) 容器里的 agent（uid ${cu}）能不能写？这里的判定必须针对容器 uid，
	#    而不是「当前用户能不能写」：root 跑 ./install.sh 时目录是 root:root
	#    0755，root 写得进，容器里的 ${cu} 却写不进 —— 这正是「预检通过、容器
	#    却 crash-loop」的根因。当前用户恰好就是容器 uid 时才用真实写入验证
	#    （能识别 ACL），否则只看权限位。
	if container_can_write "$dir" "$env_file"; then
		rm -f "${dir}/.dsh-write-test" 2>/dev/null || true
		return 0
	fi

	# 3) 不可写：几乎都是「宿主属主不是容器内的 uid」。尝试修。
	uid="$(stat -c '%u' "$dir" 2>/dev/null || echo '?')"
	gid="$(stat -c '%g' "$dir" 2>/dev/null || echo '?')"
	mode="$(stat -c '%a' "$dir" 2>/dev/null || echo '?')"
	if [ "$uid" = "0" ] && [ "$cu" != "0" ]; then
		ver="被 root 创建"
	else
		ver="uid:gid=${uid}:${gid} mode=${mode}"
	fi

	# 谁能改属主：root 直接改；否则只在「sudo 存在且免密」时改。需要输密码的
	# sudo 会在非交互调用里卡住等输入（典型场景：install.sh 跑到这里莫名不返回），
	# 所以那种情况直接走下面的报错分支，把命令交给用户自己执行。
	as_admin=""
	if [ "$(id -u)" = "0" ]; then
		as_admin="direct"
	else
		elevate="$(command -v sudo 2>/dev/null || true)"
		if [ -n "$elevate" ] && [ "$allow_elevate" != "never" ] && "$elevate" -n true 2>/dev/null; then
			as_admin="sudo"
		fi
	fi

	fixcmd="sudo chown -R ${cu}:${cg} ${dir}"

	if [ "$auto_fix" = "1" ] && [ -n "$as_admin" ]; then
		printf '    工作区对容器内 uid %s 不可写（%s），尝试修正：%s\n' "$cu" "$ver" "$dir"
		fixok=0
		if [ "$as_admin" = "direct" ]; then
			if chown -R "${cu}:${cg}" "$dir"; then fixok=1; fi
		else
			if "$elevate" chown -R "${cu}:${cg}" "$dir"; then fixok=1; fi
		fi
		if [ "$fixok" = "1" ] && container_can_write "$dir" "$env_file"; then
			rm -f "${dir}/.dsh-write-test" 2>/dev/null || true
			return 0
		fi
		printf '    修正失败。\n'
	fi

	cat >&2 <<EOF

错误：工作区目录容器内写不进去

  目录：${dir}
  现状：${ver}
  原因：bind mount 会遮蔽镜像里的属主设置；目录属主不是容器内的 uid ${cu}
        （dockerd 自动创建、或部署者以 root 运行时都会这样），而容器内的
        agent 以 uid ${cu} 运行。

  修复（任选其一）：

    A. 把属主改为容器内的 uid ${cu}：
         ${fixcmd}

    B. 换成一个你自己拥有的目录（不需要 sudo）：
         mkdir -p "\$HOME/dsh-workspace"
         echo "DSH_WORKSPACE=\$HOME/dsh-workspace" >> .env
         docker compose down && docker compose up -d
       （注意是 down + up，不是 restart —— 环境变量在创建容器时才生效）

EOF
	return 1
}

# ── dsh-home 命名卷 ─────────────────────────────────────────────────────────
#
# 容器里 $DSH_HOME(/home/node/.dsh) 的属主来自镜像的 1000:1000。命名卷首次使用时
# 由 Docker 按镜像目录**播种**，所以默认也是 1000 —— DSH_UID 保持 1000 时一切都对。
#
# 一旦 DSH_UID 不是 1000（compose 的 user: 生效），容器里就没有任何进程是 root，
# 没人能改这个卷的属主，agent 会写不进自己的配置目录（会话、凭据、登录用户），
# 又是同一类故障换了个地方。所以要在宿主侧、启动前用一次性 root 容器把它改对。
#
# 这与工作区不同：工作区是 bind mount，在宿主上 chown 即可；命名卷只能通过
# docker 操作，因此下面的路径需要 docker 可用。

# 卷是否已存在（不存在就不用管：首次 up 时按 DSH_UID 初始化）
volume_exists() { docker volume inspect "$1" >/dev/null 2>&1; }

# 从运行中的 compose 容器里读出 dsh-home 卷的**真实名字**。
#
# Compose 会给声明的卷加项目名前缀（`<项目名>_dsh-home`），项目名又取决于目录名或
# COMPOSE_PROJECT_NAME，所以猜不得。这里直接问 Docker：该容器挂了哪个卷到
# /home/node/.dsh。容器不存在时输出空（此时卷也没被创建，无需处理）。
dsh_home_volume_from_container() {
	command -v docker >/dev/null 2>&1 || return 0
	local cid
	cid="$(docker compose ps -q dsh 2>/dev/null | head -n1)"
	[ -n "$cid" ] || return 0
	docker inspect "$cid" \
		--format '{{range .Mounts}}{{if eq .Destination "/home/node/.dsh"}}{{.Name}}{{end}}{{end}}' \
		2>/dev/null || true
}

# 打印「卷内目录当前属主 uid」。卷不存在或读不到时输出空。
volume_owner_uid() {
	local vol="$1" target="$2"
	docker run --rm --network none --entrypoint stat \
		-v "${vol}:/dsh-home" \
		"${DSH_PREFLIGHT_IMAGE:-ghcr.io/qxdho/deepseek-harness-docker:latest}" \
		-c '%u' "$target" 2>/dev/null
}

# 用一次性 root 容器把卷内目录 chown 给容器 uid
repair_volume_owner() {
	local vol="$1" target="$2" cu="$3" cg="$4"
	docker run --rm --network none --user 0:0 --entrypoint chown \
		-v "${vol}:/dsh-home" \
		"${DSH_PREFLIGHT_IMAGE:-ghcr.io/qxdho/deepseek-harness-docker:latest}" \
		-R "${cu}:${cg}" "$target" >/dev/null 2>&1
}

# 返回 0 = 无需处理或已处理；1 = 处理不了（已打印指引）
check_home_volume() {
	local project_dir="$1" auto_fix="$2"
	local env_file="$project_dir/.env" cu cg vol target owner img

	# 显式把项目 .env 传给 uid 解析 —— 不要依赖全局变量：本函数会被单独调用
	# （测试、排障），那时全局变量可能是空的，解析会静默回退到 1000。
	cu="$(container_uid "$env_file")"; cg="$(container_gid "$env_file")"
	# 默认 uid 时镜像播种的属主就是对的，不必碰 docker。
	[ "$cu" = "1000" ] && [ "$cg" = "1000" ] && return 0

	# 缺少 docker 的提示必须放在最前面：这个预检要检查的是容器自己的卷，只能在
	# 宿主上用 docker 操作。本机没有 docker 时**不能静默跳过** —— 否则用户按
	# DSH_UID 部署后会遇到「复述不清的权限错误」，而预检什么都没说。
	command -v docker >/dev/null 2>&1 || {
		printf '%s\n' "提示：DSH_UID=${cu}，但本机没有 docker，无法检查 dsh-home 命名卷的属主。" >&2
		printf '%s\n' "      容器内没有 root，卷属主不对时 agent 会写不进自己的配置目录。" >&2
		return 0
	}

	# 卷名不能靠猜：docker-compose.yml 里声明的是 `dsh-home:`，但 Compose 会给它
	# 加上项目名前缀（实际是 <项目名>_dsh-home），项目名又取决于目录名 /
	# COMPOSE_PROJECT_NAME。写死 "dsh-home" 会 volume inspect 不到 → 直接跳过修复，
	# 整个 DSH_UID 修复静默失效。所以从运行中的容器读它实际挂的是哪个卷。
	vol="$(dsh_home_volume_from_container)"
	if [ -z "$vol" ]; then
		# 容器还没创建：卷也不存在，首次 up 会按新 user: 初始化，无事可做。
		return 0
	fi
	# 注意：compose 把这个卷挂在 /home/node/.dsh，所以**卷的根目录就是 DSH_HOME**，
	# 容器内看到的 /home/node/.dsh 的属主就是这个卷根目录的属主。
	# （早期版本写成 /dsh-home/.dsh，等于检查一个不存在的子目录，永远修不到。）
	target="/dsh-home"

	# 卷不存在 → 首次 up 时会按 compose 的新 user: 初始化，没问题。
	volume_exists "$vol" || return 0

	img="${DSH_IMAGE:-ghcr.io/qxdho/deepseek-harness-docker:latest}"
	DSH_PREFLIGHT_IMAGE="$img"
	if ! docker image inspect "$img" >/dev/null 2>&1; then
		printf '%s\n' "提示：DSH_UID=${cu}，但镜像 ${img} 还不存在，无法检查命名卷 ${vol} 的属主。" >&2
		printf '%s\n' "      先 ./dshm service up 拉起一次，再执行一次让预检修正卷属主。" >&2
		return 0
	fi

	# 末尾的 `|| true` 是必需的：volume_owner_uid 内部 docker run 失败时（例如目标
	# 路径不存在），在 `set -euo pipefail` 下这个赋值会让整个预检**无声中止**，
	# 用户只看到脚本突然退出。这里改为把失败交给下面的 owner 为空判断。
	owner="$(volume_owner_uid "$vol" "$target" || true)"
	[ "$owner" = "$cu" ] && return 0

	if [ "$auto_fix" = "1" ]; then
		printf '    命名卷 %s 对容器内 uid %s 不可写（当前属主 %s），尝试修正…\n' \
			"$vol" "$cu" "${owner:-未知}"
		if repair_volume_owner "$vol" "$target" "$cu" "$cg" &&
			[ "$(volume_owner_uid "$vol" "$target" || true)" = "$cu" ]; then
			return 0
		fi
		printf '    卷属主修正失败。\n'
	fi

	cat >&2 <<EOF

错误：命名卷 ${vol} 的属主不是容器内的 uid ${cu}

  卷内目录：${target}（这个卷根目录在容器内就是 \$DSH_HOME）
  卷内路径：容器内 \$DSH_HOME = /home/node/.dsh
  现状属主：${owner:-未知}
  影响：agent 写不进自己的配置目录（会话 / 凭据 / 登录用户）。
  原因：命名卷首次使用时由 Docker 按镜像目录播种，镜像里是 1000:1000。
        DSH_UID 改成 ${cu} 后，容器内没有 root，没人能改这个卷。

  修复（用一次性 root 容器改属主）：

    docker run --rm --user 0:0 --entrypoint chown \\
      -v ${vol}:/dsh-home ${img} -R ${cu}:${cg} ${target}

  或者把 DSH_UID/DSH_GID 去掉、用 `--user` 手动指定时一并处理卷属主。

EOF
	return 1
}

# 启动前总检查。返回 0 = 可以启动，1 = 有问题（已打印指引），2 = 缺 .env
check_workspace() {
	local project_dir="$1" allow_elevate="${2:-auto}" auto_fix="${3:-1}"
	local env_file="$project_dir/.env"

	if [ ! -f "$env_file" ]; then
		printf '%s\n' "缺少 ${env_file}（先运行 ./install.sh）" >&2
		return 2
	fi

	# 工作区不可写就没必要再查卷 —— 那是更根本的问题，先解决它。
	check_workspace_dir "$project_dir" "$allow_elevate" "$auto_fix" || return 1

	# 工作区 OK，再管容器自己的配置卷（只在 DSH_UID 非 1000 时才需要）。
	check_home_volume "$project_dir" "$auto_fix" || return 1

	return 0
}

# 供直接运行（排障 / CI 用）：
#   bash scripts/preflight.sh [项目目录]      默认是脚本所在的上一级目录
# 这里不做自动修复（auto_fix=0），只报告，避免排障时被意外改动。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	here="$(cd "$(dirname "${0}")/.." && pwd)"
	check_workspace "${1:-$here}" auto 0
fi
