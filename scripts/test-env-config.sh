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

echo "== 4. 无默认值的必填项 → 交互询问 =="
: >"$ENV_FILE"
printf 'hello\n' | INTERACTIVE=1 ensure_env K4 "键4" "" 0 "" >/dev/null
[ "$(get_env K4)" = "hello" ] && pass "写入了用户输入" || fail "未写入（$(get_env K4)）"

echo "== 5. 有默认值 → 交互也不询问，直接用默认 =="
# 不能再要求"回车确认默认值"：默认值就是推荐值，逐个回车只会多一次出错机会。
# 用 </dev/null 模拟"没有任何输入"，若还在询问就会读到 EOF 而失败。
: >"$ENV_FILE"
out="$(INTERACTIVE=1 ensure_env K5 "键5" "def5" 0 "" </dev/null 2>&1)"
[ "$(get_env K5)" = "def5" ] && pass "直接写入默认值" || fail "默认值未生效（$(get_env K5)）"
case "$out" in *"使用默认值"*) pass "输出说明了用的是默认值" ;; *) fail "输出未说明：$out" ;; esac
case "$out" in *"键5："*) fail "不应该出现输入提示：$out" ;; *) pass "没有出现输入提示" ;; esac

echo "== 6. 无默认值时：校验失败后重问 =="
: >"$ENV_FILE"
printf 'abc\n70000\n8080\n' | INTERACTIVE=1 ensure_env P "端口" "" 0 env_validate_port >/dev/null
[ "$(get_env P)" = "8080" ] && pass "非法值被拒绝，最终写入合法值" || fail "校验未生效（$(get_env P)）"

echo "== 7. 可选项不需要输入，直接跳过 =="
: >"$ENV_FILE"
INTERACTIVE=1 ensure_env OPT "可选" "" 1 "" </dev/null >/dev/null
[ -z "$(get_env OPT)" ] && pass "可选项不被写入" || fail "可选项被写入（$(get_env OPT)）"

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

echo "== 12. set_env 不破坏反斜杠 =="
: >"$ENV_FILE"
set_env K 'a\b'
[ "$(cat "$ENV_FILE")" = 'K=a\b' ] && pass "反斜杠原样写入" \
	|| fail "被转义成：$(od -c "$ENV_FILE" | head -1)"
[ "$(get_env K)" = 'a\b' ] && pass "读回一致" || fail "读回不一致：$(get_env K)"

echo "== 13. 已有值不合规 + 有默认值 → 改用默认值（不再要求手改）=="
printf 'P=abc\n' >"$ENV_FILE"
out="$(INTERACTIVE=0 ensure_env P "端口" "3080" 0 env_validate_port 2>&1)"
[ "$(get_env P)" = "3080" ] && pass "不合规的值被默认值覆盖" || fail "未覆盖（$(get_env P)）"
case "$out" in *"改用默认值"*) pass "输出说明了替换原因" ;; *) fail "输出未说明：$out" ;; esac

echo "== 14. 已有值不合规 + 无默认值 + 非交互 → 报错 =="
printf 'Q=abc\n' >"$ENV_FILE"
set +e
( INTERACTIVE=0 ensure_env Q "必填" "" 0 env_validate_port ) >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] && pass "无默认值可退 → 报错（rc=$rc）" || fail "不合规的必填值被放过"
[ "$(get_env Q)" = "abc" ] && pass "报错时不改动原值" || fail "原值被改动了"

echo "== 15. 容器侧路径必须绝对（空值/相对值自动纠正为默认）=="
printf 'DSH_WORKSPACE_CONTAINER=\nDSH_HOME=\n' >"$ENV_FILE"
INTERACTIVE=0 ensure_env DSH_WORKSPACE_CONTAINER "容器内工作区" "/workspace" 0 env_validate_abspath >/dev/null
INTERACTIVE=0 ensure_env DSH_HOME_CONTAINER "容器内数据目录" "/dsh" 0 env_validate_abspath >/dev/null
[ "$(get_env DSH_WORKSPACE_CONTAINER)" = "/workspace" ] && pass "空的工作区挂载点被补成 /workspace" \
	|| fail "未补默认值：$(get_env DSH_WORKSPACE_CONTAINER)"
[ "$(get_env DSH_HOME_CONTAINER)" = "/dsh" ] && pass "空的数据目录挂载点被补成 /dsh" || fail "未补默认值：$(get_env DSH_HOME_CONTAINER)"
printf 'DSH_WORKSPACE_CONTAINER=workspace\n' >"$ENV_FILE"
INTERACTIVE=0 ensure_env DSH_WORKSPACE_CONTAINER "容器内工作区" "/workspace" 0 env_validate_abspath >/dev/null
[ "$(get_env DSH_WORKSPACE_CONTAINER)" = "/workspace" ] && pass "相对路径被纠正为默认值" \
	|| fail "相对路径未被纠正：$(get_env DSH_WORKSPACE_CONTAINER)"

echo "== 16. 历史默认值对齐 =="
# 换了数据目录、工作区还是旧默认 → 工作区跟随
printf 'DSH_HOME_HOST=/data\nDSH_WORKSPACE_HOST=/dsh/workspace\n' >"$ENV_FILE"
normalize_defaults >/dev/null
[ "$(get_env DSH_WORKSPACE_HOST)" = "/data/workspace" ] && pass "工作区跟随数据目录" \
	|| fail "未跟随：$(get_env DSH_WORKSPACE_HOST)"

# 用户自己指定的工作区不动
printf 'DSH_HOME_HOST=/data\nDSH_WORKSPACE_HOST=/root/my-ws\n' >"$ENV_FILE"
normalize_defaults >/dev/null
[ "$(get_env DSH_WORKSPACE_HOST)" = "/root/my-ws" ] && pass "自定义工作区不被改动" \
	|| fail "被改成了：$(get_env DSH_WORKSPACE_HOST)"

