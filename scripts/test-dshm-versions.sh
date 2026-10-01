#!/usr/bin/env bash
# dsh 版本解析的离线单测（不需要网络、不需要 docker）。
#
# 被测的是 dshm 里那几段「从 npm registry 响应里取版本」的函数。这类逻辑是搜索式的
# （多解析器回退 + 字符串匹配），失效方式往往是**静默返回空**而不是报错 —— dshm 拿到
# 空版本号就会拿它去构建镜像，问题要到很后面才暴露。所以这里用假 curl 喂固定 JSON，
# 把每个回退分支都钉住。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/test-lib.sh"

# 把 dshm 里被测的几个函数抽出来（用 awk 按函数名取到闭合大括号）
fnfile="$(mktemp)"
for fn in dsh_npm_json dsh_versions_sorted dsh_dist_tags dsh_latest_version \
	current_dsh_version show_dsh_versions; do
	awk "/^${fn}\\(\\)/,/^}/" "$root/dshm" >>"$fnfile"
done
# show_dsh_versions 依赖这些（测试环境下给最小实现）
CONTAINER=qxdho-dsh
GRN=; RST=; YEL=; B=; DIM=
hdr() { :; }
info() { :; }
ok() { :; }
warn() { :; }
die() { printf 'DIE %s\n' "$*" >&2; exit 1; }
env_value_new() { printf '%s' "0.1.7-rc.2"; }
# shellcheck source=/dev/null
. "$fnfile"

# ── 假 curl：把固定 JSON 当 registry 响应返回 ───────────────────────────────
stub="$(mktemp -d)"
cat >"$stub/curl" <<'STUB'
#!/usr/bin/env bash
# 只认 -o 之外的 -fsSL；把 $FAKE_JSON 文件内容打到 stdout
cat "${FAKE_JSON:?}"
STUB
chmod +x "$stub/curl"

fake_json() {
	printf '%s' "$1" >"$stub/data.json"
	export FAKE_JSON="$stub/data.json"
	DSH_NPM_REGISTRY="https://example.invalid"
	DSH_NPM_NAME="@deepseek-ai/dsh"
}

SAMPLE='{
  "dist-tags": {"latest": "0.2.0-rc.2", "alpha": "0.1.7-alpha.2", "next": "0.2.0-rc.2"},
  "versions": {
    "0.1.5-rc.3": {}, "0.1.7-rc.2": {}, "0.2.0-rc.1": {}, "0.2.0-rc.2": {}
  }
}'

echo "== dsh 版本解析 =="
fake_json "$SAMPLE"

got="$(PATH="$stub:$PATH" dsh_latest_version 2>/dev/null || true)"
if [ "$got" = "0.2.0-rc.2" ]; then
	pass "dsh_latest_version 取到 dist-tags.latest"
else
	fail "dsh_latest_version 应返回 0.2.0-rc.2，实际 '${got}'"
fi

got="$(PATH="$stub:$PATH" dsh_versions_sorted "$SAMPLE" 2>/dev/null || true)"
n="$(printf '%s\n' "$got" | grep -c . || true)"
if [ "$n" = "4" ]; then
	pass "dsh_versions_sorted 列出全部 4 个版本"
else
	fail "dsh_versions_sorted 应列出 4 个，实际 ${n}：$got"
fi
# 必须是升序，最后一个才是最新
if [ "$(printf '%s\n' "$got" | tail -1)" = "0.2.0-rc.2" ]; then
	pass "版本按 semver 升序（最后一个是最新）"
else
	fail "顺序不对：$got"
fi

got="$(PATH="$stub:$PATH" dsh_dist_tags "$SAMPLE" 2>/dev/null || true)"
case "$got" in
*"latest=0.2.0-rc.2"*) pass "dsh_dist_tags 输出发布标签" ;;
*) fail "dsh_dist_tags 结果异常：'${got}'" ;;
esac

