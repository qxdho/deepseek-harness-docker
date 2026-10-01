#!/usr/bin/env bash
# 离线测试总入口：自动发现并运行 scripts/test-*.sh，汇总结果。
#
# 为什么要它：原来 CI 里为每个测试脚本写一个步骤，内容逐字重复
# （`chmod +x a.sh b.sh && ./b.sh`）—— 6 个步骤长得一样，新增一个测试还要记得加步骤。
# 现在新增 `scripts/test-*.sh` 会自动被跑到，CI 侧只有一个步骤。
#
#   ./scripts/test-all.sh            跑全部
#   ./scripts/test-all.sh -v         显示每个脚本的完整输出（CI 里默认显示）
#
# 退出码：0 全部通过；1 有失败。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

verbose=0
[ "${1:-}" = "-v" ] && verbose=1

# **不要**在这里 `chmod +x`。CI 有一步「可执行位守卫」专门检查 git 里的 mode；
# 本地跑测试时顺手把工作区的脚本都改成可执行，会让"忘了给新脚本加可执行位"这类问题
# 在本地永远看不到（工作区已经是 +x），而 git 里仍是 100644 —— 推到 CI 才红。
#
# 改成：发现有脚本少了可执行位就**报告**（提示怎么修），不自动改。
missing_exec=""
for s in "$here"/*.sh; do
	[ -f "$s" ] || continue
	[ -x "$s" ] || missing_exec="$missing_exec $(basename "$s")"
done
if [ -n "$missing_exec" ]; then
	printf '\n\033[33m注意\033[0m：以下脚本缺少可执行位，CI 的守卫会失败：%s\n' "$missing_exec"
	printf '      修：chmod +x scripts/<脚本>&& git add scripts/<脚本>\n'
fi

shopt -s nullglob
scripts=("$here"/test-*.sh)
shopt -u nullglob

# 排除两类：test-lib.sh 是被 source 的库；test-all.sh 是本文件自己
# （名字也匹配 test-*.sh，不排除就会无限递归调用自己）
filtered=()
for s in "${scripts[@]}"; do
	case "$(basename "$s")" in
	test-lib.sh | test-all.sh) continue ;;
	esac
	filtered+=("$s")
done

if [ "${#filtered[@]}" = "0" ]; then
	echo "没有找到任何测试脚本（scripts/test-*.sh）" >&2
	exit 1
fi

total=0
failed=0
failed_names=()

for s in "${filtered[@]}"; do
	name="$(basename "$s")"
	printf '\n\033[1m========== %s ==========\033[0m\n' "$name"
	total=$((total + 1))
	log="$(mktemp)"
	if [ "$verbose" = "1" ]; then
		if "$s" 2>&1 | tee "$log"; then :; else failed=$((failed + 1)); failed_names+=("$name"); fi
	else
		if "$s" >"$log" 2>&1; then
			# 只回显最后一行的 PASS=/FAIL= 小结
			tail -3 "$log" | grep -E '^PASS=' | sed 's/^/  /' || echo "  （无小结输出）"
		else
			tail -3 "$log" | grep -E '^PASS=' | sed 's/^/  /' || true
			failed=$((failed + 1))
			failed_names+=("$name")
			echo "  --- 失败输出（末 20 行）---"
			tail -20 "$log" | sed 's/^/    /'
		fi
	fi
	rm -f "$log"
done

printf '\n\033[1m========== 汇总 ==========\033[0m\n'
printf '  共 %s 个测试脚本，%s 个失败\n' "$total" "${#failed_names[@]}"
if [ "${#failed_names[@]}" != "0" ]; then
	printf '  失败：%s\n' "${failed_names[*]}"
	exit 1
fi
printf '  \033[32m全部通过\033[0m\n'
