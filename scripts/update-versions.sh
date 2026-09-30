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
apply_version() {
	local name="$1" old="$2" new="$3" changed=0

	if grep -q "^ARG ${name}=${old}$" "$DOCKERFILE"; then
		sed -i "s|^ARG ${name}=${old}$|ARG ${name}=${new}|" "$DOCKERFILE"
		changed=1
	fi
	# compose 里是 ${NAME:-旧值} 形式
	if grep -q "^        ${name}: \${${name}:-${old}}$" "$COMPOSE"; then
		sed -i "s|^        ${name}: \${${name}:-${old}}$|        ${name}: \${${name}:-${new}}|" "$COMPOSE"
		changed=1
	fi
	if grep -q "^${name}=${old}$" "$ENVEXAMPLE"; then
		sed -i "s|^${name}=${old}$|${name}=${new}|" "$ENVEXAMPLE"
		changed=1
	fi
	return 0
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
	apply_version "$name" "$old" "$new"
	printf '%-26s %-14s %-14s %s\n' "$name" "$old" "$new" "已写入三个文件"
	updated=$((updated + 1))
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