# 缺 dist-tags / versions 时必须**明确失败**，不能返回空串让调用方拿空版本去构建
fake_json '{"versions":{}}'
if got="$(PATH="$stub:$PATH" dsh_latest_version 2>/dev/null)"; then
	fail "缺少 dist-tags 时应返回非 0，实际返回 '${got}'"
else
	pass "缺少 dist-tags 时明确失败（不静默返回空）"
fi

# 坏 JSON 同理
fake_json 'not json at all'
if got="$(PATH="$stub:$PATH" dsh_latest_version 2>/dev/null)"; then
	fail "坏 JSON 时应返回非 0，实际返回 '${got}'"
else
	pass "坏 JSON 时明确失败"
fi

# curl 不存在时 dsh_npm_json 必须失败
if got="$(PATH="/nonexistent" dsh_npm_json 2>/dev/null)"; then
	fail "没有 curl 时 dsh_npm_json 应失败，实际返回 '${got}'"
else
	pass "没有 curl 时 dsh_npm_json 明确失败"
fi

# --json 输出必须是合法 JSON（面板直接解析它；格式一坏面板就整块不可用）
fake_json "$SAMPLE"
jsonout="$(PATH="$stub:$PATH" show_dsh_versions --json 2>/dev/null || true)"
case "$jsonout" in
"{"/"*\"current\":\"0.1.7-rc.2\""*) : ;;  # 占位，下面用 node 精确校验
esac
if command -v node >/dev/null 2>&1; then
	if printf '%s' "$jsonout" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);if(j.latest!=="0.2.0-rc.2")throw new Error("latest");if(j.versions.length!==4)throw new Error("n");if(j.current!=="0.1.7-rc.2")throw new Error("cur")})' 2>/dev/null; then
		pass "--json 输出是合法 JSON 且字段正确"
	else
		fail "--json 输出不是合法 JSON 或字段不对：$jsonout"
	fi
else
	skip "没有 node，跳过 --json 校验"
fi

# 版本号里带引号/反斜杠时也必须转义（不能让面板的 JSON 解析崩掉）
fake_json '{"dist-tags":{"latest":"1.0.0"},"versions":{"1.0.0":{},"we\"ird\\x":{}}}'
jsonout="$(PATH="$stub:$PATH" show_dsh_versions --json 2>/dev/null || true)"
if command -v node >/dev/null 2>&1; then
	if printf '%s' "$jsonout" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{JSON.parse(s)})' 2>/dev/null; then
		pass "版本号含引号/反斜杠时 JSON 仍合法（转义生效）"
	else
		fail "转义失效，JSON 解析失败：$jsonout"
	fi
fi

rm -f "$fnfile"
rm -rf "$stub"
echo "== dshm version（四个版本显示）=="
# 把 dshm 里 version 命令的实现整段抽出来跑（stub 掉 docker/env/npm），验证它确实把
# 四个「版本」都列出来，并在不一致时告警。
vfile="$(mktemp)"
awk '/^version-show\)/,/^\t;;/' "$root/dshm" | sed '1d;$d' >"$vfile"

run_version() {
	P_PINNED="$1" P_RUNNING="$2" P_LATEST="$3" P_UP="${4:-1}" bash -c '
set -euo pipefail
YEL=""; RST=""
hdr() { :; }; info() { printf "INFO:%s\n" "$*"; }; warn() { printf "WARN:%s\n" "$*"; }
require_docker() { :; }
CONTAINER=c
env_value_new() { printf "%s" "$P_PINNED"; }
env_value() { printf "IMG"; }
dsh_latest_version() { printf "%s" "$P_LATEST"; }
docker() { case "$1" in inspect) [ "$P_UP" = 1 ] && return 0 || return 1 ;; exec) printf "%s\n" "$P_RUNNING" ;; esac; }
Dockerfile=/nonexistent
. "$VFILE"
' 2>&1 || true
}
export VFILE="$vfile"

