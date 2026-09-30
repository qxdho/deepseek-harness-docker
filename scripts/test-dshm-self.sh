#!/usr/bin/env bash
# dshm 自身版本与「只认 tag」机制的离线单测。
#
# 为什么要测：dshm 的版本只从**发布 tag** 更新，绝不跟随 main —— 你明确说过
# 「以免更新到我没决定确定版本的代码」。这条契约一旦被改回 main，就等于把
# 未经决定的中间提交装到生产上，而且不会有任何报错。所以这里把它钉住。
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
for fn in dshm_version dshm_tags dshm_latest_tag dshm_tag_sha dshm_raw_url; do
	awk "/^${fn}\\(\\)/,/^}/" "$root/dshm" >>"$fnfile"
done
CLI_NAME=dshm
PROJECT_DIR="$root"
DSHM_REPO_URL="$tmp/remote.git"
DSHM_VERSION_RAW="__VERSION__"
# shellcheck source=/dev/null
. "$fnfile"

echo "== dshm 自身版本与 tag =="

# 版本读自 VERSION 文件（占位符未替换时的回退路径）
v="$(dshm_version)"
if [ -n "$v" ] && [ "$v" != "dev" ]; then
	pass "能从仓库 VERSION 读到版本（$v）"
else
	fail "读不到版本，实际 '$v'"
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

# 下载地址必须指向该 tag，而不是 main —— 这是「只认 tag」的核心
url="$(dshm_raw_url 2026.09.30)"
case "$url" in
*"/v2026.09.30/dshm") pass "下载地址指向该 tag" ;;
*) fail "下载地址应指向 tag，实际 $url" ;;
esac
case "$url" in
*/main/*) fail "下载地址不该指向 main：$url" ;;
*) pass "下载地址不指向 main（只认 tag）" ;;
esac

# dshm 源码里不应再有任何「跟随 main」的痕迹
if grep -qE 'refs/heads/main|raw\.githubusercontent\.com/[^/]*/[^/]*/main' "$root/dshm"; then
	fail "dshm 里仍有跟随 main 的代码（违反只认 tag 的约定）"
else
	pass "dshm 源码中已无 main 引用"
fi

run_tests
