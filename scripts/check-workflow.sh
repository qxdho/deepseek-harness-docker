#!/usr/bin/env bash
# 检查 workflow 里内嵌 shell 的问题 —— 目标是**能在本地预先复现 CI 的检查**。
#
# 为什么需要它：CI 用 actionlint 校验 workflow，而 actionlint 的 shellcheck 部分
# **依赖 runner 上装了 shellcheck**。本地往往没装，于是 actionlint「静默通过」、
# CI 却报错 —— 这个坑反复踩过：悬空 `&&`、SC2015、SC2153/SC2215，以及一次多次编辑
# workflow 后留下的孤儿代码片段（CI 报 SC2215/SC1089，本地却看不出）。
#
# 本脚本做两件事：
#   1. 逐个 `run: |` 块跑 `bash -n`（纯语法，任何环境都能跑）—— 孤儿代码、括号不匹配
#      这类问题在这一步就会暴露
#   2. 若找得到 shellcheck，就按 actionlint 的方式（先把 `${{ }}` 换成占位符）对每个块
#      跑 shellcheck，把 CI 会报的问题提前拿到
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

# 找 shellcheck（顺序：$SHELLCHECK → PATH → ~/bin → /workspace/.local/bin）
sc=""
for cand in "${SHELLCHECK:-}" "$(command -v shellcheck 2>/dev/null || true)" \
	"$HOME/bin/shellcheck" /workspace/.local/bin/shellcheck; do
	if [ -n "$cand" ] && [ -x "$cand" ]; then
		sc="$cand"
		break
	fi
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 把一个 workflow 的每个 run: | 块抽成独立文件：
#   $tmp/<name>.<i>   块内容
#   $tmp/<name>.count 块数量
extract() {
	# 只用两个参数：($1=workflow 文件, $2=块名)。输出目录用全局 $tmp。
	# 早先写成 `local d="$2" dirout="$d/$name"` 的形式，但同一行里引用自己，
	# set -u 下报 unbound variable。
	local f="$1" name="$2" dirout="$tmp/$name"
	mkdir -p "$dirout"
	# awk 变量名不要用 dir —— shell 里已有 $dir，set -u 下会报 unbound variable。
	awk -v od="$dirout" '
		/^[[:space:]]*run: \|/ {
			match($0, /^[[:space:]]*/); r = RLENGTH; n++
			cur = n
			next
		}
		cur == 0 { next }
		{
			if ($0 ~ /^[[:space:]]*$/) { print "" > (od "/b" cur); next }
			match($0, /^[[:space:]]*/); ind = RLENGTH
			if (ind <= r) { cur = 0; next }
			print > (od "/b" cur)
		}
		END { print n + 0 > (od "/count") }
	' "$f"
}

fails=0
total=0
sc_findings=0

