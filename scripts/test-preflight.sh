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

# 判定针对的是「容器内 uid」。测试机的当前用户是谁不确定，所以凡预期成功的用例，
# 都用 write_env 把 DSH_UID/DSH_GID 写成当前用户 —— 等价于「部署者本人就是容器
# uid」，此时目录属主天然对得上。「两者不一致」的场景由第 6b 节专门验证，那正是
# root 部署出问题的那条路径。
#
# 注意 DSH_UID 的取值优先来自 .env（与 DSH_WORKSPACE 一致），所以这里写进 .env
# 而不是 export。不再 export DSH_UID，以便第 6c 节能验证「shell 环境不会意外生效」。
write_env() {
	local project="$1" ws="$2" uid="$3" gid="$4"
	mkdir -p "${project}/dsh-home"
	{
		printf 'DSH_HOME_HOST=%s/dsh-home\n' "$project"
		[ -n "$ws" ] && printf 'DSH_WORKSPACE=%s\n' "$ws"
		printf 'DSH_UID=%s\nDSH_GID=%s\n' "$uid" "$gid"
	} >"${project}/.env"
}

# 手工写 .env 的用例：确保数据目录也指向沙箱（否则默认 /dsh 需要 root）。
# 没有 .env 的用例（缺 .env 的断言）直接跳过，不能把文件创建出来。
envhome() {
	local project="$1"
	[ -f "${project}/.env" ] || return 0
	grep -q '^DSH_HOME_HOST=' "${project}/.env" && return 0
	mkdir -p "${project}/dsh-home"
	printf 'DSH_HOME_HOST=%s/dsh-home\n' "$project" >>"${project}/.env"
}

TEST_UID="$(id -u)"
TEST_GID="$(id -g)"

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
write_env "$project" ./workspace "$TEST_UID" "$TEST_GID"
	envhome "$project"
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
# 默认工作区现在是 $DSH_HOME_HOST/workspace（绝对路径 /dsh/workspace），
# 不再是项目目录下的 ./workspace。非 root 下 /dsh 建不出来，应报错并指明路径。
if [ "$(id -u)" = "0" ]; then
	echo "  SKIP root 下 /dsh 可被直接创建"
else
	project="$sandbox/default"
	mkdir -p "$project"
	write_env "$project" "" "$TEST_UID" "$TEST_GID"
	envhome "$project"
	set +e
	out="$(check_workspace "$project" never 0 2>&1)"
	set -e
	case "$out" in
	*"/dsh/workspace"*) ok "未配置时回退到 /dsh/workspace" ;;
	*) bad "默认工作区路径不对：$out" ;;
	esac
fi


echo "== 3. 绝对路径 + ~ 展开 =="
project="$sandbox/abs"
mkdir -p "$project"
write_env "$project" "$sandbox/abs-target" "$TEST_UID" "$TEST_GID"
	envhome "$project"
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
write_env "$project" ./workspace "$TEST_UID" "$TEST_GID"
set +e
	envhome "$project"
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
# 故意把值加上双引号，验证解析时会剥掉
write_env "$project" "\"$sandbox/quoted-target\"" "$TEST_UID" "$TEST_GID"
	envhome "$project"
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
	envhome "$project"
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
	write_env "$project" ./workspace "$TEST_UID" "$TEST_GID"

	if have_sudo && sudo -n true 2>/dev/null; then
		sudo chown 0:0 "$project/workspace"
		set +e
	envhome "$project"
		out="$(check_workspace "$project" auto 1 2>&1)"
		rc=$?
		set -e
		# 唯一有意义的不变量：结束后必须真的可写。
		if ( : >"$project/workspace/.dsh-write-test" ) 2>/dev/null; then
			rm -f "$project/workspace/.dsh-write-test"
			ok "免密 sudo 场景下目录最终可写"
			owner="$(stat -c '%u' "$project/workspace")"
			[ "$owner" = "$(id -u)" ] && ok "属主已改为部署者 uid（$(id -u)）" || bad "属主是 $owner，期望 $(id -u)"
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
	envhome "$project"
		out="$(check_workspace "$project" never 0 2>&1)"
		rc=$?
		set -e
		chmod 755 "$project/workspace"
		[ "$rc" -ne 0 ] && ok "跳过真实 root 属主（无免密 sudo），已用 000 权限验证同类判定" \
			|| bad "不可写却返回 0"
	fi
fi

echo "== 6b. 部署者能写、容器 uid 不能写（root 部署的核心回归）=="
# 旧实现拿「当前用户」的写测试当结论：root 部署时 ./workspace 是 root:root 0755，
# root 写得进 → 预检假通过 → 容器里的 node(1000) 写不进 → crash-loop。
# 这里构造「部署者可写、容器 uid 不可写」，必须被拦下。
# 容器 uid 走 .env 设置（与 DSH_WORKSPACE 一致的取值来源）。
project="$sandbox/foreign-uid"
mkdir -p "$project/workspace"
chmod 700 "$project/workspace"
foreign_uid=$(( TEST_UID == 1000 ? 1001 : 1000 ))
foreign_gid="$foreign_uid"
write_env "$project" ./workspace "$foreign_uid" "$foreign_gid"
if ( : >"$project/workspace/.dsh-write-test" ) 2>/dev/null; then
	rm -f "$project/workspace/.dsh-write-test"
	ok "前置条件成立：部署者可写"
