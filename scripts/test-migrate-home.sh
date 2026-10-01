#!/usr/bin/env bash
# scripts/migrate-home.sh 的离线测试：不需要 docker，用 shell 函数替身模拟。
#
#   ./scripts/test-migrate-home.sh
#
# 覆盖的关键点（这些都是"搬错就丢数据/删别人容器"的风险位）：
#   1. 没有旧卷 → 不动任何东西
#   2. 目标目录非空 → 绝不写入（返回 2）
#   3. 目标为空 + 有旧卷 → 复制过去，且源卷只读、结束后仍存在
#   4. 旧卷被本项目容器占用 → 先停容器再搬
#   5. 旧卷被别的容器占用 → auto 模式跳过、explicit 模式报错退出
#   6. 复制失败 → auto 模式不阻断启动，explicit 模式报错
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$(dirname "$0")/test-lib.sh"

[ -f "$HERE/migrate-home.sh" ] || { echo "缺少 $HERE/migrate-home.sh"; exit 1; }

sandbox="$(mktemp -d "$HERE/.migrate-test.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT

# 库要求的输出函数（消息这里静默，断言用 pass/fail）
hdr() { :; }
info() { :; }
warn() { :; }
ok() { :; }
die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

# 库里只用到 scripts/env-config.sh 的一个函数：读 .env 的键（缺省时给默认值）。
# 这里给一份最小实现，免得为了一个函数把整个 env-config.sh 拉进来（它自带 ok/warn
# 消息输出，会和测试的断言计数混在一起）。
env_value() {
	local v
	v="$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-)"
	printf '%s' "${v:-$2}"
}

# ── docker 替身 ─────────────────────────────────────────────────────────────
# 状态全部放在 $FAKE 目录里：
#   $FAKE/volumes   —— docker volume ls 的输出（一行一个卷名）
#   $FAKE/ps        —— docker ps -q --filter volume=… 的输出（一行一个容器 id）
#   $FAKE/inspect-<id>-name/-image
#   $FAKE/run-fail  —— 存在时 docker run 失败
#   $FAKE/calls     —— 调用流水（用于断言"没有调用过 docker run/stop"）
FAKE=""
docker() {
	printf '%s\n' "$*" >>"$FAKE/calls"
	case "$1" in
	volume)
		# docker volume ls --format '{{.Name}}'
		cat "$FAKE/volumes" 2>/dev/null || true
		;;
	ps)
		cat "$FAKE/ps" 2>/dev/null || true
		;;
	inspect)
		local fmt="" id=""
		shift
		while [ $# -gt 0 ]; do
			case "$1" in
			--format) fmt="$2"; shift 2 ;;
			*) id="$1"; shift ;;
			esac
		done
		case "$fmt" in
		'{{.Name}}') printf '/%s\n' "$(cat "$FAKE/inspect-$id-name" 2>/dev/null || echo "id-$id")" ;;
		'{{.Config.Image}}') cat "$FAKE/inspect-$id-image" 2>/dev/null || true ;;
		esac
		;;
	stop)
		printf 'stopped %s\n' "$2" >>"$FAKE/stopped"
		;;
	run)
		[ -f "$FAKE/run-fail" ] && return 1
		# 真正的复制逻辑：从 $FAKE/src 搬到目标目录（模拟 tar 管道）
		local dest="" arg
		for arg in "$@"; do
			case "$arg" in
			*:/to) dest="${arg%:/to}" ;;
			esac
		done
		[ -n "$dest" ] || return 1
		cp -a "$FAKE/src/." "$dest/"
		;;
	esac
	return 0
}

# 复位替身状态：reset_fake <卷名…>
reset_fake() {
	rm -rf "$FAKE"
	mkdir -p "$FAKE/src"
	: >"$FAKE/volumes"
	: >"$FAKE/ps"
	: >"$FAKE/calls"
	local v
	for v in "$@"; do printf '%s\n' "$v" >>"$FAKE/volumes"; done
}

