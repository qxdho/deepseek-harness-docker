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
#   A. 离线（必须过）：镜像不带该记录；启动后 profile 里也没有；且播种/重启正常。
#   B. 联网（可选）：真的装一次插件，确认不再报 UNEXPECTED_STORE。
set -euo pipefail

IMAGE="${1:-dsh-test:smoke}"
NAME="dsh-plug-$$"
. "$(dirname "$0")/test-lib.sh"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 容器内的数据根。必须与 docker-compose.yml 一致：compose 把宿主目录挂到
# ${DSH_HOME_CONTAINER:-/dsh}，并注入同名的 DSH_HOME / HOME。裸 docker run 时
# 镜像的 ENV 是 /home/node/.dsh，与之不符 —— 所以这里显式模拟 compose。
#
# 用 --tmpfs 而不是命名卷：Docker 创建的命名卷属主是 root，容器里的 node(1000)
# 写不进去，entrypoint 会因「数据目录不可写」直接退出，测的就不是插件逻辑了。
# compose 场景下宿主目录是用户自己的，不存在这个问题。
CONTAINER_HOME="${CONTAINER_HOME:-/dsh}"
PROFILE="$CONTAINER_HOME/profiles/web"

start_container() {
	cleanup
	docker run -d --name "$NAME" \
		--tmpfs "$CONTAINER_HOME:rw,mode=1777" \
		-e DSH_HOME="$CONTAINER_HOME" \
		-e HOME="$CONTAINER_HOME" \
		-e DSH_AUTH_USER=admin \
		-e DSH_AUTH_PASSWORD='SmokePass-1234!' \
		"$IMAGE" >/dev/null
	local i st
	for i in $(seq 1 360); do
		st="$(docker inspect --format '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo unknown)"
		[ "$st" = "healthy" ] && return 0
		sleep 1
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

echo "== A2. 启动后 profile 里不应存在 store 记账；重启幂等 =="
# 这条同时覆盖一个更严重的隐患：entrypoint 以 node 身份 `cp -a` 镜像里的 seed
# 来播种 profile，若 seed 属主是 root（且含 600/700 文件），播种会直接失败、容器
# 起不来 —— 数据目录为空的全新部署必然踩到。能否 healthy 本身就是断言。
if start_container; then
	ok "容器已就绪（说明 seed 可被 node 读取并成功播种）"
else
	bad "容器未在预期时间内健康"
	docker logs --tail 20 "$NAME" 2>&1 | sed 's/^/      /'
fi

if docker exec "$NAME" test -f "$PROFILE/node_modules/.modules.yaml"; then
	bad "profile 里仍存在 .modules.yaml，运行期装插件会 store 失配"
else
	ok "profile 里没有 store 记账"
fi

# 清理逻辑不能顺手把插件本体删掉
if docker exec "$NAME" test -f "$PROFILE/node_modules/dsh-auth-gate/package.json"; then
	ok "插件本体仍在"
else
	bad "插件本体丢了"
fi

# 重启一次，确认清理是幂等的、容器仍能起来
docker restart "$NAME" >/dev/null
for i in $(seq 1 360); do
	st="$(docker inspect --format '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo unknown)"
	[ "$st" = "healthy" ] && break
	sleep 1
done

if [ "$(docker inspect --format '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)" != "true" ]; then
	bad "容器重启后未能运行"
	echo
	echo "PASS=$PASS FAIL=$FAIL"
	exit 1
fi
ok "重启后仍正常运行（清理逻辑幂等）"

echo "== B. 真的装一次插件（需要网络；无网络时跳过）=="
# 用已经装过的包做「幂等 add」：不需要新下载，但仍会让 pnpm 走一遍
# store 兼容性检查 —— 正是这一步在旧镜像上抛 ERR_PNPM_UNEXPECTED_STORE。
# pnpm 是全局装的，直接用即可（dsh 内部也是调它）。
if docker exec "$NAME" sh -c 'command -v pnpm >/dev/null 2>&1'; then
	set +e
	out="$(docker exec -w "$PROFILE" "$NAME" pnpm add dsh-auth-gate@0.15.0 2>&1)"
	rc=$?
	set -e
	if printf '%s' "$out" | grep -q 'ERR_PNPM_UNEXPECTED_STORE'; then
		bad "pnpm 仍报 UNEXPECTED_STORE"
		printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
	elif [ "$rc" -eq 0 ]; then
		ok "pnpm add 成功（无 store 失配）"
		# 装完后记录应当指向数据目录（即 .env 定义的 DSH_HOME）
		rec="$(docker exec "$NAME" sh -c "sed -n 's/.*\"storeDir\": *\"\\([^\"]*\\)\".*/\\1/p' '$PROFILE/node_modules/.modules.yaml' 2>/dev/null | head -1")"
		case "$rec" in
		"$CONTAINER_HOME"/*) ok "store 记录落在数据目录内（$rec）" ;;
		"") bad "装完后没有 store 记录" ;;
		*) bad "store 记录不在数据目录内：$rec" ;;
		esac
	else
		# 网络不可用等外部原因不算失败，但要说明
		printf '  \033[33mSKIP\033[0m pnpm add 未成功但非 store 失配（rc=%s，可能是无网络）\n' "$rc"
		printf '%s\n' "$out" | tail -3 | sed 's/^/      /'
	fi
else
	echo "  SKIP 容器内没有 pnpm"
fi

echo
run_tests
