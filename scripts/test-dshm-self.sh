#!/usr/bin/env bash
# dshm 自身版本与「只认 tag」机制的离线单测。
#
# 为什么要测：dshm 的版本只从**发布 tag** 更新，绝不跟随 main —— 用户明确要求
# 「以免更新到我没决定确定版本的代码」。这条契约一旦被改回 main，就等于把未经决定的
# 中间提交装到生产上，而且不会有任何报错。所以这里把它钉住。
#
# 另外钉住「发布包必须整包」这条：dshm 会 source 同目录的 scripts/*.sh，单个脚本文件
# 在任何地方都跑不起来，而自更新面向的是没有这些文件的部署机。
#
# 全程用本地临时 git 仓库，不碰网络、不碰真实仓库。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/test-lib.sh"

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# ── 造一个本地「远端」仓库并打若干 tag ──────────────────────────────────────
export GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL:-$tmp/gitconfig}"
printf '[safe]\n\tdirectory = *\n' >"$GIT_CONFIG_GLOBAL"
git init -q --bare "$tmp/remote.git"
git init -q "$tmp/seed"
cd "$tmp/seed"
git config user.email t@t
git config user.name t
echo x >f
git add -A
git commit -qm c1
# 故意包含容易排错的：2026.09.9 vs 2026.09.30（字符串排序会把 9 排前面）
for t in v2025.12.31 v2026.09.9 v2026.09.10 v2026.09.30 v2026.10.1; do git tag "$t"; done
# 非 v 开头的 tag 必须被忽略
git tag release-2026.11.01
git push -q "$tmp/remote.git" --tags

# 把 dshm 里被测的函数抽出来
fnfile="$tmp/fn.sh"
for fn in dshm_version dshm_tags dshm_latest_tag dshm_tag_sha dshm_raw_url dshm_release_url; do
	awk "/^${fn}\\(\\)/,/^}/" "$root/dshm" >>"$fnfile"
done
CLI_NAME=dshm
PROJECT_DIR="$root"
DSHM_REPO_URL="$tmp/remote.git"
DSHM_VERSION_RAW="__VERSION__"
# shellcheck source=/dev/null
. "$fnfile"

echo "== dshm 自身版本与 tag =="

# 版本从 git / VERSION 推断（占位符未替换时的路径）
v="$(dshm_version)"
if [ -n "$v" ] && [ "$v" != "dev" ]; then
	pass "能推断出当前版本（$v）"
else
	fail "推断不出当前版本，实际 '$v'"
fi

# 只列 v* tag，且忽略 release-*
out="$(dshm_tags)"
n="$(printf '%s\n' "$out" | grep -c . || true)"
if [ "$n" = "5" ]; then
	pass "只列出 v* 开头的 tag（5 个，忽略了 release-*）"
else
	fail "tag 数量应为 5，实际 ${n}：$out"
fi

# 降序且版本感知：2026.10.1 > 2026.09.30 > 2026.09.10 > 2026.09.9 > 2025.12.31
got="$(printf '%s\n' "$out" | awk '{print $2}' | tr '\n' ' ')"
want="2026.10.1 2026.09.30 2026.09.10 2026.09.9 2025.12.31 "
if [ "$got" = "$want" ]; then
	pass "按版本降序（字符串排序会把 2026.09.9 排在 2026.09.30 前面）"
else
	fail "排序不对：$got"
fi

latest="$(dshm_latest_tag)"
if [ "$latest" = "2026.10.1" ]; then
	pass "dshm_latest_tag 取到最新的 tag"
else
	fail "最新 tag 应为 2026.10.1，实际 '$latest'"
fi

# 指定 tag 能查到 sha（回退功能依赖它）
sha="$(dshm_tag_sha 2026.09.30)"
if [ "${#sha}" = "40" ]; then
	pass "dshm_tag_sha 能查到指定版本的 commit"