# 每个用例一个独立的 .env + 目标目录 + 卷内容
new_case() {
	CASE="$sandbox/$1"
	mkdir -p "$CASE"
	FAKE="$CASE/fake"
	ENV_FILE="$CASE/.env"
	: >"$ENV_FILE"
}

dst_of() { printf '%s' "$CASE/data"; }

# 目标目录写一行配置：本次被测的键
set_dest() { printf 'DSH_HOME_HOST=%s\nDSH_UID=%s\nDSH_GID=%s\n' "$(dst_of)" "$(id -u)" "$(id -g)" >"$ENV_FILE"; }

# shellcheck source=scripts/migrate-home.sh
. "$HERE/migrate-home.sh"

# ── 1. 没有旧卷 ─────────────────────────────────────────────────────────────
echo "== 1. 没有旧命名卷 → 什么都不做 =="
new_case no-volume
set_dest
reset_fake
rc=0
migrate_legacy_home auto || rc=$?
[ "$rc" = "1" ] && pass "返回 1（无需迁移）" || fail "应返回 1，实际 $rc"
[ -e "$(dst_of)" ] && fail "不该创建目标目录" || pass "没有创建目标目录"
grep -q '^run ' "$FAKE/calls" && fail "不该调用 docker run" || pass "没有调用 docker run"

# ── 2. 目标目录非空 → 绝不写入 ──────────────────────────────────────────────
echo "== 2. 目标目录已有数据 → 不动 =="
new_case dest-nonempty
set_dest
mkdir -p "$(dst_of)"
echo 'settings: keep-me' >"$(dst_of)/settings.yaml"
reset_fake old_dsh-home
printf 'from-volume\n' >"$FAKE/src/settings.yaml"
rc=0
migrate_legacy_home auto || rc=$?
[ "$rc" = "2" ] && pass "返回 2（目标非空）" || fail "应返回 2，实际 $rc"
grep -q '^run ' "$FAKE/calls" && fail "不该复制" || pass "没有复制"
[ "$(cat "$(dst_of)/settings.yaml")" = "settings: keep-me" ] \
	&& pass "目标目录里的数据未被覆盖" || fail "目标数据被改动了"

# ── 3. 空目标 + 有旧卷 → 复制 ───────────────────────────────────────────────
echo "== 3. 目标为空 + 有旧卷 → 复制过去 =="
new_case happy
set_dest
reset_fake old_dsh-home
echo 'from-volume' >"$FAKE/src/settings.yaml"
rc=0
migrate_legacy_home auto || rc=$?
[ "$rc" = "0" ] && pass "返回 0（已迁移）" || fail "应返回 0，实际 $rc"
[ "$(cat "$(dst_of)/settings.yaml" 2>/dev/null)" = "from-volume" ] \
	&& pass "数据已复制到 DSH_HOME_HOST" || fail "数据没有复制过去"
grep -q '^volume ls' "$FAKE/calls" && pass "查了旧卷列表" || fail "没查旧卷列表"
grep -q -- '-v old_dsh-home:/from:ro' "$FAKE/calls" && pass "源卷以只读方式挂载" || fail "源卷不是只读挂载"

# ── 4. 旧卷被本项目容器占用 → 先停再搬 ──────────────────────────────────────
echo "== 4. 旧卷被本项目容器占用 → 先停容器 =="
new_case own-container
set_dest
reset_fake old_dsh-home
printf 'abc123\n' >"$FAKE/ps"
printf 'dsh\n' >"$FAKE/inspect-abc123-name"
printf 'ghcr.io/qxdho/deepseek-harness-docker:latest\n' >"$FAKE/inspect-abc123-image"
echo 'from-volume' >"$FAKE/src/settings.yaml"
rc=0
migrate_legacy_home auto || rc=$?
[ "$rc" = "0" ] && pass "返回 0（已迁移）" || fail "应返回 0，实际 $rc"
grep -q '^stop abc123' "$FAKE/calls" && pass "停掉了旧容器" || fail "没有停旧容器"
[ -f "$(dst_of)/settings.yaml" ] && pass "迁移仍然完成" || fail "迁移未完成"

