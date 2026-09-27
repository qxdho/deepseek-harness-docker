#!/usr/bin/env bash
# scripts/preflight.sh 与容器内 entrypoint 工作区检查的离线回归测试。
#
#   ./scripts/test-preflight.sh
#
# 这台机器上不需要 docker：只构造宿主目录的属主/权限场景，直接验证判定逻辑。
# 覆盖当初 CI 漏掉的那条路径 —— 空的 bind mount 源目录若由 dockerd 以 root
# 创建，容器里的 node(1000) 就会写不进去（EACCES: permission denied）。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFLIGHT="$HERE/preflight.sh"
ENTRYPOINT="$HERE/../entrypoint.sh"

PASS=0
FAIL=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
have_sudo() { command -v sudo >/dev/null 2>&1; }

[ -f "$PREFLIGHT" ] || { echo "缺少 $PREFLIGHT"; exit 1; }
[ -f "$ENTRYPOINT" ] || { echo "缺少 $ENTRYPOINT"; exit 1; }

# shellcheck source=scripts/preflight.sh
. "$PREFLIGHT"

sandbox="$(mktemp -d)"
cleanup() {
	# 被测目录里可能有 chmod 000 的残留，先尽力恢复再删
	chmod -R u+rwx "$sandbox" 2>/dev/null || true
	rm -rf "$sandbox"
}
trap cleanup EXIT

echo "== 1. 工作区存在且可写 =="
project="$sandbox/ok"
mkdir -p "$project/workspace"
printf 'DSH_WORKSPACE=./workspace\n' >"$project/.env"
if check_workspace "$project" auto 0 >/dev/null 2>&1; then
	ok "可写目录返回 0"
else
	bad "可写目录应返回 0"
fi
if [ -e "$project/workspace/.dsh-write-test" ]; then
	bad "探测用的临时文件没有清理"
else
	ok "探测临时文件已清理"
fi

echo "== 2. 默认值：.env 未设 DSH_WORKSPACE =="
project="$sandbox/default"
mkdir -p "$project"
: >"$project/.env"
if check_workspace "$project" auto 0 >/dev/null 2>&1; then
	ok "默认目录 ./workspace 自动创建并通过"
else
	bad "默认目录应自动创建并通过"
fi
[ -d "$project/workspace" ] && ok "确认创建了 ./workspace" || bad "./workspace 没有被创建"

echo "== 3. 绝对路径 + ~ 展开 =="
project="$sandbox/abs"
mkdir -p "$project"
printf 'DSH_WORKSPACE=%s\n' "$sandbox/abs-target" >"$project/.env"
if check_workspace "$project" auto 0 >/dev/null 2>&1; then
	ok "绝对路径可用"
else
	bad "绝对路径应可用"
fi
[ -d "$sandbox/abs-target" ] && ok "确实建在 .env 指定的位置" || bad "没有建在指定位置"

res="$(absolute_workspace_path "$sandbox" '~/x')"
[ "$res" = "$HOME/x" ] && ok "~ 展开为 \$HOME" || bad "~ 展开错误：$res"

res="$(absolute_workspace_path /a/b './c')"
[ "$res" = "/a/b/c" ] && ok "相对路径按项目目录解析" || bad "相对路径解析错误：$res"

echo "== 4. 不可写目录必须被拦下 =="
project="$sandbox/ro"
mkdir -p "$project/workspace"
chmod 000 "$project/workspace"
printf 'DSH_WORKSPACE=./workspace\n' >"$project/.env"
set +e
out="$(check_workspace "$project" never 0 2>&1)"
rc=$?
set -e
chmod 755 "$project/workspace"
if [ "$rc" -ne 0 ]; then
	ok "不可写目录返回非 0（rc=$rc）"
else
	bad "不可写目录应返回非 0"
fi
case "$out" in
*"chown"*) ok "报错里给出了 chown 修复命令" ;;
*) bad "报错缺少 chown 提示：$out" ;;
esac
case "$out" in
*"DSH_WORKSPACE"*) ok "报错里给出了换目录的替代方案" ;;
*) bad "报错缺少替代方案" ;;
esac

echo "== 4b. .env 里带引号 / DSH_WORKSPACE_DIR 输出 =="
project="$sandbox/quoted"
mkdir -p "$project"
printf 'DSH_WORKSPACE="%s"\n' "$sandbox/quoted-target" >"$project/.env"
if check_workspace "$project" auto 0 >/dev/null 2>&1; then
	ok "带引号的值可解析"
else
	bad "带引号的值解析失败"