else
	fail "查不到 2026.09.30 的 sha：'$sha'"
fi

# 不存在的 tag 必须返回非 0（让调用方能在下载前就拒绝，而不是下到 404 页面）
if dshm_tag_sha "2099.01.01" | grep -q .; then
	fail "不存在的 tag 不该返回 sha"
else
	pass "不存在的 tag 查不到 sha（下载前即可拒绝）"
fi

# 下载地址必须指向该 tag 的 release 包，而不是 main —— 这是「只认 tag」的核心
url="$(dshm_release_url 2026.09.30)"
case "$url" in
*"/releases/download/v2026.09.30/dshm-v2026.09.30.tar.gz") pass "下载地址指向该 tag 的 release 包" ;;
*) fail "下载地址应指向 tag 的 release 包，实际 $url" ;;
esac
case "$url" in
*/main/*) fail "下载地址不该指向 main：$url" ;;
*) pass "下载地址不指向 main（只认 tag）" ;;
esac

echo
echo "== 发布包必须是整包（dshm 依赖同目录 scripts/）=="

# dshm 会 source 同目录的 scripts/*.sh，所以单独一个脚本文件跑不起来
if grep -qE '^[[:space:]]*\.[[:space:]]*\./scripts/' "$root/dshm"; then
	pass "dshm 确实会 source 同目录的 scripts/（因此必须发整包）"
else
	fail "未找到对 scripts/ 的 source —— 测试前提已变，请复核"
fi

missing=""
for f in env-config.sh migrate-home.sh admin.sh; do
	grep -qE "\./scripts/${f}" "$root/dshm" || missing="$missing $f"
done
if [ -z "$missing" ]; then
	pass "三个依赖文件都在源码中被引用"
else
	fail "未被引用的依赖文件：$missing"
fi

# 自更新必须按 tar 包解压安装，而不是直接覆盖单个文件
if grep -q 'tar -xzf "\$tgz"' "$root/dshm"; then
	pass "自更新按 tar 包解压安装"
else
	fail "自更新未使用 tar 解包"
fi

# 安装前必须逐个校验包内容，缺任何一个就拒绝（不能装到一半才发现）
if grep -qF '[ -f "$src/$f" ]' "$root/dshm" && grep -qF '[ -f "$src/dshm" ]' "$root/dshm"; then
	pass "安装前逐个校验包内容完整性（缺文件即拒绝）"
else
	fail "安装前未逐个校验包内容"
fi

# 校验必须发生在**写目标文件之前**：否则会把一个残缺的包装上一半
line_check="$(grep -nF '[ -f "$src/$f" ]' "$root/dshm" | head -1 | cut -d: -f1)"
line_install="$(grep -nF 'install -m "$mode"' "$root/dshm" | head -1 | cut -d: -f1)"
if [ -n "$line_check" ] && [ -n "$line_install" ] && [ "$line_check" -lt "$line_install" ]; then
	pass "校验先于安装（校验在第 ${line_check} 行，安装在第 ${line_install} 行）"
else
	fail "校验与安装的顺序不对（校验=$line_check 安装=$line_install）"
fi

echo
echo "== 发布版的版本号必须写死（部署机没有 git/VERSION）=="

# CI 用 sed 把赋值行写死、并把「占位符还在不在」的判断改成恒真。
# 只替换赋值而不管判断，会让判断永远为真、绕过版本号去走推断分支，最终显示成 dev。
if grep -q 'if true; then' "$root/.github/workflows/build.yml"; then
	pass "CI 会把版本判断改成恒真（否则发布版会显示成 dev）"
else
	fail "CI 未处理版本判断，发布版会显示成 dev"
fi
if grep -q '__VERSION__' "$root/.github/workflows/build.yml"; then
	pass "CI 按 __VERSION__ 定位待替换内容"
else
	fail "CI 里找不到 __VERSION__ 替换逻辑"
fi

run_tests
