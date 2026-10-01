#!/usr/bin/env bash
# 检查 workflow 里内嵌 shell 的问题 —— 不依赖 shellcheck。
#
# 为什么需要它：CI 里用 actionlint 校验 workflow，而 actionlint 的 shellcheck 检查
# **依赖 runner 上装了 shellcheck**。本地（或任何没装 shellcheck 的环境）跑 actionlint
# 会「静默通过」，于是同一个问题只在 CI 暴露 —— 这个坑真踩过两次：
#
#   1) `if:` 表达式以 `&&` 结尾（悬空）→ 整个 workflow 被 GitHub 拒绝，0 个作业
#   2) `A && B || { ...; exit 1; }` 简写 → shellcheck SC2015，兜底分支会在不该执行时执行
#
# 本脚本覆盖这两类的**语法**层面：抽出每个 `run: |` 块逐个 `bash -n`，并扫描 SC2015
# 形态（同一行同时出现 && 与 ||）。它替代不了 shellcheck 的语义分析，但能在没有
# shellcheck 的环境里挡住上面两类。
#
#   ./scripts/check-workflow.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/log.sh"

shopt -s nullglob
files=("$root"/.github/workflows/*.yml)
shopt -u nullglob
[ "${#files[@]}" -gt 0 ] || die "没有找到 .github/workflows/*.yml"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fails=0
total=0

for f in "${files[@]}"; do
	name="$(basename "$f")"

	# 抽出 run: | 的正文。规则：记录 `run: |` 那一行的缩进 R；其后的行
	#   * 空行      → 属于块（保留）
	#   * 缩进 > R  → 属于块
	#   * 缩进 <= R → 块结束（这一步最初写漏了，导致把后面的 YAML 也吃进来）
	awk -v dir="$tmp" '
		/^[[:space:]]*run: \|/ {
			match($0, /^[[:space:]]*/); r = RLENGTH; n++; next
		}
		{
			if (r == "") next
			if ($0 ~ /^[[:space:]]*$/) { print "" > (dir "/b" n); next }
			match($0, /^[[:space:]]*/); ind = RLENGTH
			if (ind <= r) { r = ""; next }
			print > (dir "/b" n)
		}
		END { print n + 0 > (dir "/count") }
	' "$f"

	n="$(cat "$tmp/count" 2>/dev/null || echo 0)"
	broken=0
	i=1
	while [ "$i" -le "$n" ]; do
		if [ -s "$tmp/b$i" ]; then
			total=$((total + 1))
			if ! bash -n "$tmp/b$i" 2>"$tmp/err"; then
				broken=$((broken + 1))
				fails=$((fails + 1))
				fail "$name 第 $i 个内嵌脚本语法错误"
				head -3 "$tmp/err" | sed 's/^/        /'
			fi
		fi
		i=$((i + 1))
	done
	if [ "$broken" = "0" ]; then
		ok "$name：$n 个内嵌脚本块语法正确"
	fi

	# SC2015 形态。只看非注释行：`A && B || C`（或反过来）。
	sc_lines="$(grep -nE '^[[:space:]]*[^#[:space:]].*(&&.*\|\||\|\|.*&&)' "$f" 2>/dev/null || true)"
	if [ -n "$sc_lines" ]; then
		fails=$((fails + 1))
		fail "$name：发现 SC2015 形态（与运算接或运算不是 if-then-else）"
		printf '%s\n' "$sc_lines" | sed 's/^/        /'
	else
		ok "$name：无 SC2015 形态"
	fi
done

printf '\n  共检查 %s 个内嵌脚本块\n' "$total"
[ "$fails" = "0" ] || exit 1
ok "workflow 内嵌脚本检查通过"