# ── 5a. 旧卷被别的容器占用 → auto 跳过 ─────────────────────────────────────
echo "== 5a. 旧卷被别的容器占用 → auto 模式跳过 =="
new_case foreign-auto
set_dest
reset_fake old_dsh-home
printf 'xyz789\n' >"$FAKE/ps"
printf 'some-other-app\n' >"$FAKE/inspect-xyz789-name"
printf 'postgres:16\n' >"$FAKE/inspect-xyz789-image"
rc=0
migrate_legacy_home auto || rc=$?
[ "$rc" = "3" ] && pass "返回 3（跳过，不阻断启动）" || fail "应返回 3，实际 $rc"
grep -q '^stop ' "$FAKE/calls" && fail "不该停别人的容器" || pass "没有停别人的容器"
grep -q '^run ' "$FAKE/calls" && fail "不该复制" || pass "没有复制"
auto_migrate_legacy_home && pass "auto_migrate_legacy_home 不阻断启动（返回 0）" || fail "auto 包装不应失败"

# ── 5b. 旧卷被别的容器占用 → explicit 报错 ─────────────────────────────────
echo "== 5b. 旧卷被别的容器占用 → explicit 模式报错退出 =="
new_case foreign-explicit
set_dest
reset_fake old_dsh-home
printf 'xyz789\n' >"$FAKE/ps"
printf 'some-other-app\n' >"$FAKE/inspect-xyz789-name"
printf 'postgres:16\n' >"$FAKE/inspect-xyz789-image"
rc=0
( migrate_legacy_home explicit ) >/dev/null 2>&1 || rc=$?
[ "$rc" != "0" ] && pass "explicit 模式报错退出（rc=$rc）" || fail "explicit 模式应报错退出"
grep -q '^run ' "$FAKE/calls" && fail "不该复制" || pass "没有复制"

# ── 6. 复制失败的处理 ───────────────────────────────────────────────────────
echo "== 6. 复制失败 =="
new_case run-fail
set_dest
reset_fake old_dsh-home
: >"$FAKE/run-fail"
rc=0
migrate_legacy_home auto || rc=$?
[ "$rc" = "3" ] && pass "auto 模式返回 3（不阻断）" || fail "auto 应返回 3，实际 $rc"
rc=0
( migrate_legacy_home explicit ) >/dev/null 2>&1 || rc=$?
[ "$rc" != "0" ] && pass "explicit 模式报错退出（rc=$rc）" || fail "explicit 模式应报错退出"

echo

# ── 6b. 复制失败后目标目录必须保持原样、且不留临时目录 ─────────────────────
# 以前 tar 是直接写目标目录的：失败时目标里已经留了半份数据，而下次运行会因为
# 「目标非空」直接跳过（dest_is_empty 判定），提示却写着「原数据未改动，可重试」
# —— 用户拿到的是一份半迁移的数据目录，且没有回滚路径。
# 现在改成先拷到 ${dest}.migrating.$$ 再改名，失败时目标不受影响、重试仍然可行。
echo "== 6b. 复制失败不污染目标目录 =="
new_case run-fail
set_dest
reset_fake old_dsh-home
: >"$FAKE/run-fail"
rc=0
migrate_legacy_home auto || rc=$?
dest_dir="$(dst_of)"
if [ "$rc" = "3" ]; then
	pass "auto 模式返回 3（不阻断）"
else
	fail "auto 应返回 3，实际 $rc"
fi
if [ -z "$(ls -A "$dest_dir" 2>/dev/null)" ]; then
	pass "失败后目标目录仍为空（没有半成品数据）"
else
	fail "失败却在目标里留下了数据：$(ls -A "$dest_dir" | tr '\n' ' ')"
fi
leftover="$(find "$(dirname "$dest_dir")" -maxdepth 1 -name '*.migrating.*' 2>/dev/null | head -3)"
if [ -z "$leftover" ]; then
	pass "失败后没有残留 .migrating 临时目录"
else
	fail "残留了临时目录：$leftover"
fi

