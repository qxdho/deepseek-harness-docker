#!/usr/bin/env bash
# 把仓库里钉住的第三方版本查询到最新并写回三个文件。
#
# 为什么需要它：dsh 目前每几天就发一个版本（实测 4 天发了 4 个：0.1.7-rc.1 →
# 0.2.0-rc.2），而 Dockerfile / docker-compose.yml / .env.example 里的 DSH_VERSION
# 是写死的。没人改就等于「仓库构建出来的镜像永远是旧版」——包括 CI 推到 GHCR 的
# latest。本脚本把这件事自动化，配合 .github/workflows/update-versions.yml 定时运行。
#
# 用法：
#   ./scripts/update-versions.sh            查询并写回（有变化才改）
#   ./scripts/update-versions.sh --check    只报告是否有新版（不改文件）；有可更新项返回 1
#   ./scripts/update-versions.sh --only dsh 只更新指定项（调试用）
#
# 可用环境变量覆盖（测试用）：DSH_UPDATE_REPO_ROOT、DSH_NPM_REGISTRY。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ROOT="${DSH_UPDATE_REPO_ROOT:-$(cd "$here/.." && pwd)}"
REGISTRY="${DSH_NPM_REGISTRY:-https://registry.npmjs.org}"
CHECK=0
ONLY=""

while [ $# -gt 0 ]; do
	case "$1" in
	--check) CHECK=1 ;;
	--only)
		shift
		ONLY="${1:-}"
		[ -n "$ONLY" ] || { echo "--only 需要一个名字" >&2; exit 2; }
		;;
	-h | --help)
		sed -n '2,18p' "$0"
		exit 0
		;;
	*)
		echo "未知参数：$1" >&2
		exit 2
		;;
	esac
	shift
done

DOCKERFILE="$ROOT/Dockerfile"
COMPOSE="$ROOT/docker-compose.yml"
ENVEXAMPLE="$ROOT/.env.example"
for f in "$DOCKERFILE" "$COMPOSE" "$ENVEXAMPLE"; do
	[ -f "$f" ] || {
		echo "找不到 $f" >&2
		exit 1
	}
done

# 从 npm registry 取 dist-tags.latest。取不到就返回非 0 —— 绝不能返回空串，
# 否则调用方会拿空版本号去覆盖文件里的真实值。
npm_latest() {
	local pkg="$1" json
	local encoded
	encoded="$(printf '%s' "$pkg" | sed 's|/|%2f|')"
	json="$(curl -fsSL --max-time 20 "$REGISTRY/$encoded" 2>/dev/null)" || return 1
	if command -v jq >/dev/null 2>&1; then
		printf '%s' "$json" | jq -r '."dist-tags".latest // empty' 2>/dev/null
	elif command -v node >/dev/null 2>&1; then
		printf '%s' "$json" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s)["dist-tags"].latest||""))}catch(e){process.exit(1)}})' 2>/dev/null
	elif command -v python3 >/dev/null 2>&1; then
		printf '%s' "$json" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("dist-tags",{}).get("latest",""))' 2>/dev/null
	else
		return 1
	fi
}

# 当前钉住的版本：从 Dockerfile 的 ARG 读（它是唯一的真源，compose 与 .env.example
# 只是它的镜像）。
#
# 用 awk 而不是 `grep -oP '\K'`：后者依赖 PCRE 支持（macOS 自带的 BSD grep 没有），
# 而且 `\K` 写在双引号里还要多一层转义 —— 极易写成 `\\K` 而永远读不到值。
current_pin() {
	local name="$1"
	awk -v want="ARG $name=" '
		index($0, want) == 1 {
			v = substr($0, length(want) + 1)
			sub(/[ \t\r]+$/, "", v)
			print v
			exit
		}' "$DOCKERFILE"
}

# current != latest 时把版本写进三个文件。
# 每处都用锚定到具体键名的替换，避免误伤别的行（例如 .env.example 里可能还有注释
# 提到同一个版本号）。
# 该条目**应该**出现在哪些文件里。顺序与 apply_version 的检查顺序一致：
#   d = Dockerfile、c = docker-compose.yml、e = .env.example
# 有了这个清单，apply_version 才能判断「是格式漂移」还是「这个条目本来就不在某个文件里」——
# 否则「匹配到 2 处」既可能是正常的（如 DSH_AUTH_GATE_VERSION 确实没有 .env.example 项），
# 也可能是 compose 那行被人改坏了，两者无法区分。
targets_of() {
	case "$1" in
	DSH_VERSION) printf 'dce' ;;
	DSH_AUTH_GATE_VERSION) printf 'dce' ;;
	PNPM_VERSION) printf 'd' ;; # 只在 Dockerfile（compose 与 .env.example 都没有它）；
	# 且它在上面的表里标了 :skip，永远不会走到 apply_version —— 这里写 'd' 只是
	# 让"目标文件"与实际相符，避免下次有人取消 skip 时照着错的清单改。
	*) printf 'dce' ;;
	esac
}

