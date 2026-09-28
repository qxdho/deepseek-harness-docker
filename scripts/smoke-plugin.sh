#!/usr/bin/env bash
# pnpm store 记账（node_modules/.modules.yaml）与插件安装的回归测试。
#
#   ./scripts/smoke-plugin.sh <镜像名>      例如 dsh-test:smoke
#
# 背景：pnpm 每次装插件都会拿 .modules.yaml 里记的 storeDir 与当前环境算出的 store
# 比对，不一致就报 ERR_PNPM_UNEXPECTED_STORE 拒绝安装。镜像里那份 profile 若是
# 构建期以 root 装的，记的就是 /root/.local/share/pnpm/store/v11，而运行期
# HOME=$DSH_HOME，于是用户第一次装插件必然失败。
#
# 这个测试分两层：
#   A. 离线（必须过）：镜像不带该记录；存量卷里的旧记录会被启动时清掉。
#   B. 联网（可选）：真的装一次插件，确认不再报 UNEXPECTED_STORE。
set -euo pipefail

IMAGE="${1:-dsh-test:smoke}"
NAME="dsh-plug-$$"
PASS=0
FAIL=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 容器内的数据根与 profile（与 docker-compose.yml 的默认值一致）
CONTAINER_HOME="${CONTAINER_HOME:-/dsh}"
PROFILE="$CONTAINER_HOME/profiles/web"

start_container() {
	cleanup
	docker run -d --name "$NAME" \
		-e DSH_AUTH_USER=admin \
		-e DSH_AUTH_PASSWORD='SmokePass-1234!' \
		"$@" \
		"$IMAGE" >/dev/null
	# 等 healthcheck 之外的东西就绪：只要 entrypoint 跑过清理逻辑即可
	local i
	for i in $(seq 1 72); do
		local st
		st="$(docker inspect --format '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo unknown)"
		[ "$st" = "healthy" ] && return 0
		sleep 5
	done
	return 1
}

echo "== A1. 镜像内的预置 profile 不能带 pnpm store 记账 =="
# 这是最廉价也最关键的一条：记录一旦被烤进镜像，运行期路径必然失配。
# 用 --entrypoint 绕开 entrypoint，直接看镜像里的文件。
if docker run --rm --entrypoint sh "$IMAGE" -c "test -f /opt/dsh-seed/profiles/web/node_modules/.modules.yaml"; then
	bad "镜像里的 profile 仍带 .modules.yaml（pnpm store 记账），装插件会报 UNEXPECTED_STORE"
else
	ok "镜像内的 profile 不带 .modules.yaml"
fi

echo "== A2. 存量卷里的旧记录会被启动时清掉 =="
# 模拟旧镜像播种留下的坏状态：先起容器，塞入一份指错的记录，再重启。
if start_container; then
	ok "容器已就绪"
else
	bad "容器未在预期时间内健康"
fi

if docker exec "$NAME" sh -c "mkdir -p '$PROFILE/node_modules' && printf '\"storeDir\": \"/root/.local/share/pnpm/store/v11\"\n' > '$PROFILE/node_modules/.modules.yaml'"; then
	ok "已注入模拟的旧记账"
else
	bad "无法注入模拟的旧记账"
fi

# 重启让 entrypoint 再跑一遍清理
docker restart "$NAME" >/dev/null
for i in $(seq 1 72); do
	st="$(docker inspect --format '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo unknown)"
	[ "$st" = "healthy" ] && break
	sleep 5
done

if docker exec "$NAME" test -f "$PROFILE/node_modules/.modules.yaml"; then
	bad "旧记账未被清除，装插件仍会失配"
else
	ok "旧记账已被启动逻辑清除"
fi

# 清除记录不能顺手把插件本体删掉
if docker exec "$NAME" test -f "$PROFILE/node_modules/dsh-auth-gate/package.json"; then
	ok "插件本体仍在（清理不影响已装插件）"
else
	bad "清理把插件本体弄丢了"
fi

echo "== B. 真的装一次插件（需要网络；无网络时跳过）=="
# 用已经装过的包做「幂等 add」：不需要新下载，但仍会让 pnpm 走一遍
# store 兼容性检查 —— 正是这一步在旧镜像上抛 ERR_PNPM_UNEXPECTED_STORE。
if docker exec "$NAME" sh -c "cd '$PROFILE' && pnpm config get registry" >/dev/null 2>&1; then
	set +e
	out="$(docker exec -w "$PROFILE" "$NAME" pnpm add dsh-auth-gate@0.15.0 2>&1)"
	rc=$?
	set -e
	if printf '%s' "$out" | grep -q 'ERR_PNPM_UNEXPECTED_STORE'; then
		bad "pnpm 仍报 UNEXPECTED_STORE"
		printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
	elif [ "$rc" -eq 0 ]; then
		ok "pnpm add 成功（无 store 失配）"
	else
		# 网络不可用等外部原因不算失败，但要说明
		printf '  \033[33mSKIP\033[0m pnpm add 未成功但非 store 失配（rc=%s，可能是无网络）\n' "$rc"
		printf '%s\n' "$out" | tail -3 | sed 's/^/      /'
	fi
else
	echo "  SKIP 容器内无法运行 pnpm"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
