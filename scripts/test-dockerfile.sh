#!/usr/bin/env bash
# Dockerfile 的离线结构检查。由 test-all.sh 自动发现。
#
# 为什么需要它：CI 现在**只在打镜像 tag 时才构建镜像**（日常推 main 只跑离线测试），
# 于是 Dockerfile 坏了可以一路合进 main 而没人发现 —— 直到某个维护者打 tag 构建，
# 才发现镜像根本出不来。真实案例：一次编辑把 `FROM ${NODE_IMAGE}`（第二个阶段）连同
# 阶段 1 的收尾一起删掉了，`COPY --from=builder` 便出现在 builder 阶段自己里面，
# 构建报 `circular dependency detected on stage: builder`，而离线测试全绿。
#
# 检查项（都只需要读文件，不需要 docker）：
#   1. 至少两个阶段，且每个 `FROM` 都在
#   2. `COPY --from=X` 只能引用**之前**定义的阶段，不能引用自己或后面的阶段
#   3. `RUN` 必须真的有命令（只有 `VAR=value` 的 RUN 等于什么都没做）
#   4. 本地 `COPY` 的源在构建上下文里确实存在
#   5. 结尾有 `USER` 与 `ENTRYPOINT`
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/test-lib.sh"

DF="$ROOT/Dockerfile"
[ -f "$DF" ] || {
	fail "找不到 Dockerfile"
	run_tests
	exit 0
}

section "1. 阶段结构"
# 把续行拼成逻辑行（忽略注释），供后续解析
LOGICAL="$(awk '
	{ line=$0 }
	/^[[:space:]]*#/ { next }
	{
		if (line ~ /\\[[:space:]]*$/) {
			sub(/\\[[:space:]]*$/, "", line)
			hold = hold line
			next
		}
		print hold line
		hold = ""
	}
	END { if (hold != "") print hold }
' "$DF")"

stage_count="$(printf '%s\n' "$LOGICAL" | grep -cE '^[[:space:]]*FROM[[:space:]]')"
[ "$stage_count" -ge 2 ] && pass "有 ${stage_count} 个构建阶段（≥2）" \
	|| fail "只找到 ${stage_count} 个 FROM —— 多阶段构建的第二个 FROM 很可能被删了"

# 阶段名按顺序收集（FROM ... AS name，也接受 --platform 前缀）
declare -a stages=()
while IFS= read -r name; do
	[ -n "$name" ] && stages+=("$name")
done < <(printf '%s\n' "$LOGICAL" | sed -nE 's/^[[:space:]]*FROM[[:space:]]+[^[:space:]]+([[:space:]]+AS[[:space:]]+([A-Za-z0-9_.-]+))?.*/\2/Ip' | grep . || true)
# 阶段名（最后那个运行阶段通常不写 AS，属正常）。这里只要求：能解析出名字，
# 且 builder 阶段有名字 —— `COPY --from=builder` 全靠它。
case " ${stages[*]} " in
*" builder "*) pass "阶段名可解析且包含 builder：${stages[*]}" ;;
*) fail "解析不出 builder 阶段名（实际：${stages[*]:-无}）—— COPY --from=builder 会失效" ;;
esac

section "2. COPY --from 只能引用更早的阶段"
bad_ref=0
cur=0 # 当前阶段序号（从 0 开始），按顺序推进
while IFS= read -r line; do
	# 注意：case 用的是 **glob**，不是正则 —— `[[:space:]]*X` 的含义是「一个空白 +
	# 任意字符 + X」，需要前导空白才匹配。所以先 trim，再按 `X[[:space:]]*` 判断。
	probe="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//')"
	case "$probe" in
	FROM[[:space:]]* | FROM)
		cur=$((cur + 1))
		name="${stages[$((cur - 1))]:-}"
		# 阶段自身不能 FROM 自己（按名字引用时）
		img="$(printf '%s' "$probe" | sed -nE 's/^FROM[[:space:]]+([^[:space:]]+).*/\1/p')"
		if [ -n "$name" ] && [ "$img" = "$name" ]; then
			fail "阶段 ${name} 的 FROM 指向了自己：$probe"
			bad_ref=1
		fi
		;;
	COPY[[:space:]]*--from=* | ADD[[:space:]]*--from=*)
		ref="$(printf '%s' "$probe" | sed -nE 's/.*--from=([A-Za-z0-9_.-]+).*/\1/p')"
		idx=""
		i=0
		while [ "$i" -lt "${#stages[@]}" ]; do
			[ "${stages[$i]}" = "$ref" ] && idx="$((i + 1))"
			i=$((i + 1))
		done
		if [ -z "$idx" ]; then
			# 数字引用（--from=0）只在范围内才合法
			case "$ref" in
			[0-9]*) [ "$ref" -lt "$cur" ] && idx="$((ref + 1))" || idx="" ;;
			esac
		fi
		if [ -z "$idx" ]; then
			fail "--from=${ref} 引用了一个还不存在的阶段（当前是第 ${cur} 个）：$line"
			bad_ref=1
		elif [ "$idx" -ge "$cur" ]; then
			fail "--from=${ref} 引用了自己或后面的阶段（当前是第 ${cur} 个）—— 会报 circular dependency：$line"
			bad_ref=1
		fi
		;;
	esac