# 把 name 的版本从 old 改成 new，**在 stdout 打印「改动数 目标数」**（如 `3 3`）。
#
# 为什么不是返回值：返回值只适合表达成功/失败，而这里要传两个计数。原来恒 return 0，
# 调用方无从判断到底写没写进去 —— 即使一处都没匹配上，也照样打印「已写入三个文件」，
# 每周定时任务据此开出一个什么都没改的空 PR。
#
# `改动数 < 目标数` 即「有目标文件没按预期格式找到」，调用方据此判为漂移并失败。
apply_version() {
	local name="$1" old="$2" new="$3" changed=0 want
	want="$(targets_of "$name")"

	case "$want" in *d*)
		if grep -q "^ARG ${name}=${old}$" "$DOCKERFILE"; then
			sed -i "s|^ARG ${name}=${old}$|ARG ${name}=${new}|" "$DOCKERFILE"
			changed=$((changed + 1))
		fi
		;;
	esac
	case "$want" in *c*)
		# compose 里是 ${NAME:-旧值} 形式。**缩进写死 8 个空格** —— 改缩进会让这里匹配不上，
		# 所以上面的单测专门钉住了这个前提。
		if grep -q "^        ${name}: \${${name}:-${old}}$" "$COMPOSE"; then
			sed -i "s|^        ${name}: \${${name}:-${old}}$|        ${name}: \${${name}:-${new}}|" "$COMPOSE"
			changed=$((changed + 1))
		fi
		;;
	esac
	case "$want" in *e*)
		if grep -q "^${name}=${old}$" "$ENVEXAMPLE"; then
			sed -i "s|^${name}=${old}$|${name}=${new}|" "$ENVEXAMPLE"
			changed=$((changed + 1))
		fi
		;;
	esac
	printf '%s %s' "$changed" "${#want}"
}

# 版本条目：<ARG 名>:<npm 包名>[:skip]
# pnpm 只是构建工具，且升级它可能改变依赖解析结果 —— 默认只报告不自动写。
ENTRIES=(
	"DSH_VERSION:@deepseek-ai/dsh"
	"DSH_AUTH_GATE_VERSION:dsh-auth-gate"
	"PNPM_VERSION:pnpm:skip"
)

updated=0
have_update=0
unmatched=0
printf '%-26s %-14s %-14s %s\n' "配置项" "当前" "最新" "动作"
printf '%-26s %-14s %-14s %s\n' "--------------------------" "--------------" "--------------" "----"

for entry in "${ENTRIES[@]}"; do
	IFS=':' read -r name pkg mode <<<"$entry"
	[ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue

	old="$(current_pin "$name")"
	if [ -z "$old" ]; then
		printf '%-26s %-14s %-14s %s\n' "$name" "?" "?" "读不到当前值，跳过"
		continue
	fi
	new="$(npm_latest "$pkg" || true)"
	if [ -z "$new" ]; then
		printf '%-26s %-14s %-14s %s\n' "$name" "$old" "?" "查询失败，保留现值"
		continue
	fi

	if [ "$old" = "$new" ]; then
		printf '%-26s %-14s %-14s %s\n' "$name" "$old" "$new" "已最新"
		continue
	fi

	# 「不自动改」的条目（如 pnpm）只提示，不参与「是否有可更新项」的判断 ——
	# 否则定时任务会因为构建工具的小版本更新而反复开空 PR。
	if [ "$mode" = "skip" ]; then
		printf '%-26s %-14s %-14s %s\n' "$name" "$old" "$new" "有新版本（不自动改，仅提示）"
		continue
	fi

	have_update=1
	if [ "$CHECK" = "1" ]; then
		printf '%-26s %-14s %-14s %s\n' "$name" "$old" "$new" "可更新"
		continue
	fi
	# apply_version 在 stdout 报「改动数 目标数」（见其注释）。
	# 改动数 < 目标数 说明有目标文件不是预期写法 —— 多半是格式漂移，必须失败，
	# 否则会开出一个没改完（甚至没改）的空 PR，而看起来像"自动更新在工作"。
	av_out="$(apply_version "$name" "$old" "$new")"
	n_changed="${av_out%% *}"
	n_want="${av_out##* }"
	printf '%-26s %-14s %-14s %s\n' "$name" "$old" "$new" "已写入 ${n_changed}/${n_want} 处"
	updated=$((updated + 1))
	if [ "$n_changed" != "$n_want" ]; then
		unmatched=$((unmatched + 1))
	fi
done

echo
if [ "$CHECK" = "1" ]; then
	if [ "$have_update" = "1" ]; then
		echo "存在可更新的版本（--check 模式，未改动任何文件）"
		exit 1
	fi
	echo "全部已是最新"
	exit 0
fi

if [ "$updated" = "0" ]; then
	echo "没有需要写入的变化"
else
	echo "已更新 $updated 项；受影响文件：Dockerfile、docker-compose.yml、.env.example"
	echo "注意：跨次版本（如 0.1.x → 0.2.x）可能有破坏性变更，建议先看上游 release notes 再合并。"
fi

# 有项匹配不上就明确失败：定时任务据此不开 PR，而不是开一个什么都没改的空 PR。
if [ "$unmatched" != "0" ]; then
	echo
	echo "错误：有 $unmatched 项的旧值在目标文件里找不到（格式可能已漂移）。" >&2
	echo "      请手工确认 Dockerfile / docker-compose.yml / .env.example 里的写法。" >&2
	exit 1
fi
