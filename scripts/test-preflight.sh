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

. "$(dirname "$0")/test-lib.sh"
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
# 注意 DSH_UID 的取值优先来自 .env（与 DSH_WORKSPACE_HOST 一致），所以这里写进 .env
# 而不是 export。不再 export DSH_UID，以便第 6c 节能验证「shell 环境不会意外生效」。
#
# 凡「预期通过」的用例，.env 里必须带上 DSH_UID/DSH_GID=当前 uid：容器 uid 的默认值
# 是 1000，而 GitHub runner 的 uid 是 1001。少了这两行，本地（uid 1000）会通过，
# CI 上却会因为「1000 写不进 1001 的目录」而必然失败 —— 2026-09-28 连续 9 次 CI
# 爆红就是这个原因（见第 6d 节）。
write_env() {
	local project="$1" ws="$2" uid="$3" gid="$4"
	mkdir -p "${project}/dsh-home"
	{
		printf 'DSH_HOME_HOST=%s/dsh-home\n' "$project"
		[ -n "$ws" ] && printf 'DSH_WORKSPACE_HOST=%s\n' "$ws"
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

echo "== 2. 工作区路径：默认值与「失败时也要给出正确路径」=="
# 工作区与数据目录是两条**独立**的绝对路径：未配置时取 preflight 的默认值
# /dsh/workspace，**不**从 DSH_HOME_HOST 派生。
#
# 这里守住一个曾经的 bug：check_host_dir 在「目录可写」的正常路径上会提前
# return 0，调用方若在它之后（或只在成功路径上）才赋值，就会读到上一次调用留下的
# 陈旧路径。这个 bug 只在**失败路径**上暴露，所以下面显式构造一条失败路径。
project="$sandbox/default"
mkdir -p "$project"
write_env "$project" "" "$TEST_UID" "$TEST_GID"
envhome "$project"
set +e
check_workspace "$project" never 0 >/dev/null 2>&1
set -e
if [ "$DSH_WORKSPACE_DIR" != "$sandbox/ok/workspace" ]; then
	ok "工作区路径不是上一用例的陈旧值"
else
	bad "DSH_WORKSPACE_DIR 仍是陈旧值：$DSH_WORKSPACE_DIR"
fi
case "$DSH_WORKSPACE_DIR" in
*/workspace) ok "未配置时取得到工作区路径：$DSH_WORKSPACE_DIR" ;;
"") bad "未配置时 DSH_WORKSPACE_DIR 为空" ;;
*) bad "工作区路径异常：$DSH_WORKSPACE_DIR" ;;
esac

# 失败路径：把工作区指向一个不可写的父目录下，check_workspace 必然报错返回，
# 此时 DSH_WORKSPACE_DIR 仍必须是**本次**解析出的路径。
ro_parent="$sandbox/ro-parent"
mkdir -p "$ro_parent"
chmod 500 "$ro_parent"
project="$sandbox/default-fail"
mkdir -p "$project"
write_env "$project" "$ro_parent/ws" "$TEST_UID" "$TEST_GID"
envhome "$project"
set +e
check_workspace "$project" never 0 >/dev/null 2>&1
fail_rc=$?
set -e
chmod 700 "$ro_parent"
if [ "$fail_rc" -ne 0 ]; then
	ok "不可写的工作区被拦下（rc=$fail_rc）"
else
	# root 下权限位无效，跳过
	echo "  SKIP 当前用户可无视权限位（root？），失败路径未触发"
fi
if [ "$DSH_WORKSPACE_DIR" = "$ro_parent/ws" ]; then
	ok "失败路径上工作区路径也是本次解析值"
else
	bad "失败路径上工作区路径陈旧：期望 $ro_parent/ws，实际 ${DSH_WORKSPACE_DIR:-（空）}"
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

# compose 不展开这些 shell 写法，但预检要按用户「想用的目录」去判断，
# 否则检查的是一个目录、实际挂载的是另一个。这里只验证展开本身。
# 用一个沙箱里的假 HOME：不依赖测试机的家目录是否可写。
fake_home="$sandbox/fakehome"
mkdir -p "$fake_home"
for raw in '$HOME/x' '${HOME}/x'; do
	res="$(HOME="$fake_home" absolute_workspace_path "$sandbox" "$raw")"
	[ "$res" = "$fake_home/x" ] && ok "$raw 展开为 \$HOME/x" || bad "$raw 展开错误：$res"
done

