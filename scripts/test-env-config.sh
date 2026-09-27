#!/usr/bin/env bash
# scripts/env-config.sh 的离线测试。
#
#   ./scripts/test-env-config.sh
#
# 覆盖「空则询问、非空跳过」的核心行为：非交互 fail-closed、校验失败重问、
# 可选项留空、占位符视为未配置、密码二次确认。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
ENV_FILE="$sandbox/.env"

# 库要求的输出函数（消息照常输出，断言用 pass/fail）
hdr() { :; }
ok() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# shellcheck source=scripts/env-config.sh
. "$HERE/env-config.sh"

# 密码走隐藏输入；测试用最简 stub：每次读一行到 SECRET
read_secret() { IFS= read -r SECRET || SECRET=""; }

echo "== 1. 已有值 → 跳过，不覆盖 =="
printf 'K=keep\n' >"$ENV_FILE"
out="$(INTERACTIVE=0 ensure_env K "键" "def" 0 "")"
[ "$(get_env K)" = "keep" ] && pass "原有值保持不变" || fail "原有值被改成了 $(get_env K)"
case "$out" in *"已配置，跳过"*) pass "输出说明是跳过" ;; *) fail "输出未说明跳过：$out" ;; esac

echo "== 2. 非交互 + 为空 + 有默认 → 写入默认 =="
: >"$ENV_FILE"
INTERACTIVE=0 ensure_env K2 "键2" "def2" 0 "" >/dev/null
[ "$(get_env K2)" = "def2" ] && pass "写入了默认值" || fail "默认值未写入（$(get_env K2)）"

echo "== 3. 非交互 + 必填为空 → 报错退出（fail-closed）=="
: >"$ENV_FILE"
set +e
out="$(INTERACTIVE=0 ensure_env K3 "键3" "" 0 "" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] && pass "非交互缺必填项 → rc=$rc" || fail "应报错却成功"
case "$out" in *"K3"*) pass "报错指名了缺失的键" ;; *) fail "报错未指名：$out" ;; esac

echo "== 4. 交互 + 输入值 → 写入 =="
: >"$ENV_FILE"
printf 'hello\n' | INTERACTIVE=1 ensure_env K4 "键4" "def" 0 "" >/dev/null
[ "$(get_env K4)" = "hello" ] && pass "写入了用户输入" || fail "未写入（$(get_env K4)）"

echo "== 5. 交互 + 直接回车 → 用默认 =="
: >"$ENV_FILE"
printf '\n' | INTERACTIVE=1 ensure_env K5 "键5" "def5" 0 "" >/dev/null
[ "$(get_env K5)" = "def5" ] && pass "回车接受默认值" || fail "默认值未生效（$(get_env K5)）"

echo "== 6. 交互 + 校验失败后重问 =="
: >"$ENV_FILE"
printf 'abc\n70000\n8080\n' | INTERACTIVE=1 ensure_env P "端口" "3080" 0 env_validate_port >/dev/null
[ "$(get_env P)" = "8080" ] && pass "非法值被拒绝，最终写入合法值" || fail "校验未生效（$(get_env P)）"

echo "== 7. 交互 + 可选项留空 → 跳过 =="
: >"$ENV_FILE"
printf '\n' | INTERACTIVE=1 ensure_env OPT "可选" "" 1 "" >/dev/null
[ -z "$(get_env OPT)" ] && pass "可选项留空不写入" || fail "可选项被写入（$(get_env OPT)）"

echo "== 8. 占位符视为未配置（密码）=="
printf 'DSH_AUTH_PASSWORD=请换成至少14位且含大小写/数字/符号的强密码\n' >"$ENV_FILE"
printf 'StrongPassw0rd!\nStrongPassw0rd!\n' | INTERACTIVE=1 ensure_password >/dev/null
[ "$(get_env DSH_AUTH_PASSWORD)" = 'StrongPassw0rd!' ] && pass "占位符被真实密码替换" || fail "占位符未被替换"

echo "== 9. 密码：先不一致、再弱密码、最后合法 =="
: >"$ENV_FILE"
printf 'aaa\nbbb\nshort\nshort\nGoodPassw0rd!x\nGoodPassw0rd!x\n' | INTERACTIVE=1 ensure_password >/dev/null
[ "$(get_env DSH_AUTH_PASSWORD)" = 'GoodPassw0rd!x' ] && pass "不一致/弱密码被拒，最终写入合规密码" || fail "密码流程异常"

echo "== 10. 密码已配置 → 非交互也跳过 =="
printf 'DSH_AUTH_PASSWORD=AlreadyGood!123\n' >"$ENV_FILE"
set +e
INTERACTIVE=0 ensure_password >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$(get_env DSH_AUTH_PASSWORD)" = 'AlreadyGood!123' ]; then
	pass "已有密码非交互直接跳过"
else
	fail "已有密码处理异常（rc=$rc）"
fi

echo "== 11. 密码为空 + 非交互 → 报错 =="
: >"$ENV_FILE"
set +e
# 必须放进子 shell：die 会 exit，直接调用会把整个测试脚本带走
( INTERACTIVE=0 ensure_password >/dev/null 2>&1 )
rc=$?
set -e
[ "$rc" -ne 0 ] && pass "非交互缺密码 → rc=$rc" || fail "应报错却成功"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