done <<<"$LOGICAL"
[ "$bad_ref" = "0" ] && pass "所有 --from 都指向更早的阶段"

section "3. RUN 必须真的有命令"
bad_run=0
while IFS= read -r line; do
	# 只处理 RUN 行（否则 ARG/ENV 这类"赋值看起来像 RUN"的行会被误报一屏）。
	# case 是 glob：`[[:space:]]*RUN` 需要前导空白，所以先 trim 再判断。
	probe="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//')"
	case "$probe" in
	RUN[[:space:]]* | RUN) ;;
	*) continue ;;
	esac
	# 去掉 RUN 关键字、--mount=… 之类的 flag，以及开头的 VAR=value 赋值。
	# 每一步都必须让字符串真的变短，否则 `--flag`（后面没有空格也没有命令）会让
	# 这里死循环 —— 写这段时正是踩了这个坑。
	rest="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*RUN[[:space:]]*//')"
	while :; do
		# 每轮先去行首空白：拼过续行之后 token 之间是多空格，去掉一个 flag 后
		# 下一个 token 前面还留着空格，不 trim 就会匹配不上、把纯赋值当成命令。
		rest="$(printf '%s' "$rest" | sed -E 's/^[[:space:]]+//')"
		case "$rest" in
		--* | [A-Za-z_][A-Za-z0-9_]*=*)
			case "$rest" in
			*" "*) rest="${rest#* }" ;;
			*) rest="" ;;
			esac
			;;
		*) break ;;
		esac
	done
	rest="$(printf '%s' "$rest" | tr -d '[:space:]')"
	if [ -z "$rest" ]; then
		fail "有一行 RUN 只有环境变量赋值、没有命令（等于什么都没做）：${line:0:80}"
		bad_run=1
	fi
done <<<"$LOGICAL"
[ "$bad_run" = "0" ] && pass "每个 RUN 都有实际命令"

section "4. 本地 COPY 的源存在"
bad_src=0
while IFS= read -r line; do
	# 只处理 COPY / ADD 行；别的指令不要被误当成 COPY（HEALTHCHECK 的 --interval=…
	# 之类曾被当成了源路径，报出一屏假失败）。case 是 glob，先 trim 再判断。
	probe="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//')"
	case "$probe" in
	COPY[[:space:]]* | ADD[[:space:]]*) ;;
	*) continue ;;
	esac
	spec="$(printf '%s' "$probe" | sed -E 's/^(COPY|ADD)[[:space:]]+//')"
	case " $spec " in
	*--from=*) continue ;;
	esac
	# shellcheck disable=SC2086
	set -- $spec
	[ "$#" -ge 2 ] || continue
	dest="$#"
	i=1
	while [ "$i" -lt "$dest" ]; do
		eval "src=\${$i}"
		case "$src" in
		--*) ;;
		*)
			# 允许 glob；用 compgen 判断
			if ! compgen -G "$ROOT/$src" >/dev/null 2>&1; then
				fail "COPY 的源不存在于构建上下文：$src"
				bad_src=1
			fi
			;;
		esac
		i=$((i + 1))
	done
done <<<"$LOGICAL"
[ "$bad_src" = "0" ] && pass "所有本地 COPY 源都存在"

section "5. 运行镜像的收尾"
grep -qE '^[[:space:]]*USER[[:space:]]' <<<"$LOGICAL" && pass "设置了 USER" || fail "缺少 USER"
grep -qE '^[[:space:]]*ENTRYPOINT[[:space:]]' <<<"$LOGICAL" && pass "设置了 ENTRYPOINT" || fail "缺少 ENTRYPOINT"
grep -qE '^[[:space:]]*HEALTHCHECK[[:space:]]' <<<"$LOGICAL" && pass "设置了 HEALTHCHECK" || fail "缺少 HEALTHCHECK"

run_tests