echo "== 3b. .env 里用 \$HOME 写法必须告警，并给出绝对路径 =="
project="$sandbox/homeexpr"
mkdir -p "$project"
write_env "$project" '$HOME/dsh-ws-test' "$TEST_UID" "$TEST_GID"
envhome "$project"
set +e
out="$(HOME="$fake_home" check_workspace "$project" auto 0 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
	ok "展开后判定为可写（rc=0）"
else
	bad "应当可写，实际 rc=$rc：$out"
fi
case "$out" in
*"不会展开"*) ok "提示了 Compose 不展开 \$HOME" ;;
*) bad "缺少「不展开」告警：$out" ;;
esac
case "$out" in
*"$fake_home/dsh-ws-test"*) ok "告警里给出了展开后的绝对路径" ;;
*) bad "告警缺少绝对路径" ;;
esac

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
*"DSH_WORKSPACE_HOST"*) ok "报错里给出了换目录的替代方案" ;;
*) bad "报错缺少替代方案" ;;
esac
# 方案 B 若打印字面量 $HOME，用户照着写进 .env 会被 compose 当成相对路径
case "$out" in
*'$HOME'*) bad "替代方案里出现了未展开的 \$HOME" ;;
*) ok "替代方案里没有未展开的 \$HOME" ;;
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
# 容器 uid 走 .env 设置（与 DSH_WORKSPACE_HOST 一致的取值来源）。
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
# 这里必须显式写上 DSH_UID/DSH_GID：容器 uid 默认 1000，而 runner 的 uid 是 1001，
# 走权限位推断时会得出「不可写」，导致「可写的数据目录应通过」在 CI 上假失败。
homecheck_env=(DSH_HOME_HOST="$project/data" DSH_WORKSPACE_HOST="$project/ws" DSH_UID="$TEST_UID" DSH_GID="$TEST_GID")
printf '%s\n' "${homecheck_env[@]}" >"$project/.env"
if check_dsh_home_dir "$project" auto 0 >/dev/null 2>&1; then
	ok "可写的数据目录通过"
else
	bad "可写的数据目录应通过"
fi

# 不写 DSH_UID 时容器 uid 取默认 1000：只有部署者本人就是 1000 时才可能「可写」，
# 否则必须被拦下。这条断言把上面那个 CI 陷阱显式化 —— 它依赖当前 uid，两条分支都
# 必须成立，不会再出现「本地过、CI 挂」。
printf 'DSH_HOME_HOST=%s/data\nDSH_WORKSPACE=%s/ws\n' "$project" "$project" >"$project/.env"
set +e
out_default="$(check_dsh_home_dir "$project" never 0 2>&1)"
rc_default=$?
set -e
if [ "$TEST_UID" = "1000" ]; then
	[ "$rc_default" -eq 0 ] && ok "默认 DSH_UID=1000 且部署者就是 1000 → 通过" \
		|| bad "应通过，实际 rc=$rc_default"
else
	[ "$rc_default" -ne 0 ] && ok "默认 DSH_UID=1000 ≠ 部署者($TEST_UID) → 被拦下（无假通过）" \
		|| bad "容器 uid 与部署者不一致却判为可写：$out_default"
fi

printf '%s\n' "${homecheck_env[@]}" >"$project/.env"
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


echo "== 6g. uid 不匹配 + 权限 000（perm_for_uid 短 mode 回归）=="
# stat %a 对 000 只输出 "0"；若直接 ${mode: -3} 会得到空串，10#$mode 报算术错误。
project="$sandbox/zero"
mkdir -p "$project/ws"
chmod 000 "$project/ws"
printf 'DSH_WORKSPACE_HOST=%s/ws\nDSH_UID=4242\nDSH_GID=4242\n' "$project" >"$project/.env"
set +e
out="$(check_workspace_dir "$project" never 0 2>&1)"
rc=$?
set -e
chmod 755 "$project/ws"
[ "$rc" -ne 0 ] && ok "不可写被拦下（rc=$rc）" || bad "应被拦下"
case "$out" in
*"invalid integer"*) bad "perm_for_uid 出现算术错误：$out" ;;
*) ok "没有算术错误，给出的是正常诊断" ;;
esac

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

