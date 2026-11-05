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

run_tests
