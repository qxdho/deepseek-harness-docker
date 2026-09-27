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

# 容器里的 agent 以哪个 uid/gid 运行。镜像是 USER node，即 1000:1000；
# 用 DSH_UID/DSH_GID 覆盖以配合 `docker compose` 里的 user:。
container_uid() { printf '%s' "${DSH_UID:-1000}"; }
container_gid() { printf '%s' "${DSH_GID:-1000}"; }

# 目录对指定 uid:gid 是否有写权限 —— 只看权限位，与「当前是谁」无关。
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
		[ $((u & 2)) -eq 2 ]
	elif [ "$want_gid" = "$o_gid" ]; then
		[ $((g & 2)) -eq 2 ]
	else
		[ $((o & 2)) -eq 2 ]
	fi
}

# 容器 uid 能否写这个目录。若当前用户恰好就是该 uid，用真实写入验证（能识别 ACL）；
# 否则用权限位推断 —— 当前用户不是容器用户时，他的写测试结论没有意义。
container_can_write() {
	local dir="$1" cu cg
	cu="$(container_uid)"; cg="$(container_gid)"
	if [ "$(id -u)" = "$cu" ]; then
		( : >"${dir}/.dsh-write-test" ) 2>/dev/null
		return $?
	fi
	perm_for_uid "$dir" "$cu" "$cg"
}

check_workspace() {
	local project_dir="$1" allow_elevate="${2:-auto}" auto_fix="${3:-1}"
	local env_file="$project_dir/.env" raw dir uid gid mode ver cu cg as_admin fixok
	local elevate="" fixcmd

	if [ ! -f "$env_file" ]; then
		printf '%s\n' "缺少 ${env_file}（先运行 ./install.sh）" >&2
		return 2
	fi

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

	cu="$(container_uid)"; cg="$(container_gid)"

	# 2) 容器里的 agent（uid ${cu}）能不能写？这里的判定必须针对容器 uid，
	#    而不是「当前用户能不能写」：root 跑 ./install.sh 时目录是 root:root
	#    0755，root 写得进，容器里的 ${cu} 却写不进 —— 这正是「预检通过、容器
	#    却 crash-loop」的根因。当前用户恰好就是容器 uid 时才用真实写入验证
	#    （能识别 ACL），否则只看权限位。
	if container_can_write "$dir"; then
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
		if [ "$fixok" = "1" ] && container_can_write "$dir"; then
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

# 供直接运行（排障 / CI 用）：
#   bash scripts/preflight.sh [项目目录]      默认是脚本所在的上一级目录
# 这里不做自动修复（auto_fix=0），只报告，避免排障时被意外改动。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	here="$(cd "$(dirname "${0}")/.." && pwd)"
	check_workspace "${1:-$here}" auto 0
fi