# ── 7. 多个项目各有旧卷时，绝不任取一个 ─────────────────────────────────────
# 原来 `docker volume ls | grep dsh-home | head -n1` 会任取第一个 —— 同机多项目时
# 会把**别的项目的数据**迁进本项目，还打印「迁移成功」。目标被污染且用户看不出来，
# 比"迁移失败"危险得多。现在：优先本项目（COMPOSE_PROJECT_NAME 或目录名），
# 认不出且有多个候选时就 fail-closed。
echo "== 7. 多项目同名旧卷时不猜 =="

# 7a. 明确指定了 COMPOSE_PROJECT_NAME → 只认本项目那个
new_case multi-project
set_dest
reset_fake alpha_dsh-home beta_dsh-home
rc=0
COMPOSE_PROJECT_NAME=beta migrate_legacy_home auto || rc=$?
if [ "$rc" = "0" ]; then
	pass "指定 COMPOSE_PROJECT_NAME=beta 时迁移成功（认出本项目）"
else
	fail "指定项目名后应能迁移，实际 rc=$rc"
fi
# beta 的复制内容来自同一个假 src，这里只要确认它没因为"多个候选"被跳过
grep -q '^run ' "$FAKE/calls" && pass "并确实执行了复制" || fail "没有执行复制"

# 7b. 没有项目名、多个候选 → 必须失败而不是任取
new_case multi-project-2
set_dest
reset_fake alpha_dsh-home beta_dsh-home
# **必须在 reset_fake 之后**写入 marker：reset_fake 会重建（清空）$FAKE/src，
# 顺序反了就是"往空目录里复制"，下面两条污染断言会变成假通过 —— 上一版正是如此：
# 把 legacy_dsh_home_volume 换回旧的 `| head -n1` 任取，这两条照样 PASS。
printf 'alpha-project-secret\n' >"$FAKE/src/settings.yaml"
printf 'alpha-only\n' >"$FAKE/src/alpha-marker.txt"
# 自检：marker 必须真的存在于"源卷"里，否则后面的断言没有意义
if [ -f "$FAKE/src/alpha-marker.txt" ]; then
	pass "夹具就绪：源卷里有只属于别的项目的 marker"
else
	fail "夹具错误：源卷里没有 marker（污染断言会假通过）"
fi
rc=0
out7="$(migrate_legacy_home explicit 2>&1)" || rc=$?
[ "$rc" != "0" ] && pass "多候选且无法判断时 explicit 模式报错退出（rc=$rc）" \
	|| fail "多候选时应报错，却成功退出"
case "$out7" in
*"多个旧数据卷"*) pass "错误里说明了「检测到多个旧数据卷」" ;;
*) fail "缺少针对性诊断：$(printf '%s' "$out7" | tail -2 | tr '\n' ' ')" ;;
esac
# 诊断里要列出候选卷名，否则用户没法判断该用哪个
case "$out7" in
*alpha_dsh-home*) pass "列出了候选卷（alpha_dsh-home）" ;;
*) fail "没有列出候选卷名" ;;
esac
# **最关键**：这种情况下一个字节都不该往目标目录写
if [ -z "$(ls -A "$(dst_of)" 2>/dev/null)" ]; then
	pass "多候选时目标目录保持为空（没有把别人的数据迁进来）"
else
	fail "多候选却写了数据：$(ls -A "$(dst_of)" | tr '\n' ' ')"
fi
if [ -f "$(dst_of)/alpha-marker.txt" ] || [ -f "$(dst_of)/settings.yaml" ]; then
	fail "把别的项目的数据迁进来了：$(ls -A "$(dst_of)" | tr '\n' ' ')"
else
	pass "别的项目的数据（含 marker）没有被写入目标"
fi

# 7c. 只有一个候选时照常自动迁移（不能因为加了守卫就不干活）
new_case single
set_dest
reset_fake only_dsh-home
rc=0
migrate_legacy_home auto || rc=$?
[ "$rc" = "0" ] && pass "只有一个候选时照常自动迁移" || fail "单候选应能迁移，实际 rc=$rc"

# ── 8. 落位与属主：两个"报了成功但其实是坏的"路径 ─────────────────────────────
echo "== 8. 落位失败与属主改写失败都必须明确失败 =="

