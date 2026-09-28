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
PASS=0
FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

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
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