out="$(run_version 0.2.0-rc.2 0.2.0-rc.2 0.2.0-rc.2)"
for label in "配置里钉的版本" "镜像" "容器内实际运行" "npm 最新"; do
	case "$out" in
	*"$label"*) pass "列出了「$label」" ;;
	*) fail "缺少「$label」：$out" ;;
	esac
done
case "$out" in
*WARN*) fail "四者一致时不该告警：$out" ;;
*) pass "四者一致时不告警" ;;
esac

# 配置改了但没应用 → 必须告警（这是最常见的困惑来源）
out="$(run_version 0.2.0-rc.2 0.1.7-rc.2 0.2.0-rc.2)"
case "$out" in
*"不一致"*) pass "钉的版本与运行的不一致时告警" ;;
*) fail "版本不一致时未告警：$out" ;;
esac

# 有新版本 → 给出升级命令
out="$(run_version 0.1.7-rc.2 0.1.7-rc.2 0.9.9)"
case "$out" in
*"version update"*) pass "有新版本时给出升级命令" ;;
*) fail "未给出升级命令：$out" ;;
esac

# 容器没起 + 离线 → 优雅降级，不报错
out="$(run_version 0.2.0-rc.2 "" "")"
case "$out" in
*"未运行"*) pass "容器未运行时显示「未运行」" ;;
*) fail "容器未运行时的输出异常：$out" ;;
esac
rm -f "$vfile"


# ── img_base：从 DSH_IMAGE 推导镜像仓库时必须保住端口与 digest ──────────────
# 这里曾有 bug：用 `case *:*/*` 判断「冒号后面有没有路径」，于是
#   myregistry:5000            → 被截成 myregistry
#   repo@sha256:abc123         → 被截成 repo@sha256
# 而 dshm 会把这个错值 set_env 回 .env（version update 路径），用户配好的私有
# registry / digest 被悄悄改掉，直到下次 compose pull 才炸。
#
# 单独抽 img_base，用可注入的 env_value 控制 DSH_IMAGE。
ib_fn="$(mktemp)"
awk '/^img_base\(\)/,/^}/' "$root/dshm" >"$ib_fn"
ib_case() { # <DSH_IMAGE> <DSH_IMAGE_BASE> → 打印 img_base 结果
	# 必须 export：bash -c 起的是子进程，同行的赋值只存在于当前 shell 的局部环境
	export DSH_IMAGE_BASE="$2"
	DSH_IMG="$1" bash -c '
		env_value() { printf "%s" "$DSH_IMG"; }
		# shellcheck source=/dev/null
		. "'"$ib_fn"'"
		img_base
	'
}
check_ib() { # <描述> <DSH_IMAGE> <期望>
	got="$(ib_case "$2" "")"
	if [ "$got" = "$3" ]; then
		pass "img_base：$1 → $got"
	else
		fail "img_base：$1 期望「$3」实际「$got」"
	fi
}
check_ib "未配 DSH_IMAGE 时用默认" "" "ghcr.io/qxdho/deepseek-harness-docker"
check_ib "普通 repo:tag 去掉 tag" "ghcr.io/mine/repo:latest" "ghcr.io/mine/repo"
check_ib "带端口的 registry（无 tag）原样保留" "myregistry:5000/team/dsh" "myregistry:5000/team/dsh"
check_ib "带端口的 registry + tag 只去 tag" "myregistry:5000/team/dsh:v1" "myregistry:5000/team/dsh"
check_ib "裸 host:port（无路径）不被截断" "myregistry:5000" "myregistry:5000"
check_ib "digest 引用原样保留" "repo@sha256:abc123" "repo@sha256:abc123"
if [ "$(ib_case 'ghcr.io/x/y:tag' 'mirror.example.com/proj')" = "mirror.example.com/proj" ]; then
	pass "img_base：显式 DSH_IMAGE_BASE 优先"
else
	fail "img_base：显式 DSH_IMAGE_BASE 没有被优先采用"
fi
rm -f "$ib_fn"
run_tests