echo "== 8b. entrypoint 收紧过宽的私密文件权限 =="
# credentials 插件要求 .credentials.yaml 不能有 group/other 权限位，否则拒绝启动：
#   credentials-local: /dsh/.credentials.yaml is readable beyond its owner (mode 777)
# 这种文件常来自旧命名卷，或在宿主上被 chmod -R 777 过。
mkdir -p "$home/auth"
printf 'users: []\n' >"$home/auth/users.yaml" # 跳过「创建管理员」，让流程走到权限自检
echo 'token: x' >"$home/.credentials.yaml"
chmod 777 "$home/.credentials.yaml"
echo 'ui: {}' >"$home/settings.yaml"
chmod 640 "$home/settings.yaml"
set +e
out4="$(DSH_WORKSPACE_CONTAINER="$sandbox/ep3-ws" DSH_HOME="$home" bash "$stage/entrypoint.sh" 2>&1)"
set -e
[ "$(stat -c '%a' "$home/.credentials.yaml")" = "600" ] \
	&& ok "777 的 .credentials.yaml 被收紧为 600" \
	|| bad "凭据文件未收紧：$(stat -c '%a' "$home/.credentials.yaml")"
[ "$(stat -c '%a' "$home/settings.yaml")" = "600" ] \
	&& ok "640 的 settings.yaml 被收紧为 600" \
	|| bad "设置文件未收紧：$(stat -c '%a' "$home/settings.yaml")"
case "$out4" in
*"已收紧"*) ok "日志说明了权限收紧" ;;
*) bad "日志未提权限收紧：$out4" ;;
esac

# 幂等：已经是 600 的不再改，也不应再打印收紧日志
set +e
out5="$(DSH_WORKSPACE_CONTAINER="$sandbox/ep3-ws" DSH_HOME="$home" bash "$stage/entrypoint.sh" 2>&1)"
set -e
case "$out5" in
*"已收紧"*) bad "第二次启动仍在收紧（非幂等）" ;;
*) ok "第二次启动跳过收紧（幂等）" ;;
esac
[ "$(stat -c '%a' "$home/.credentials.yaml")" = "600" ] && ok "权限保持 600" || bad "权限被再次改动"

# 属主不对时容器内改不了（不是 root），必须直接给出宿主机命令并退出，
# 而不是放 dsh 去抛一堆 EACCES
chmod 000 "$home/.credentials.yaml"
set +e
out_unreadable="$(DSH_WORKSPACE_CONTAINER="$sandbox/ep3-ws" DSH_HOME="$home" bash "$stage/entrypoint.sh" 2>&1)"
rc_unreadable=$?
set -e
[ "$rc_unreadable" -ne 0 ] && ok "读不了的私密文件 → 直接退出（rc=$rc_unreadable）" \
	|| bad "读不了却继续启动"
case "$out_unreadable" in
*"读不了"*) ok "说明是属主/可读性问题" ;;
*) bad "缺少可读性诊断：$out_unreadable" ;;
esac
case "$out_unreadable" in
*"sudo chown"*) ok "给出了宿主机上的 chown 命令" ;;
*) bad "缺少 chown 指引" ;;
esac
chmod 600 "$home/.credentials.yaml"

# 宿主侧预检：同一组文件在宿主上也必须被收紧（cover 用户在宿主机修复的场景）
echo "== 8c. 宿主预检收紧私密文件权限与属主 =="
pre="$sandbox/preperm"
mkdir -p "$pre/data/auth"
printf 'DSH_HOME_HOST=%s/data\nDSH_WORKSPACE_HOST=%s/data/workspace\nDSH_UID=%s\nDSH_GID=%s\n' \
	"$pre" "$pre" "$TEST_UID" "$TEST_GID" >"$pre/.env"
mkdir -p "$pre/data/workspace"
echo 'token: x' >"$pre/data/.credentials.yaml"
chmod 777 "$pre/data/.credentials.yaml"
printf 'users: []\n' >"$pre/data/auth/users.yaml"
chmod 755 "$pre/data/auth/users.yaml"
echo 'keep' >"$pre/data/notes.txt"
chmod 644 "$pre/data/notes.txt"
set +e
out6="$(check_workspace "$pre" auto 1 2>&1)"
set -e
[ "$(stat -c '%a' "$pre/data/.credentials.yaml")" = "600" ] \
	&& ok "宿主上 777 的凭据文件被收紧为 600" \
	|| bad "宿主凭据文件未收紧：$(stat -c '%a' "$pre/data/.credentials.yaml")"
