#!/usr/bin/env bash
# scripts/sync-gate.sh 的离线单测。
#
# 重点守住「人动过就别碰」这条：升级镜像要能把登录门禁带到新版本，但用户在容器里
# 自己升/降过的版本、或装过别的插件的 profile，都**不能**被启动流程悄悄覆盖。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/test-lib.sh"

script="$here/sync-gate.sh"
[ -x "$script" ] || {
	fail "sync-gate.sh 不存在或没有可执行位"
	run_tests
	exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 造一份 profile：<dir>/package.json + node_modules/dsh-auth-gate/package.json
make_profile() { # <dir> <gate 版本> [额外依赖名]
	local dir="$1" ver="$2" extra="${3:-}"
	mkdir -p "$dir/node_modules/dsh-auth-gate"
	printf '{"version":"%s"}\n' "$ver" >"$dir/node_modules/dsh-auth-gate/package.json"
	if [ -n "$extra" ]; then
		printf '{"dependencies":{"dsh-auth-gate":"%s","%s":"1.0.0"}}\n' "$ver" "$extra" >"$dir/package.json"
	else
		printf '{"dependencies":{"dsh-auth-gate":"%s"}}\n' "$ver" >"$dir/package.json"
	fi
}

# 每个用例一套独立的 seed / profile / marker
setup() { # <名字> <镜像版本> <卷版本> [额外依赖]
	local name="$1" iv="$2" pv="$3" extra="${4:-}"
	root="$tmp/$name"
	mkdir -p "$root"
	make_profile "$root/seed" "$iv"
	make_profile "$root/profile" "$pv" "$extra"
	marker="$root/marker"
}

vol_ver() { node -e 'process.stdout.write(require(process.argv[1]).version)' "$1/profile/node_modules/dsh-auth-gate/package.json"; }
has_extra() { grep -q "extra-plugin" "$1/profile/package.json"; }

run_sync() { # [env...] -> 输出
	"$script" "$root/seed" "$root/profile" "$marker" 2>&1
}

section "sync-gate.sh"

# 1. 版本相同：什么都不做
setup same 0.18.0 0.18.0
out="$(run_sync)"
if [ "$(vol_ver "$root")" = "0.18.0" ]; then pass "版本相同：不改动"; else fail "版本相同却被改动"; fi
if [ -f "$marker" ]; then pass "版本相同：补写了管理标记"; else fail "版本相同：没写标记（存量卷无法认领）"; fi

# 1b. **版本相同、内容不同**：本仓库 vendor 过 0.18.0，版本号与上游相同。
# 只比版本会让存量卷永远停在未打补丁的构建上（登录页 404），必须按内容哈希同步。
setup samepatch 0.18.0 0.18.0
mkdir -p "$root/seed/node_modules/dsh-auth-gate/lib" "$root/profile/node_modules/dsh-auth-gate/lib"
printf 'patched\n' >"$root/seed/node_modules/dsh-auth-gate/lib/build-stamp"
printf 'upstream\n' >"$root/profile/node_modules/dsh-auth-gate/lib/build-stamp"
out="$(run_sync)"
if [ "$(cat "$root/profile/node_modules/dsh-auth-gate/lib/build-stamp")" = "patched" ]; then
	pass "同版本内容更新：vendor 补丁被同步进卷"
else
	fail "同版本内容更新：仍是 $(cat "$root/profile/node_modules/dsh-auth-gate/lib/build-stamp")"
fi
case "$out" in *"同版本内容更新"*) pass "同版本内容更新：输出说明了结果" ;; *) fail "同版本内容更新：没有提示：$out" ;; esac
if [ -s "$marker.sha256" ]; then pass "同版本内容更新：写入了内容哈希标记"; else fail "同版本内容更新：没有内容哈希标记"; fi

# 1b-2. 同版本内容更新 + 装过额外插件：只替换门禁目录，别冲掉别的插件
setup samepatch-extra 0.18.0 0.18.0 extra-plugin
mkdir -p "$root/seed/node_modules/dsh-auth-gate/lib" "$root/profile/node_modules/dsh-auth-gate/lib"
printf 'patched\n' >"$root/seed/node_modules/dsh-auth-gate/lib/build-stamp"
printf 'upstream\n' >"$root/profile/node_modules/dsh-auth-gate/lib/build-stamp"
out="$(run_sync)"
if [ "$(cat "$root/profile/node_modules/dsh-auth-gate/lib/build-stamp")" = "patched" ]; then
	pass "同版本内容更新 + 额外插件：门禁被同步"
else
	fail "同版本内容更新 + 额外插件：门禁没同步"
fi
if has_extra "$root"; then pass "同版本内容更新 + 额外插件：额外插件仍保留"; else fail "同版本内容更新 + 额外插件：额外插件被冲掉"; fi

