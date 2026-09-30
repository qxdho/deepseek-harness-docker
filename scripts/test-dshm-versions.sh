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
run_tests
