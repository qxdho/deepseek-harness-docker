#!/usr/bin/env bash
# dshm v2 的离线测试：不启动 Docker，只验证 CLI/模板/安装生成。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/test-lib.sh"

DSHM="$root/dshm"
[ -x "$DSHM" ] || { fail "dshm 不存在或没有可执行位"; run_tests; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

section "dshm v2"

if "$DSHM" help >/dev/null 2>&1; then pass "help 可执行"; else fail "help 失败"; fi
if "$DSHM" version 2>/dev/null | grep -q 'dshm：'; then pass "version 输出 dshm 版本"; else fail "version 输出异常"; fi

# 安装 dry-run：不碰 Docker，只生成 compose/.env。
printf 'TestPassword123!\n' |
	"$DSHM" docker install --dir "$tmp/inst" --data-dir "$tmp/data" \
		--no-pull --dry-run --container qxdho-dsh-v2 --password-stdin >/dev/null 2>&1
[ -f "$tmp/inst/.env" ] && pass "生成 .env" || fail "没有生成 .env"
[ -f "$tmp/inst/docker-compose.yml" ] && pass "生成 compose" || fail "没有生成 compose"
[ "$(stat -c '%a' "$tmp/inst/.env")" = "600" ] && pass ".env 权限 600" || fail ".env 权限不是 600"
grep -q '^DSH_AUTH_PASSWORD=TestPassword123!$' "$tmp/inst/.env" && pass "密码写入 .env" || fail "密码没写入"
grep -q 'DSH_HOME_HOST=.*/data' "$tmp/inst/.env" && pass "数据目录写入 .env" || fail "数据目录没写入"
grep -q '^DSHM_CONTAINER=qxdho-dsh-v2$' "$tmp/inst/.env" && pass "容器名写入 .env" || fail "容器名没写入"
grep -q 'DSH_HOST: 0.0.0.0' "$tmp/inst/docker-compose.yml" && pass "compose 使用 0.0.0.0" || fail "compose 没有 0.0.0.0"

# 已存在实例时拒绝覆盖
set +e
"$DSHM" docker install --dir "$tmp/inst" --no-pull --dry-run --password-stdin </dev/null >/dev/null 2>&1
rc=$?
set -e
[ "$rc" != "0" ] && pass "已有 .env 时拒绝覆盖" || fail "已有 .env 时仍继续"

# 短密码拒绝
set +e
printf 'short\n' | "$DSHM" docker install --dir "$tmp/short" --no-pull --dry-run --password-stdin >/dev/null 2>&1
rc=$?
set -e
[ "$rc" != "0" ] && pass "短密码被拒绝" || fail "短密码被接受"

# 容器名非法字符拒绝
set +e
printf 'TestPassword123!\n' | "$DSHM" docker install --dir "$tmp/badname" --no-pull --dry-run \
	--container 'bad name' --password-stdin >/dev/null 2>&1
rc=$?
set -e
[ "$rc" != "0" ] && pass "非法容器名被拒绝" || fail "非法容器名被接受"

# docker 无子命令时给帮助
if "$DSHM" docker >/dev/null 2>&1; then pass "docker 无子命令显示帮助"; else fail "docker 无子命令失败"; fi


# init -> 编辑 .env -> install 的完整离线流程（假 docker）
mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
compose*) exit 0 ;;
inspect*) echo healthy; exit 0 ;;
*) exit 0 ;;
esac
FAKE
chmod +x "$tmp/bin/docker"

"$DSHM" docker init --dir "$tmp/flow" --image dsh-v2:local --container qxdho-dsh-v2 --port 3081 >/dev/null
sed -i 's/^DSH_AUTH_PASSWORD=$/DSH_AUTH_PASSWORD=TestPassword123!/' "$tmp/flow/.env"
HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/cfg" XDG_DATA_HOME="$tmp/data" PATH="$tmp/bin:$PATH" "$DSHM" --dir "$tmp/flow" docker install --no-pull >/dev/null
[ -f "$tmp/flow/state.json" ] && pass "init 后 install 生成 state.json" || fail "init 后 install 没生成 state"
grep -q '"image": "dsh-v2:local"' "$tmp/flow/state.json" && pass "state 记录镜像" || fail "state 镜像不对"
grep -q '^DSHM_CONTAINER=qxdho-dsh-v2$' "$tmp/flow/.env" && pass "state 容器名保留" || fail "容器名丢失"


run_tests