else
	bad "前置条件失败：部署者本应可写"
fi
set +e
	envhome "$project"
out="$(check_workspace "$project" never 0 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] && ok "部署者可写但容器 uid($foreign_uid) 不可写 → 被拦下（rc=$rc）" \
	|| bad "只看当前用户可写，会放过 root 部署的假通过"
case "$out" in
*"${foreign_uid}"*) ok "报错指明了容器 uid" ;;
*) bad "报错未提容器 uid：$out" ;;
esac

echo "== 6c. DSH_UID 优先取自 .env，与 compose 同源 =="
project="$sandbox/env-precedence"
mkdir -p "$project/workspace"
write_env "$project" ./workspace 1111 2222
if [ "$(container_uid "$project/.env")" = "1111" ] &&
	[ "$(container_gid "$project/.env")" = "2222" ]; then
	ok ".env 里的 DSH_UID/DSH_GID 生效"
else
	bad ".env 里的值没生效：$(container_uid "$project/.env"):$(container_gid "$project/.env")"
fi
if [ "$(DSH_UID=9999 container_uid "$project/.env")" = "1111" ]; then
	ok ".env 的值优先于 shell 环境变量"
else
	bad "shell 环境变量错误地覆盖了 .env"
fi
project2="$sandbox/env-default"
mkdir -p "$project2"
: >"$project2/.env"
if [ "$(container_uid "$project2/.env")" = "1000" ]; then
	ok "未配置时回退到 1000"
else
	bad "未配置时应回退到 1000，实际 $(container_uid "$project2/.env")"
fi

echo "== 6d. 数据目录（DSH_HOME_HOST）检查 =="
project="$sandbox/homecheck"
mkdir -p "$project/data" "$project/ws"
printf 'DSH_HOME_HOST=%s/data\nDSH_WORKSPACE=%s/ws\n' "$project" "$project" >"$project/.env"
if check_dsh_home_dir "$project" auto 0 >/dev/null 2>&1; then
	ok "可写的数据目录通过"
else
	bad "可写的数据目录应通过"
fi
printf 'DSH_HOME_HOST=%s/data\nDSH_WORKSPACE=%s/ws\n' "$project" "$project" >"$project/.env"
chmod 000 "$project/data"
set +e
out="$(check_dsh_home_dir "$project" never 0 2>&1)"
rc=$?
set -e
chmod 755 "$project/data"
[ "$rc" -ne 0 ] && ok "不可写的数据目录被拦下（rc=$rc）" || bad "不可写却通过"
case "$out" in
*DSH_HOME_HOST*) ok "报错指明了 .env 键名 DSH_HOME_HOST" ;;
*) bad "报错未指明键名：$out" ;;
esac

echo "== 6e. 数据目录默认值 /dsh =="
if [ "$(id -u)" = "0" ]; then
	echo "  SKIP root 下 /dsh 可被直接创建"
else
	project="$sandbox/defaulthome"
	mkdir -p "$project"
	: >"$project/.env"
	set +e
	out="$(check_dsh_home_dir "$project" never 0 2>&1)"
	set -e
	case "$out" in
	*"/dsh"*) ok "未配置时回退到默认 /dsh" ;;
	*) bad "默认值不对：$out" ;;
	esac
fi


echo "== 7. 容器内 entrypoint 的工作区检查 =="
# entrypoint.sh 会以自己所在目录为基准，所以拷到临时目录里单测它的检查逻辑。
# 覆盖两条路径：DSH_WORKSPACE_STRICT=1 时 fail-fast；默认时降级到容器内目录 ——
# 不能因为宿主工作区不可写就让 restart 策略把容器拖进无限重启。
if [ "$(id -u)" = "0" ]; then
	echo "  SKIP root 下权限位无效"