for f in "${files[@]}"; do
	name="$(basename "$f" .yml)"
	extract "$f" "$name"
	n="$(cat "$tmp/$name/count" 2>/dev/null || echo 0)"

	broken=0
	i=1
	while [ "$i" -le "$n" ]; do
		blk="$tmp/$name/b$i"
		if [ -s "$blk" ]; then
			total=$((total + 1))
			if ! bash -n "$blk" 2>"$tmp/err"; then
				broken=$((broken + 1))
				fails=$((fails + 1))
				warn "$name 第 $i 个内嵌脚本语法错误（孤儿代码 / 括号不匹配）"
				head -3 "$tmp/err" | sed 's/^/        /'
			fi
			if [ -n "$sc" ]; then
				# 与 actionlint 一致：先替换 GitHub 表达式，否则 shellcheck 会把
				# ${{ ... }} 当成非法参数展开（SC2296）而误报。
				#
				# 每个**出现**都替换成唯一占位符。若都换成同一个字符串，
				# `[ "${{ github.event_name }}" = "pull_request" ]` 会被看成
				# 「常量比较恒假」而误报 SC2050；只按行号区分也不够，因为同一行
				# 可能有两个表达式被替换成同一个值。
				awk '{
					out = ""
					rest = $0
					while (match(rest, /\$\{\{[^}]*\}\}/)) {
						cnt++
						out = out substr(rest, 1, RSTART - 1) "EXPR" cnt
						rest = substr(rest, RSTART + RLENGTH)
					}
					print out rest
				}' "$blk" >"$tmp/e$i"
				if ! "$sc" -s bash "$tmp/e$i" >"$tmp/o$i" 2>&1; then
					# 只警告、不退码：本脚本用「唯一占位符」替代 GitHub 表达式，
					# 无法完美复刻 actionlint 的处理，会残留 SC2050 这类误报。
					# CI 的权威是 actionlint；这里的作用是提前看到可能的真问题。
					sc_findings=$((sc_findings + 1))
					warn "$name 第 $i 个内嵌脚本 shellcheck 有提示（供参考）"
					grep -E 'SC[0-9]+' "$tmp/o$i" | head -5 | sed 's/^/        /'
				fi
			fi
		fi
		i=$((i + 1))
	done
	if [ "$broken" = "0" ]; then
		ok "$name：$n 个内嵌脚本块语法正确"
	fi

	# SC2015 形态（`A && B || C` 不是 if-then-else）。**只扫抽出来的 run: 块**：
	# 早先这里 grep 的是整个 workflow YAML，于是 GitHub Actions 的合法表达式
	# `if: a && b || c` 会被判成问题并让本检查失败（假红）。YAML 里的 if: 是
	# GH Actions 表达式语言，不是 shell，SC2015 根本不适用。
	sc_lines=""
	i=1
	while [ "$i" -le "$n" ]; do
		blk="$tmp/$name/b$i"
		if [ -s "$blk" ]; then
			found="$(grep -nE '^[[:space:]]*[^#[:space:]].*(&&.*\|\||\|\|.*&&)' "$blk" 2>/dev/null || true)"
			if [ -n "$found" ]; then
				sc_lines="${sc_lines}${sc_lines:+$'\n'}第 ${i} 块：${found}"
			fi
		fi
		i=$((i + 1))
	done
	if [ -n "$sc_lines" ]; then
		fails=$((fails + 1))
		warn "$name：发现 SC2015 形态（与运算接或运算不是 if-then-else）"
		printf '%s\n' "$sc_lines" | sed 's/^/        /'
	fi
done

# ── 作业级 if 的语义检查（YAML 合法 ≠ 条件写对）────────────────────────────
# 这个坑真踩过：`checks` 的条件写成 `github.ref == 'refs/heads/main'`，而注释声称
# 「推 main 与 PR 上跑」。**PR 的 github.ref 是 `refs/pull/<N>/merge`**，所以 PR 永远
# 跳过检查 —— 仓库当时没有 PR，一直没暴露。actionlint 也查不出这种语义错误。
#
# 这里做一条最小但有效的检查：本 workflow 显式声明了 `pull_request:` 触发器，就必须
# 至少有一个作业会在 PR 上跑（否则触发器形同虚设）。
for wf in "$root"/.github/workflows/*.yml; do
	[ -f "$wf" ] || continue
	name="$(basename "$wf")"
	# 只有声明了 pull_request 触发器的 workflow 才适用
	if ! grep -qE '^  pull_request:' "$wf"; then
		continue
	fi
	# 找出所有「会在 PR 上跑」的作业条件：出现 pull_request 字样的 if
	if ! grep -qE "github\.event_name == 'pull_request'|github\.event_name == \"pull_request\"" "$wf"; then
		fails=$((fails + 1))
		warn "$name：声明了 pull_request 触发器，但没有任何作业的条件包含 pull_request —— PR 上不会有检查跑"
		printf '        修复：相关作业的 if 加上 `github.event_name == '"'"'pull_request'"'"'`（PR 的 github.ref 是 refs/pull/<N>/merge）\n'
	fi
done

printf '\n  共检查 %s 个内嵌脚本块\n' "$total"
if [ -z "$sc" ]; then
	warn "没找到 shellcheck —— 只做了语法检查，CI 的 shellcheck 部分未在本地复现"
	warn "装上后本脚本会自动启用：https://github.com/koalaman/shellcheck/releases"
else
	ok "已用 shellcheck 检查（$sc），与 CI 的 actionlint 同一套规则"
	[ "$sc_findings" = "0" ] || warn "shellcheck 报告 $sc_findings 个块有问题"
fi
[ "$fails" = "0" ] || exit 1
ok "workflow 内嵌脚本检查通过"