# 这两条用例专门验"报错路径"的**用户可见输出**，所以临时把 warn/info 改成会打印的
# （测试顶部把它们定义成 `:` 是为了让其它用例的输出干净——这里必须看到内容）。
warn() { printf 'WARN %s\n' "$*"; }
info() { printf 'INFO %s\n' "$*"; }
# ⚠ 说明局限：本机无法构造"**顶层** chown 成功、深层失败"的场景（当前进程不是 root，
# chown 整体就失败了），所以旧实现（`chown -R … || true` + 只校验顶层）在这里也会
# 因为最后那道 owner_ok 兜底而返回 3 —— **这条用例区分不出新旧实现**。
# 它仍有价值：钉住"属主改不了时必须返回非 0 且给出修复命令"这个对外行为。
# 真正修掉的是那种"顶层对了、深层还是 root"的安静成功，需要 root 环境才能复现。
# 8a. chown 报错时不能报「迁移成功」
# 原来两处 `chown -R … || true` 吞掉失败，然后只校验**顶层**目录的属主 ——
# "顶层对了、深层还是 root"也会打印成功，而深层写不进去一样让容器起不来。
new_case chown-fails
# 故意要一个不等于当前进程的 uid，这样 owner_ok 为假、必然走 chown 分支
printf 'DSH_HOME_HOST=%s\nDSH_UID=4242\nDSH_GID=4242\n' "$(dst_of)" >"$ENV_FILE"
reset_fake old_dsh-home
printf 'data\n' >"$FAKE/src/settings.yaml"
# 让"改属主"这两条路径**两种环境下都必然失败**：
#   * 非 root 分支：sudo -n 必须失败（否则会真的去 chown），用一个必然返回非 0 的
#     sudo 替身钉住；
#   * root 分支：chown 替身必然失败。
# 这条用例原先只在"当前进程不是 root"时成立 —— CI 以 root 跑，`chown -R` 直接成功、
# 脚本返回 0，测试就红了。**测试不能依赖运行者身份**。
chown() { return 1; }
sudo() { return 1; }
chown() { return 1; }
rc=0
out8a="$(migrate_legacy_home explicit 2>&1)" || rc=$?
unset -f chown sudo
[ "$rc" != "0" ] && pass "chown 失败时返回非 0（rc=$rc）" || fail "chown 失败却报成功"
case "$out8a" in
*"sudo chown -R"*) pass "提示里给出了要手工执行的 chown 命令" ;;
*) fail "没有给出 chown 修复命令：$(printf '%s' "$out8a" | tail -3 | tr '\n' ' ')" ;;
esac

# 8b. rmdir 失败时不得把临时目录塞进目标里一层
# `rmdir` 只在空目录上成功；失败说明它非空或不可删。此时 `mv tmp dest` 不替换 dest，
# 而是把 tmp 塞进 dest 里一层 —— 数据落错位置却走成功路径。
new_case rmdir-fails
set_dest
reset_fake old2_dsh-home
printf 'data\n' >"$FAKE/src/settings.yaml"
# 让目标目录存在且非空（dest_is_empty 会因此返回"非空"）→ 走不到落位；
# 所以这里改为让目标存在但"看起来空"、再让 rmdir 必然失败
mkdir -p "$(dst_of)"
rmdir() { return 1; }
rc=0
out8b="$(migrate_legacy_home explicit 2>&1)" || rc=$?
unset -f rmdir
# 无论走哪条分支，都不能出现"目标里套着一层临时目录"的形态
if find "$(dst_of)" -maxdepth 1 -name '.migrating.*' 2>/dev/null | grep -q .; then
	fail "临时目录被塞进了目标里：$(ls -A "$(dst_of)" | tr '\n' ' ')"
else
	pass "没有把临时目录塞进目标目录"
fi
[ "$rc" != "0" ] && pass "rmdir 失败时返回非 0（rc=$rc）" || pass "该场景由 dest_is_empty 提前拦下（rc=$rc），无嵌套残留"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