[ "$(stat -c '%a' "$pre/data/auth/users.yaml")" = "600" ] \
	&& ok "宿主上 755 的用户文件被收紧为 600" \
	|| bad "宿主用户文件未收紧：$(stat -c '%a' "$pre/data/auth/users.yaml")"
[ "$(stat -c '%a' "$pre/data/notes.txt")" = "644" ] \
	&& ok "无关文件不被改动" \
	|| bad "无关文件被改了：$(stat -c '%a' "$pre/data/notes.txt")"
case "$out6" in
*"权限 777 → 600"*) ok "预检说明了权限收紧" ;;
*) bad "预检未提权限问题：$out6" ;;
esac
# 已经是 600 → 不应再报权限问题
set +e
out7="$(check_workspace "$pre" auto 1 2>&1)"
set -e
case "$out7" in
*"权限过宽"*) bad "已收紧的文件仍被报警" ;;
*) ok "已合规的文件不再报警" ;;
esac

# 属主不对（root:root）也要修回容器 uid —— 需要有免密 sudo 才能构造这个场景
if have_sudo && sudo -n true 2>/dev/null; then
	sudo chown 0:0 "$pre/data/.credentials.yaml"
	sudo chown 0:0 "$pre/data/notes.txt"
	set +e
	out8="$(check_workspace "$pre" auto 1 2>&1)"
	set -e
	[ "$(stat -c '%u:%g' "$pre/data/.credentials.yaml")" = "$TEST_UID:$TEST_GID" ] \
		&& ok "root 属主的凭据文件被改回容器 uid" \
		|| bad "属主未修：$(stat -c '%u:%g' "$pre/data/.credentials.yaml")"
	case "$out8" in
	*"属主 0:0 →"*) ok "预检说明了属主修正" ;;
	*) bad "预检未提属主：$out8" ;;
	esac
	# 其它顶层条目属主不对时只提示，不擅自递归 chown
	case "$out8" in
	*"不属于容器 uid"*) ok "提示了数据目录里其它属主不对的条目" ;;
	*) bad "未提示其它属主问题：$out8" ;;
	esac
	[ "$(stat -c '%u' "$pre/data/notes.txt")" = "0" ] \
		&& ok "无关文件不被 chown（只提示不动它）" \
		|| bad "无关文件被改了：$(stat -c '%u' "$pre/data/notes.txt")"
else
	echo "  SKIP 无免密 sudo，跳过属主修复用例"
fi

# 磁盘预检：把阈值抬到不可能满足，应给出明确提示（只告警、不退出）
set +e
out3="$(DSH_WORKSPACE_CONTAINER="$sandbox/ep3-ws" DSH_DISK_MIN_MB=99999999 DSH_HOME="$home" bash "$stage/entrypoint.sh" 2>&1)"
set -e
case "$out3" in
*"阈值"*) ok "磁盘余量不足时给出提示" ;;
*) bad "磁盘检查未触发：$out3" ;;
esac

echo

# ── 9. entrypoint 写插件配置与播种 profile 都不能「先破坏再写」 ──────────────
# 两处都曾直接操作最终路径：
#   * `cat >"$PROFILE/cordis.patch.yml"` 先截断 —— 磁盘写满时留下空/半截的鉴权网关
#     配置（mode: password 丢了），容器进重启循环；
#   * `rm -rf "$PROFILE"` 再 `cp -a` —— cp 失败（磁盘满/被中断）时用户连原有的
#     插件和能跑的 profile 都没了。
# 现在都是「临时文件 + 校验 + 原子换名」。
echo "== 9. entrypoint 的配置写入与播种是原子的 =="
stage9="$sandbox/ep9"
rm -rf "$stage9"
mkdir -p "$stage9"
cp "$ENTRYPOINT" "$stage9/entrypoint.sh"
sed -i "s#^SEED=/opt/dsh-seed#SEED=$sandbox/ep9-seed#" "$stage9/entrypoint.sh"

# 一个最小可用的假 seed（含 auth-gate 的必需文件），以及它的"缺失版"
mk_seed() {
	rm -rf "$1"
	mkdir -p "$1/profiles/web/node_modules/dsh-auth-gate/lib"
	printf '{}\n' >"$1/profiles/web/package.json"
	printf '//x\n' >"$1/profiles/web/node_modules/dsh-auth-gate/lib/cli.js"
}
healthy="$sandbox/ep9-seed"
mk_seed "$healthy"