# 旧默认容器路径 → 当前默认（宿主目录不变，不搬数据）
printf 'DSH_HOME_HOST=/data\nDSH_HOME_CONTAINER=/home/node/.dsh\n' >"$ENV_FILE"
normalize_defaults >/dev/null
[ "$(get_env DSH_HOME_CONTAINER)" = "/dsh" ] && pass "旧容器路径改为 /dsh" || fail "未改：$(get_env DSH_HOME_CONTAINER)"
[ "$(get_env DSH_HOME_HOST)" = "/data" ] && pass "宿主数据目录保持不动" || fail "宿主目录被改了"

# 已经是当前默认 → 不重复写入（文件内容保持原样，不产生无意义的变更日志）
printf 'DSH_HOME_HOST=/dsh\nDSH_HOME_CONTAINER=/dsh\nDSH_WORKSPACE_HOST=/dsh/workspace\n' >"$ENV_FILE"
before="$(cat "$ENV_FILE")"
normalize_defaults >/dev/null
[ "$(cat "$ENV_FILE")" = "$before" ] && pass "默认值场景下不改动文件" || fail "文件被无谓改动"

echo "== 17. 旧键改名迁移 =="
printf 'PROXY_PORT=9090\nDSH_WORKSPACE=/root/ws\nDSH_HOME=/home/node/.dsh\nDSH_TOTP=required\nAUTH_GATE_VERSION=0.16.0\nDEV_TOOLS=full\n' >"$ENV_FILE"
migrate_legacy_keys >/dev/null
[ "$(get_env DSH_HTTP_PORT)" = "9090" ] && pass "PROXY_PORT → DSH_HTTP_PORT" || fail "端口未迁移"
[ "$(get_env DSH_WORKSPACE_HOST)" = "/root/ws" ] && pass "DSH_WORKSPACE → DSH_WORKSPACE_HOST" || fail "工作区未迁移"
[ "$(get_env DSH_HOME_CONTAINER)" = "/home/node/.dsh" ] && pass "DSH_HOME → DSH_HOME_CONTAINER" || fail "数据目录未迁移"
[ "$(get_env DSH_AUTH_TOTP)" = "required" ] && pass "DSH_TOTP → DSH_AUTH_TOTP" || fail "TOTP 未迁移"
[ "$(get_env DSH_AUTH_GATE_VERSION)" = "0.16.0" ] && pass "AUTH_GATE_VERSION → DSH_AUTH_GATE_VERSION" || fail "插件版本未迁移"
[ "$(get_env DSH_DEV_TOOLS)" = "full" ] && pass "DEV_TOOLS → DSH_DEV_TOOLS" || fail "构建参数未迁移"
for old in PROXY_PORT DSH_WORKSPACE DSH_HOME DSH_TOTP AUTH_GATE_VERSION DEV_TOOLS; do
	has_key "$old" && fail "旧键 ${old} 仍留在 .env"
done
pass "旧键已从 .env 中删除，不会出现两个来源"

# 幂等：再跑一次不应改动文件
before="$(cat "$ENV_FILE")"
migrate_legacy_keys >/dev/null
[ "$(cat "$ENV_FILE")" = "$before" ] && pass "重复执行不改动文件" || fail "重复执行改动了文件"

# 新旧键同时存在 → 以新键为准，删掉旧键
printf 'DSH_HTTP_PORT=8081\nPROXY_PORT=9090\n' >"$ENV_FILE"
migrate_legacy_keys >/dev/null
[ "$(get_env DSH_HTTP_PORT)" = "8081" ] && pass "同时存在时保留新键" || fail "新键被旧键覆盖"
has_key PROXY_PORT && fail "旧键未被删除" || pass "旧键被删除"

echo "== 18. 迁移前也能读到旧键（兼容读取）=="
printf 'PROXY_PORT=7070\nDSH_WORKSPACE=/srv/ws\n' >"$ENV_FILE"
[ "$(env_value_new DSH_HTTP_PORT 3080)" = "7070" ] && pass "新键缺失时回退到旧键" || fail "未回退到旧键"
[ "$(env_value_new DSH_WORKSPACE_HOST /dsh/workspace)" = "/srv/ws" ] && pass "工作区同样回退" || fail "工作区未回退"
printf 'DSH_HTTP_PORT=8080\nPROXY_PORT=7070\n' >"$ENV_FILE"
[ "$(env_value_new DSH_HTTP_PORT 3080)" = "8080" ] && pass "新键优先于旧键" || fail "旧键压过了新键"
: >"$ENV_FILE"
[ "$(env_value_new DSH_HTTP_PORT 3080)" = "3080" ] && pass "都没有时用默认值" || fail "默认值未生效"

echo "== 19. TOTP 取值校验 =="
printf 'DSH_AUTH_TOTP=banana\n' >"$ENV_FILE"
INTERACTIVE=0 ensure_env DSH_AUTH_TOTP "两步验证" "optional" 0 env_validate_totp >/dev/null 2>&1
[ "$(get_env DSH_AUTH_TOTP)" = "optional" ] && pass "非法值被默认值覆盖" || fail "非法 TOTP 未被纠正：$(get_env DSH_AUTH_TOTP)"
printf 'DSH_AUTH_TOTP=required\n' >"$ENV_FILE"
INTERACTIVE=0 ensure_env DSH_AUTH_TOTP "两步验证" "optional" 0 env_validate_totp >/dev/null
[ "$(get_env DSH_AUTH_TOTP)" = "required" ] && pass "合法值保留" || fail "合法值被改动"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