fi
if [ "$DSH_WORKSPACE_DIR" = "$sandbox/quoted-target" ]; then
	ok "DSH_WORKSPACE_DIR 去掉了引号"
else
	bad "DSH_WORKSPACE_DIR 不对：$DSH_WORKSPACE_DIR"
fi
[ -d "$sandbox/quoted-target" ] && ok "目录建在去引号后的位置" || bad "目录位置不对"

echo "== 5. 缺少 .env =="
project="$sandbox/noenv"
mkdir -p "$project"
set +e
check_workspace "$project" never 0 >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] && ok "缺 .env 返回 2" || bad "缺 .env 应返回 2，实际 $rc"

echo "== 6. 被 root 创建的目录（核心回归）=="
# 场景：属主是 root（dockerd 自动创建源目录时的真实状态）。
# 这里检查的是不变量本身 —— 结束后目录必须真的可写，而不只是返回码好看。
if [ "$(id -u)" = "0" ]; then
	echo "  SKIP 当前是 root，权限位对它无效"
else
	project="$sandbox/rootwned"
	mkdir -p "$project/workspace"
	printf 'DSH_WORKSPACE=./workspace\n' >"$project/.env"

	if have_sudo && sudo -n true 2>/dev/null; then
		sudo chown 0:0 "$project/workspace"
		set +e
		out="$(check_workspace "$project" auto 1 2>&1)"
		rc=$?
		set -e
		# 唯一有意义的不变量：结束后必须真的可写。
		if ( : >"$project/workspace/.dsh-write-test" ) 2>/dev/null; then
			rm -f "$project/workspace/.dsh-write-test"
			ok "免密 sudo 场景下目录最终可写"
			owner="$(stat -c '%u' "$project/workspace")"
			[ "$owner" = "1000" ] && ok "属主已改为 1000" || bad "属主是 $owner，期望 1000"
		else
			# 可接受的另一种结果：不去修，但明确报错并非 0 退出
			[ "$rc" -ne 0 ] && ok "未自动修复但明确报错退出（rc=$rc）" \
				|| bad "既没修好也没报错"
		fi
		sudo chown -R "$(id -u):$(id -g)" "$project/workspace" 2>/dev/null || true
	else
		# 无 sudo：无法伪造 root 属主，改用 000 权限验证同一条判定路径
		chmod 000 "$project/workspace"
		set +e
		out="$(check_workspace "$project" never 0 2>&1)"
		rc=$?
		set -e
		chmod 755 "$project/workspace"
		[ "$rc" -ne 0 ] && ok "跳过真实 root 属主（无免密 sudo），已用 000 权限验证同类判定" \
			|| bad "不可写却返回 0"
	fi
fi

echo "== 7. 容器内 entrypoint 的工作区检查 =="
# entrypoint.sh 会以自己所在目录为基准，所以拷到临时目录里单测它的检查逻辑。
# 只跑「工作区不可写 → 必须 exit 1 且给出 chown 提示」这一条路径。
if [ "$(id -u)" = "0" ]; then
	echo "  SKIP root 下权限位无效"
else
	stage="$sandbox/ep"
	mkdir -p "$stage"
	cp "$ENTRYPOINT" "$stage/entrypoint.sh"
	# 把 /workspace 重定向到可控目录：DSH_WORKSPACE 在 entrypoint 里是硬编码的
	# WORKSPACE=/workspace，这里用 sed 换成测试目录，避免真的去动 /workspace。
	sed -i "s#^WORKSPACE=/workspace#WORKSPACE=$sandbox/ep-ws#" "$stage/entrypoint.sh"
	mkdir -p "$sandbox/ep-ws"
	chmod 000 "$sandbox/ep-ws"
	# 用 /nonexistent 当 SEED，保证在检查之后、播种之前就失败，不会真的启动服务
	set +e
	out="$(SEED=/nonexistent DSH_HOME="$sandbox/ep-home" bash "$stage/entrypoint.sh" 2>&1)"
	rc=$?
	set -e
	chmod 755 "$sandbox/ep-ws"
	if [ "$rc" -ne 0 ]; then
		ok "entrypoint 在 /workspace 不可写时退出（rc=$rc）"
	else
		bad "entrypoint 应退出"
	fi
	case "$out" in
	*"不可写"*) ok "输出了「不可写」诊断" ;;
	*) bad "缺少诊断信息：$out" ;;
	esac
	case "$out" in
	*"chown"*) ok "诊断里含 chown 修复提示" ;;
	*) bad "诊断缺少 chown 提示" ;;
	esac
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