# 1c. 版本相同、但用户手动改过内容（与上次镜像写入的哈希不一致）=> 保持不动
setup samemanual 0.18.0 0.18.0
mkdir -p "$root/seed/node_modules/dsh-auth-gate/lib" "$root/profile/node_modules/dsh-auth-gate/lib"
run_sync >/dev/null
printf 'user-edit\n' >"$root/profile/node_modules/dsh-auth-gate/lib/user-stamp"
out="$(run_sync)"
if [ -f "$root/profile/node_modules/dsh-auth-gate/lib/user-stamp" ]; then
	pass "同版本手动改动：保持用户内容"
else
	fail "同版本手动改动：用户内容被镜像覆盖"
fi
case "$out" in *"手动改过"*) pass "同版本手动改动：给出了提示" ;; *) fail "同版本手动改动：没有提示：$out" ;; esac

# 2. 镜像更新、没装额外插件、旧镜像没留标记（存量卷升级的典型场景）
setup upgrade 0.18.0 0.17.4
out="$(run_sync)"
if [ "$(vol_ver "$root")" = "0.18.0" ]; then pass "镜像更新：门禁被带到 0.18.0"; else fail "镜像更新：门禁仍是 $(vol_ver "$root")"; fi
case "$out" in *"更新到"*) pass "镜像更新：输出里说明了结果" ;; *) fail "镜像更新：没有输出结果：$out" ;; esac
if [ "$(cat "$marker")" = "0.18.0" ]; then pass "镜像更新：标记写成新版本"; else fail "镜像更新：标记不对（$(cat "$marker" 2>/dev/null)）"; fi

# 3. 有标记且卷里就是标记版本（上次由镜像写入）=> 可以继续同步
setup managed 0.18.0 0.17.4
printf '0.17.4\n' >"$marker"
out="$(run_sync)"
if [ "$(vol_ver "$root")" = "0.18.0" ]; then pass "标记与卷一致：照常同步"; else fail "标记与卷一致却没同步"; fi

# 4. 人在容器里动过（卷版本 != 标记）=> 不动
setup manual 0.18.0 0.17.9
printf '0.17.4\n' >"$marker"
out="$(run_sync)"
if [ "$(vol_ver "$root")" = "0.17.9" ]; then pass "手动升级过：保持不动"; else fail "手动升级过却被改回 $(vol_ver "$root")"; fi
case "$out" in *"手动安装"*) pass "手动升级过：给出了提示" ;; *) fail "手动升级过：没有提示：$out" ;; esac

# 5. 装过别的插件 => 不整份重播（别把用户的东西冲掉）
setup extras 0.18.0 0.17.4 extra-plugin
out="$(run_sync)"
if [ "$(vol_ver "$root")" = "0.17.4" ]; then pass "装过额外插件：跳过同步"; else fail "装过额外插件却被覆盖"; fi
if has_extra "$root"; then pass "装过额外插件：插件仍在"; else fail "装过额外插件：被冲掉了"; fi
case "$out" in *"额外插件"*) pass "装过额外插件：给出了提示" ;; *) fail "装过额外插件：没有提示：$out" ;; esac

# 6. 卷里版本更新（用户在面板里升过，且标记没跟上）=> 保持
setup newer 0.18.0 0.19.0
out="$(run_sync)"
if [ "$(vol_ver "$root")" = "0.19.0" ]; then pass "卷里更新：不回退"; else fail "卷里更新却被降级到 $(vol_ver "$root")"; fi

# 7. DSH_GATE_SYNC=off 彻底关掉
setup off 0.18.0 0.17.4
out="$(DSH_GATE_SYNC=off "$script" "$root/seed" "$root/profile" "$marker" 2>&1)"
if [ "$(vol_ver "$root")" = "0.17.4" ]; then pass "DSH_GATE_SYNC=off：不动"; else fail "DSH_GATE_SYNC=off 时仍被改"; fi

# 8. 镜像里没有门禁（理论上不会发生）=> 老实放过，不报错
setup nogate 0.18.0 0.17.4
rm -rf "$root/seed/node_modules/dsh-auth-gate"
out="$(run_sync)"; rc=$?
if [ "$rc" = "0" ] && [ "$(vol_ver "$root")" = "0.17.4" ]; then
	pass "镜像里缺门禁：返回 0 且不动"
else
	fail "镜像里缺门禁时行为异常（rc=$rc）"
fi

# 9. 替换是原子的：过程失败也不该留下半成品目录
setup atomic 0.18.0 0.17.4
run_sync >/dev/null
leftover="$(find "$root" -maxdepth 1 -name 'profile.gate-sync.*' | wc -l)"
if [ "$leftover" = "0" ]; then pass "替换后没有残留临时目录"; else fail "留下了临时目录：$(find "$root" -maxdepth 1 -name 'profile.gate-sync.*')"; fi

run_tests