home9="$sandbox/ep9-home"
mkdir -p "$home9/profiles"
# 预置一份「用户已在用」的 profile：有 package.json（所以不触发播种）与一个用户插件
mkdir -p "$home9/profiles/web"
printf '{}\n' >"$home9/profiles/web/package.json"
mkdir -p "$home9/profiles/web/node_modules/dsh-auth-gate/lib"
printf '//x\n' >"$home9/profiles/web/node_modules/dsh-auth-gate/lib/cli.js"
printf 'user-plugin\n' >"$home9/profiles/web/node_modules/.user-plugin-marker"

# 9a. 正常启动：cordis.patch.yml 应被写出且内容完整
set +e
out9="$(DSH_HOME="$home9" DSH_AUTH_PASSWORD=x DSH_AUTH_USER=admin \
	DSH_PUBLIC_HOST=dsh.example.com timeout 5 bash "$stage9/entrypoint.sh" 2>&1)"
set -e
patch="$home9/profiles/web/cordis.patch.yml"
if [ -f "$patch" ] && grep -q 'mode: password' "$patch" && grep -q 'publicHost: "dsh.example.com"' "$patch"; then
	ok "插件配置被写出且内容完整（含 publicHost）"
else
	bad "插件配置不完整：$(cat "$patch" 2>/dev/null | tr '\n' ' ')"
fi
# 不能留临时文件
left9="$(find "$home9/profiles/web" -maxdepth 1 -name '.cordis.patch.yml.new.*' 2>/dev/null | wc -l)"
if [ "$left9" = "0" ]; then
	ok "配置写入没有残留临时文件"
else
	bad "配置写入残留了 $left9 个临时文件"
fi

# 9b. 非法 publicHost（含双引号）必须被拒绝，而不是生成非法 YAML
set +e
out9b="$(DSH_HOME="$home9" DSH_AUTH_PASSWORD=x DSH_PUBLIC_HOST='evil".example.com' \
	timeout 5 bash "$stage9/entrypoint.sh" 2>&1)"
rc9b=$?
set -e
if [ "$rc9b" -ne 0 ]; then
	ok "含非法字符的 DSH_PUBLIC_HOST 被拒绝（rc=$rc9b）"
else
	bad "非法 DSH_PUBLIC_HOST 未被拒绝"
fi
case "$out9b" in
*"不允许的字符"*) ok "给出了字符集诊断" ;;
*) bad "缺少诊断：$(printf '%s' "$out9b" | tail -1)" ;;
esac
# 关键不变式：**任何一次失败的启动都不能让已有的插件配置变得不完整**。
#
# 旧实现是 `cat >"$PROFILE/cordis.patch.yml"` —— 一旦截断后写失败（磁盘满），
# 留下的是空/半截文件：mode: password 丢了、YAML 也不合法，容器随即进重启循环。
# 只断言"文件还在"太弱，这里逐个字段检查它仍然完整可用。
missing_fields=""
for field in 'mode: password' 'totp:' 'cookieSecure:' 'clientIpHeader:' 'trustedProxyCidrs:' 'publicHost:'; do
	grep -q "$field" "$patch" 2>/dev/null || missing_fields="$missing_fields [$field]"
done
if [ -z "$missing_fields" ]; then
	ok "启动失败后已有插件配置仍完整（6 个字段都在）"
else
	bad "启动失败后插件配置缺字段：$missing_fields（半截文件会让容器起不来）"
fi

# 9c. seed 缺少 auth-gate 时必须放弃替换，且不动已有的 profile
broken="$sandbox/ep9-seed-broken"
rm -rf "$broken"
mkdir -p "$broken/profiles/web"
printf '{}\n' >"$broken/profiles/web/package.json"   # 有 package.json 但没有 auth-gate
home9c="$sandbox/ep9-home-c"
mkdir -p "$home9c/profiles/web"
printf 'user-data\n' >"$home9c/profiles/web/keepme"
sed -i "s#^SEED=.*#SEED=$broken#" "$stage9/entrypoint.sh"
set +e
out9c="$(DSH_HOME="$home9c" DSH_AUTH_PASSWORD=x timeout 5 bash "$stage9/entrypoint.sh" 2>&1)"
rc9c=$?
set -e
if [ "$rc9c" -ne 0 ]; then
	ok "播种出的 profile 缺 auth-gate 时报错退出（rc=$rc9c）"
else
	bad "缺 auth-gate 却没有报错"
fi
if [ -f "$home9c/profiles/web/keepme" ]; then
	ok "播种失败没有动已有的 profile 目录"