else
	stage="$sandbox/ep"
	mkdir -p "$stage"
	cp "$ENTRYPOINT" "$stage/entrypoint.sh"
	# 把镜像内的 SEED 换成可控值；容器内工作区路径用 DSH_WORKSPACE_CONTAINER
	# 环境变量传给 entrypoint（它已支持配置，不再硬编码）。
	sed -i "s#^SEED=/opt/dsh-seed#SEED=/nonexistent-seed#" "$stage/entrypoint.sh"
	mkdir -p "$sandbox/ep-ws"
	chmod 000 "$sandbox/ep-ws"

	# 7a. 严格模式：不可写 → 退出（rc != 0）并给 chown 指引
	set +e
	out="$(DSH_WORKSPACE_CONTAINER="$sandbox/ep-ws" DSH_WORKSPACE_STRICT=1 DSH_HOME="$sandbox/ep-home-a" bash "$stage/entrypoint.sh" 2>&1)"
	rc=$?
	set -e
	if [ "$rc" -ne 0 ]; then
		ok "严格模式在 /workspace 不可写时退出（rc=$rc）"
	else
		bad "严格模式应退出"
	fi
	case "$out" in
	*"不可写"*) ok "输出了「不可写」诊断" ;;
	*) bad "缺少诊断信息：$out" ;;
	esac
	case "$out" in
	*"chown"*) ok "诊断里含 chown 修复提示" ;;
	*) bad "诊断缺少 chown 提示" ;;
	esac

	# 7b. 默认模式：不可写 → 不在这里退出，降级到容器内可写目录后继续
	set +e
	out="$(DSH_WORKSPACE_CONTAINER="$sandbox/ep-ws" DSH_HOME="$sandbox/ep-home-b" bash "$stage/entrypoint.sh" 2>&1)"
	rc=$?
	set -e
	case "$out" in
	*"工作区降级"*) ok "默认模式打印了降级横幅" ;;
	*) bad "默认模式缺少降级横幅：$out" ;;
	esac
	[ -d "$sandbox/ep-home-b/.workspace" ] && ok "降级目录已创建" || bad "降级目录未创建"
	case "$out" in
	*"预置 profile"*) ok "降级后继续走到播种阶段（因测试用 SEED 缺失而停）" ;;
	*) bad "降级后未继续：$out" ;;
	esac
	chmod 755 "$sandbox/ep-ws"
fi

echo "== 8. entrypoint 会补齐持久卷 profile 里缺失的 peer 软链 =="
# 场景：卷里已有旧 profile（package.json + dsh-auth-gate 都在），但缺少
# @deepseek-ai/dsh-storage-domain / cordis 两个 peer 软链。dsh 0.1.7 起会因此
# 禁用 storage-domain 行、web 起不来。entrypoint 必须按当前镜像里的 dsh 位置补齐。
stage="$sandbox/ep3"
mkdir -p "$stage"
cp "$ENTRYPOINT" "$stage/entrypoint.sh"

sed -i "s#^DSH_PKG=/usr/local/lib/node_modules/@deepseek-ai/dsh#DSH_PKG=$sandbox/ep3-pkg#" "$stage/entrypoint.sh"
mkdir -p "$sandbox/ep3-ws"
# 模拟当前镜像里的 dsh 安装
for p in dsh-storage-domain cordis; do
	mkdir -p "$sandbox/ep3-pkg/node_modules/@deepseek-ai/$p"
	: >"$sandbox/ep3-pkg/node_modules/@deepseek-ai/$p/package.json"
done
# 模拟卷内旧 profile：有 package.json 与 dsh-auth-gate，但没有 peer 软链
home="$sandbox/ep3-home"
mkdir -p "$home/profiles/web/node_modules/dsh-auth-gate/lib"
: >"$home/profiles/web/package.json"
: >"$home/profiles/web/node_modules/dsh-auth-gate/lib/cli.js"

set +e
out="$(DSH_WORKSPACE_CONTAINER="$sandbox/ep3-ws" DSH_HOME="$home" bash "$stage/entrypoint.sh" 2>&1)"
rc=$?
set -e
# entrypoint 会在「创建管理员」处因缺 DSH_AUTH_PASSWORD 退出，但 peer 修复应已完成
[ -f "$home/profiles/web/node_modules/@deepseek-ai/dsh-storage-domain/package.json" ] \
	&& ok "补齐了 dsh-storage-domain 软链" || bad "dsh-storage-domain 软链未补齐"
[ -f "$home/profiles/web/node_modules/@deepseek-ai/cordis/package.json" ] \
	&& ok "补齐了 cordis 软链" || bad "cordis 软链未补齐"
case "$out" in
*"补齐 profile peer 依赖"*) ok "日志说明了补齐动作" ;;
*) bad "日志未提补齐：$out" ;;
esac

# 幂等：第二次启动不应再补齐
set +e
out2="$(DSH_WORKSPACE_CONTAINER="$sandbox/ep3-ws" DSH_HOME="$home" bash "$stage/entrypoint.sh" 2>&1)"
set -e
case "$out2" in
*"补齐 profile peer 依赖"*) bad "第二次启动仍在补齐（非幂等）" ;;
*) ok "第二次启动跳过补齐（幂等）" ;;
esac

# 磁盘预检：把阈值抬到不可能满足，应给出明确提示（只告警、不退出）
set +e
out3="$(DSH_WORKSPACE_CONTAINER="$sandbox/ep3-ws" DSH_DISK_MIN_MB=99999999 DSH_HOME="$home" bash "$stage/entrypoint.sh" 2>&1)"
set -e
case "$out3" in
*"阈值"*) ok "磁盘余量不足时给出提示" ;;
*) bad "磁盘检查未触发：$out3" ;;
esac

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
