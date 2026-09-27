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

check_workspace() {
	local project_dir="$1" allow_elevate="${2:-auto}" auto_fix="${3:-1}"
	local env_file="$project_dir/.env" raw dir uid gid mode ver
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

	# 1) 先保证目录存在。此刻创建 = 属主是当前宿主用户，最理想。
	if ! mkdir -p "$dir" 2>/dev/null; then
		printf '%s\n' "无法创建工作区目录：${dir}" >&2
		printf '%s\n' "（检查上级目录权限，或用 DSH_WORKSPACE 指定一个你能写的目录）" >&2
		return 1
	fi

	# 2) 是否已可写？可写就没事了 —— 注意这里用真写一次来测，
	#    而不是只看权限位（owner/group/ACL 组合下 `test -w` 会骗人）。
	if ( : >"${dir}/.dsh-write-test" ) 2>/dev/null; then
		rm -f "${dir}/.dsh-write-test" 2>/dev/null || true
		return 0
	fi

	# 3) 不可写：几乎是「目录被 root 创建」这一种情况，尝试修。
	uid="$(stat -c '%u' "$dir" 2>/dev/null || echo '?')"
	gid="$(stat -c '%g' "$dir" 2>/dev/null || echo '?')"
	mode="$(stat -c '%a' "$dir" 2>/dev/null || echo '?')"
	if [ "$uid" = "0" ]; then
		ver="被 root 创建"
	else
		ver="uid:gid=${uid}:${gid} mode=${mode}"
	fi

	# 只在「sudo 可用且免密」时才自动动手。需要输密码的 sudo 会在非交互调用里
	# 卡住等输入（典型场景：install.sh 跑到这里莫名不返回），所以那种情况直接
	# 走下面的报错分支，把命令交给用户自己执行。
	elevate="$(command -v sudo 2>/dev/null || true)"
	if [ "$allow_elevate" = "never" ] || [ -z "$elevate" ]; then
		elevate=""
	elif ! "$elevate" -n true 2>/dev/null; then
		elevate=""
	fi

	fixcmd="sudo chown -R 1000:1000 ${dir}"

	if [ "$auto_fix" = "1" ] && [ -n "$elevate" ]; then
		printf '    工作区属主不对（%s），尝试用 sudo 修正：%s\n' "$ver" "$dir"
		if "$elevate" chown -R 1000:1000 "$dir" &&
			( : >"${dir}/.dsh-write-test" ) 2>/dev/null; then
			rm -f "${dir}/.dsh-write-test" 2>/dev/null || true
			return 0
		fi
		printf '    sudo 修正失败。\n'
	fi

	cat >&2 <<EOF

错误：工作区目录容器内写不进去

  目录：${dir}
  现状：${ver}
  原因：bind mount 会遮蔽镜像里的属主设置；目录若是 dockerd 自动创建，
        属主就是 root，而容器内的 agent 以 node(uid 1000) 运行。

  修复（任选其一）：

    A. 把属主改为容器内的 node：
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