else
	bad "播种失败把已有 profile 弄丢了"
fi
left9c="$(find "$home9c/profiles" -maxdepth 1 -name '*.seeding.*' 2>/dev/null | wc -l)"
if [ "$left9c" = "0" ]; then
	ok "播种失败没有残留临时目录"
else
	bad "播种失败残留了 $left9c 个 .seeding 临时目录"
fi

# ── 10. entrypoint 的停止语义与日志保留 ─────────────────────────────────────
# 两个都曾出错：
#   * 收到 SIGTERM（docker stop）时 `wait -n` 返回 143，代码把它当成"dsh 崩溃"并打印
#     日志尾部 —— 每次正常停止都留下一个假的崩溃现场。
#   * 每次启动 `: >"$WEB_LOG"` 截断日志，于是"带着现场重来"永远只能看到本次的输出。
echo "== 10. entrypoint 的停止语义与日志保留 =="
ep="$ENTRYPOINT"
# 10a. SIGTERM 必须走"按要求停止"分支并以 0 退出
if grep -qE '^on_signal\(\) \{' "$ep" && grep -qE '^\s*stopping=1' "$ep" && grep -qE '^\s*exit 0' "$ep"; then
	ok "SIGTERM 有专门的 on_signal：标记 stopping 并以 0 退出"
else
	bad "缺少 on_signal 的停止处理（正常停止会被当成崩溃）"
fi
if grep -qE 'trap on_signal INT TERM' "$ep"; then
	ok "INT/TERM 绑定到 on_signal（而不是直接走 cleanup）"
else
	bad "INT/TERM 没有绑定 on_signal"
fi
if grep -qE '\[ "\$stopping" = "1" \]' "$ep"; then
	ok "退出判定会先检查 stopping，不把正常停止报成崩溃"
else
	bad "退出判定没有区分正常停止"
fi
# 10b. 日志必须是追加，不能截断
if grep -qE '^\s*: >"\$WEB_LOG"$' "$ep"; then
	bad "启动时仍会截断 \$WEB_LOG（上次的崩溃现场会被丢掉）"
else
	ok "启动时不再截断 \$WEB_LOG"
fi
if grep -qE '>>"\$WEB_LOG"' "$ep" && grep -qE 'tail -F -n 0 "\$WEB_LOG"' "$ep"; then
	ok "dsh 输出追加写、tail 只看新增（历史留在文件里）"
else
	bad "日志追加或 tail 偏移写法不对"
fi
# 10c. 真跑一次：两次启动的日志都要留在文件里
home10="$sandbox/ep10-home"
seed10="$sandbox/ep10-seed"
rm -rf "$home10" "$seed10"
mkdir -p "$seed10/profiles/web/node_modules/dsh-auth-gate/lib"
printf '{}\n' >"$seed10/profiles/web/package.json"
printf '//x\n' >"$seed10/profiles/web/node_modules/dsh-auth-gate/lib/cli.js"
stage10="$sandbox/ep10"
rm -rf "$stage10"; mkdir -p "$stage10"
cp "$ep" "$stage10/entrypoint.sh"
sed -i "s#^SEED=.*#SEED=$seed10#" "$stage10/entrypoint.sh"
mkdir -p "$home10/profiles/web/node_modules/dsh-auth-gate/lib"
printf '{}\n' >"$home10/profiles/web/package.json"
printf '//x\n' >"$home10/profiles/web/node_modules/dsh-auth-gate/lib/cli.js"
for round in 1 2; do
	DSH_HOME="$home10" DSH_AUTH_PASSWORD=x DSH_WORKSPACE_STRICT=1 \
		timeout 4 bash "$stage10/entrypoint.sh" >/dev/null 2>&1 || true
done
logfile="$home10/logs/web.log"
# 日志路径可能不同，兜底找一下
[ -f "$logfile" ] || logfile="$(find "$home10" -name 'web.log' 2>/dev/null | head -1)"
if [ -n "$logfile" ] && [ -f "$logfile" ]; then
	nstart="$(grep -c '启动（pid' "$logfile" 2>/dev/null || echo 0)"
	if [ "$nstart" -ge 2 ]; then
		ok "两次启动的日志都留在文件里（找到 $nstart 条启动标记）"
	else
		bad "日志被截断了：只找到 $nstart 条启动标记"
	fi
else
	skip "没找到 web.log，跳过日志保留的行为验证"
fi
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
