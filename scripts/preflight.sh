#!/usr/bin/env bash
# 部署前预检：确保 DSH_WORKSPACE_HOST 指向的宿主目录存在，且容器内的 node 用户
# （uid/gid 1000）真的能写。
#
# 为什么必须有这一步
# ------------------
# docker-compose.yml 里 `- ${DSH_WORKSPACE_HOST:-/dsh/workspace}:${DSH_WORKSPACE_CONTAINER:-/workspace}` 是 bind mount。
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

# 读任意 .env 文件里的键（preflight 会对临时 .env 做检查，所以不能只用 $ENV_FILE）。
#
# **规则必须与 env-config.sh 的 get_env 完全一致** —— 这里有两条路：
#   * 调用方已经 source 过 env-config.sh（dshm / install.sh 都会）→ 直接委托；
#   * 没 source（例如单独跑 preflight 的测试）→ 用同一套规则自己实现。
# 两份实现曾经分叉：这个允许行首空白、get_env 不允许，于是 `  DSH_UID=1111`
# 会让 preflight 以为容器用 1111、而实际用默认 1000 —— 检查通过但容器起不来。
env_file_value() {
	local file="$1" key="$2"
	if command -v get_env >/dev/null 2>&1 && [ "${ENV_FILE:-}" != "$file" ]; then
		# get_env 的实现里已经带了「允许行首空白 + 去一层引号」，直接用它
		get_env "$key" "$file"
		return 0
	fi
	local v
	[ -f "$file" ] || return 0
	v="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -n1 || true)"
	[ -n "$v" ] || return 0
	v="${v#*=}"
	case "$v" in
	\"*\") v="${v#\"}"; v="${v%\"}" ;;
	\'*\') v="${v#\'}"; v="${v%\'}" ;;
	esac
	printf '%s' "$v"
}

# 进入项目目录后，${DSH_WORKSPACE_HOST} 的相对路径与 docker compose 的解析一致
# （compose 以 --project-directory，默认是 compose 文件所在目录为准）。
absolute_workspace_path() {
	local project_dir="$1" raw="$2" expanded
	[ -n "$raw" ] || raw="/dsh/workspace"
	# ~ / $HOME / ${HOME} 这类写法在这里展开，是为了让「检查的目录」和用户「想用的
	# 目录」一致。注意 compose 不会展开它们：.env 里的值会原样交给 dockerd，相对
	# 路径按 --project-directory 解析，~/dsh 会变成 <项目目录>/~/dsh。所以下面
	# check_host_dir 会对这类写法额外告警，并给出展开后的绝对路径。
	case "$raw" in
	"~") expanded="$HOME" ;;
	"~/"*) expanded="$HOME/${raw#\~/}" ;;
	'$HOME') expanded="$HOME" ;;
	'$HOME/'*) expanded="$HOME/${raw#\$HOME/}" ;;
	'${HOME}') expanded="$HOME" ;;
	'${HOME}/'*) expanded="$HOME/${raw#\$\{HOME\}/}" ;;
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
# 取值优先读 .env，与 DSH_WORKSPACE_HOST 一致：项目所有配置都在 .env 里，而
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
# root 的 VPS、1Panel 等）。root 建的工作区目录是 root:root 0755 —— root 写得进，
# 容器里的 node(uid 1000) 写不进。若拿当前用户的写测试当结论，就会给出假通过，
# 随后容器 entrypoint 退出、restart 策略把它拉进无限重启。
# 目录对指定 uid:gid 是否有写权限 —— 只看权限位，与「当前是谁」无关。
#
# 目录要能写入，需要同时具备**写位和执行位**（进入目录需要 x）。只查写位会把
# mode 0200 这类目录误判为可写，实际上连 cd 都进不去。所以两边都要查。
#
# 为什么不能只用「当前用户能不能写」来判断：部署者常常是 root（sudo ./install.sh、
# root 的 VPS、1Panel 等）。root 建的工作区目录是 root:root 0755 —— root 写得进，
# 容器里的 node(uid 1000) 写不进。若拿当前用户的写测试当结论，就会给出假通过，
# 随后容器 entrypoint 退出、restart 策略把它拉进无限重启。
perm_for_uid() {
	local dir="$1" want_uid="$2" want_gid="$3"
	local o_uid o_gid mode m u g o
	o_uid="$(stat -c '%u' "$dir" 2>/dev/null)" || return 1
	o_gid="$(stat -c '%g' "$dir" 2>/dev/null)" || return 1
	mode="$(stat -c '%a' "$dir" 2>/dev/null)" || return 1
	# stat %a 对 000 只输出 "0"（不是 "000"）；短于 3 位时不能切片，
	# 否则 ${mode: -3} 会得到空串，下面 10#$mode 直接报算术错误。
	if [ "${#mode}" -ge 3 ]; then
		mode="${mode: -3}" # 去掉 setuid/setgid/sticky 位
	fi
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
# ── 宿主机目录检查（工作区、数据目录共用）──────────────────────────────────
#
# check_host_dir 项目目录 .env键 说明 默认值 allow_elevate auto_fix
#
# 判定的是「容器内 uid 能不能写这个宿主目录」，而不是「当前用户能不能写」——
# root 跑 install.sh 时 root:root 0755 对 root 可写、对容器里的 1000 不可写，
# 用后者当结论就会给出假通过，随后容器崩溃重启。
# 解析出的绝对路径放在 CHECK_HOST_DIR_PATH，供调用方显示。
CHECK_HOST_DIR_PATH=""
check_host_dir() {
	local project_dir="$1" key="$2" label="$3" default="$4" allow_elevate="$5" auto_fix="$6"
	local env_file="$project_dir/.env" raw dir uid gid mode ver cu cg as_admin fixok elevate="" fixcmd home_root

	raw="$(env_file_value "$env_file" "$key")"
	[ -n "$raw" ] || raw="$default"
	dir="$(absolute_workspace_path "$project_dir" "$raw")"
	CHECK_HOST_DIR_PATH="$dir"

	# 这类写法 compose 不展开，必须提醒（否则挂载点和这里检查的不是同一个目录）。
	case "$raw" in
	'~'|'~/'*|'$HOME'|'$HOME/'*|'${HOME}'|'${HOME}/'*)
		printf '%s\n' "警告：.env 里 ${key}=${raw} 用了 shell 写法的家目录，Compose 不会展开它。" >&2
		printf '%s\n' "      实际挂载点会变成 <项目目录>/${raw}；请直接写绝对路径：${key}=${dir}" >&2
		;;
	esac

	# 1) 目录得先存在。系统路径（默认 /dsh）需要 sudo 才能创建。
	#    钉住 umask，避免在宿主的宽松 umask（0000/0002）下把目录建得过宽 —— 目录
	#    可写会让 agent 在其中新建的文件带上可执行位，进而在 git 工作区里产生一堆
	#    「已修改但 diff 为空」的噪音。
	if ( umask 0022; mkdir -p "$dir" ) 2>/dev/null; then
		:
	elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
		sudo mkdir -p "$dir" || {
			printf '%s\n' "无法创建${label}：${dir}" >&2
			return 1
		}
	else
		printf '%s\n' "无法创建${label}：${dir}" >&2
		printf '%s\n' "（默认 /dsh 在根目录下，需要 root/sudo；也可以把 .env 里的 ${key} 换成一个你能写的目录）" >&2
		return 1
	fi

	# 1b) 已经存在的目录若被改得过宽（g+w / o+w），顺手收紧。
	#     这是「不小心改了目录权限」之后的自愈路径：跑一次 ./dshm service up 即可，
	#     不必记住该 chmod 成什么。只收紧「可写」位，不动可执行位与属主。
	cur_mode="$(stat -c '%a' "$dir" 2>/dev/null || true)"
	case "$cur_mode" in
	'' | *[!0-7]*) ;;
	*)
		if [ $(( 8#$cur_mode & 8#022 )) -ne 0 ]; then
			if chmod g-w,o-w "$dir" 2>/dev/null; then
				printf '    已收紧 %s 的权限：%s → %s（去掉组/其他用户可写）\n' \
					"$dir" "$cur_mode" "$(stat -c '%a' "$dir" 2>/dev/null)"
			elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
				sudo chmod g-w,o-w "$dir" 2>/dev/null || true
			else
				printf '%s\n' "提示：${dir} 权限为 ${cur_mode}（其他用户可写）。建议执行：chmod g-w,o-w ${dir}" >&2
			fi
		fi
		;;
	esac

	cu="$(container_uid "$env_file")"; cg="$(container_gid "$env_file")"

	# 2) 容器 uid 能否写？当前用户恰好是容器 uid 时才用真实写入验证（能识别 ACL）。
	if container_can_write "$dir" "$env_file"; then
		rm -f "${dir}/.dsh-write-test" 2>/dev/null || true
		return 0
	fi

	uid="$(stat -c '%u' "$dir" 2>/dev/null || echo '?')"
	gid="$(stat -c '%g' "$dir" 2>/dev/null || echo '?')"
	mode="$(stat -c '%a' "$dir" 2>/dev/null || echo '?')"
	if [ "$uid" = "0" ] && [ "$cu" != "0" ]; then
		ver="被 root 创建"
	else
		ver="uid:gid=${uid}:${gid} mode=${mode}"
	fi

	# 3) 谁能改属主：root 直接改；否则只在 sudo 免密时改（需要输密码的 sudo 会在
	#    非交互调用里卡住，那种情况直接走报错分支，把命令交给用户）。
	as_admin=""
	if [ "$(id -u)" = "0" ]; then
		as_admin="direct"
	else
		elevate="$(command -v sudo 2>/dev/null || true)"
		if [ -n "$elevate" ] && [ "$allow_elevate" != "never" ] && "$elevate" -n true 2>/dev/null; then
			as_admin="sudo"
		fi
	fi

	# 打印修复命令时用 printf %q 转义路径，避免目录名带空格/特殊字符时复制粘贴出错。
	printf -v fixcmd 'sudo chown -R %s:%s %q' "$cu" "$cg" "$dir"

	if [ "$auto_fix" = "1" ] && [ -n "$as_admin" ]; then
		printf '    %s对容器内 uid %s 不可写（%s），尝试修正：%s\n' "$label" "$cu" "$ver" "$dir"
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

	# 方案 B 提示里给出展开后的绝对路径（compose 不会展开 $HOME，写 $HOME 会出错）。
	# root 部署时不要把家目录当推荐位置：/root 是 0700、和系统目录混在一起，
	# 而且默认的 /dsh 本来就不需要 sudo。
	if [ "$(id -u)" = "0" ]; then
		home_root="/dsh"
	else
		home_root="${HOME%/}/dsh"
	fi

	cat >&2 <<EOF

错误：${label}容器内写不进去

  目录：${dir}（.env 里的 ${key}）
  现状：${ver}
  原因：这是宿主目录，属主由宿主决定；目录属主不是容器内的 uid ${cu}
        （dockerd 自动创建、或部署者以 root 运行时都会这样），而容器内的
        agent 以 uid ${cu} 运行。

  修复（任选其一）：

    A. 把属主改为容器内的 uid ${cu}：
         ${fixcmd}

    B. 换成默认位置（${home_root}，当前用户可写）：
         mkdir -p "${home_root}"
         然后把 .env 改成（必须写绝对路径，Compose 不展开 ~ 这类 shell 写法）：
           DSH_HOME_HOST=${home_root}
           DSH_WORKSPACE_HOST=${home_root}/workspace
$(if [ "$(id -u)" != "$cu" ]; then
	printf '           DSH_UID=%s\n           DSH_GID=%s   # 你的 uid 不是 %s，必须让容器用同一个 uid\n' "$(id -u)" "$(id -g)" "$cu"
fi)
         ./dshm service up

EOF
	return 1
}

# 工作区目录（宿主侧）
check_workspace_dir() {
	local project_dir="$1" allow_elevate="$2" auto_fix="$3" rc
	check_host_dir "$project_dir" DSH_WORKSPACE_HOST "工作区目录" "/dsh/workspace" "$allow_elevate" "$auto_fix"
	rc=$?
	# **无论检查成功还是失败**都要把解析结果交出去：check_host_dir 在还未判定
	# 成败时就已经把路径写进 CHECK_HOST_DIR_PATH 了，失败时它同样是一个已知路径
	# （报错信息里用的就是它）。若只在成功路径上赋值，失败时这里会保留上一次调用
	# 留下的陈旧路径，显示出来的目录是错的。
	DSH_WORKSPACE_DIR="$CHECK_HOST_DIR_PATH"
	return "$rc"
}

# dsh 数据目录（DSH_HOME_CONTAINER 的宿主侧）
check_dsh_home_dir() {
	local project_dir="$1" allow_elevate="$2" auto_fix="$3"
	check_host_dir "$project_dir" DSH_HOME_HOST "dsh 数据目录" "/dsh" "$allow_elevate" "$auto_fix"
}
# 私密文件：dsh 的 credentials 插件要求 .credentials.yaml 没有 group/other 权限位
# （源码判定 mode & 0o077 == 0），否则拒绝启动并让容器进入重启循环：
#   credentials-local: /dsh/.credentials.yaml is readable beyond its owner (mode 777)
# 反过来，收紧成 600 之后如果属主还是 root，容器里的 uid 1000 同样读不了：
#   EACCES: permission denied, open '/dsh/.credentials.yaml'
# 两种都必须处理，所以这里既改属主（到容器 uid）又改权限（到 600）。
# 这类文件常来自旧命名卷，或在宿主上被 chmod -R 777 / chown 过。
sudo_or_run() {
	"$@" 2>/dev/null && return 0
	command -v sudo >/dev/null 2>&1 && sudo -n "$@" 2>/dev/null
}

fix_private_files() {
	local project_dir="$1" home f mode owner cu cg
	local env_file="$project_dir/.env"
	home="$(env_file_value "$env_file" DSH_HOME_HOST)"
	[ -n "$home" ] || home="$project_dir"
	case "$home" in /*) ;; *) home="$project_dir/${home#./}" ;; esac
	[ -d "$home" ] || return 0
	cu="$(container_uid "$env_file")"
	cg="$(container_gid "$env_file")"

	for f in "$home/.credentials.yaml" "$home/settings.yaml" "$home/auth/users.yaml"; do
		[ -f "$f" ] || continue
		owner="$(stat -c '%u:%g' "$f" 2>/dev/null || echo '')"
		mode="$(stat -c '%a' "$f" 2>/dev/null || echo '')"
		# 属主：容器以 uid ${cu} 运行，0600 的文件不是它的话必然 EACCES
		if [ -n "$owner" ] && [ "$owner" != "${cu}:${cg}" ]; then
			if sudo_or_run chown "${cu}:${cg}" "$f"; then
				printf '    %s 属主 %s → %s\n' "$f" "$owner" "${cu}:${cg}"
			else
				printf '%s\n' "    警告：$f 属主是 $owner，容器内 uid ${cu} 读不了它。请执行： sudo chown ${cu}:${cg} $f" >&2
			fi
		fi
		# 权限：不能有任何 group/other 位
		if [ -n "$mode" ] && [ "${mode: -2}" != "00" ]; then
			if sudo_or_run chmod 600 "$f"; then
				printf '    %s 权限 %s → 600\n' "$f" "$mode"
			else
				printf '%s\n' "    警告：$f 权限过宽（$mode），dsh 会拒绝启动。请执行： sudo chmod 600 $f" >&2
			fi
		fi
	done

	# 顶层还有别的条目属主不对时，dsh 读写同样会失败；这里只提示，不擅自整目录 chown
	local foreign
	foreign="$(find "$home" -maxdepth 1 -mindepth 1 ! -user "$cu" 2>/dev/null | head -5)"
	if [ -n "$foreign" ]; then
		printf '    警告：数据目录里还有不属于容器 uid %s 的条目，容器可能读写失败：\n' "$cu"
		printf '%s\n' "$foreign" | sed 's/^/      /'
		printf '    修复： sudo chown -R %s:%s %s\n' "$cu" "$cg" "$home"
	fi
	return 0
}

# 启动前总检查。返回 0 = 可以启动，1 = 有问题（已打印指引），2 = 缺 .env
check_workspace() {
	local project_dir="$1" allow_elevate="${2:-auto}" auto_fix="${3:-1}"
	local env_file="$project_dir/.env"

	if [ ! -f "$env_file" ]; then
		printf '%s\n' "缺少 ${env_file}（先运行 ./install.sh）" >&2
		return 2
	fi

	# 数据目录（DSH_HOME_CONTAINER 的宿主侧）与工作区都是 bind mount，属主不对容器就写不进。
	check_dsh_home_dir "$project_dir" "$allow_elevate" "$auto_fix" || return 1
	check_workspace_dir "$project_dir" "$allow_elevate" "$auto_fix" || return 1
	# auto_fix=0（排障模式）只报告不修改
	[ "$auto_fix" = "0" ] || fix_private_files "$project_dir"

	return 0
}

# 供直接运行（排障 / CI 用）：
#   bash scripts/preflight.sh [项目目录]      默认是脚本所在的上一级目录
# auto_fix=0：只报告，不自动 chown。但缺少的目录仍会被创建（mkdir -p），
# 因为「目录存不存在」本身就是检查项之一。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	here="$(cd "$(dirname "${0}")/.." && pwd)"
	check_workspace "${1:-$here}" auto 0
fi
