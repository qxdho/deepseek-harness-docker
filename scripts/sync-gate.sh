#!/usr/bin/env bash
# 让持久卷里的登录门禁跟上镜像版本。
#
#   sync-gate.sh <镜像内 profile 目录> <卷里的 profile 目录> <标记文件>
#
# 为什么需要：entrypoint 只在「卷里没有 package.json」时播种 profile（见 entrypoint.sh
# "播种 profile" 一节）。于是升级镜像时 dsh 换了、**门禁却还停在第一次播种的版本**；
# 而 entrypoint 每次启动又都会把 peer 软链指向新镜像的 cordis —— 旧插件配新框架，
# 正是 0.2.2-rc.1 那次「插件 apply 抛错、门禁整体消失、容器却 healthy」的成因。
#
# 为什么不能简单「镜像更旧就覆盖」：用户可能在容器里用插件面板升/降过门禁，那是
# 他自己的选择，重启不该被镜像悄悄改回去。所以同时看三样东西：
#   1. 标记文件 —— 上次由镜像写进去的版本；卷里版本 != 标记 => 人动过，此后不再碰；
#   2. package.json 的 dependencies —— 用户装过别的插件就不整份重播；
#   3. 版本大小 —— 只在镜像严格更新时才动。
# 任一条件不满足都只是**提示一句然后放过**，绝不报错、绝不阻断启动。
#
# DSH_GATE_SYNC=off 可彻底关掉自动同步（改由用户自己管）。
set -euo pipefail

seed="${1:-}"
profile="${2:-}"
marker="${3:-}"

say() { printf '[entrypoint] %s\n' "$*" >&2; }

[ -n "$seed" ] && [ -n "$profile" ] && [ -n "$marker" ] || {
	echo "用法: sync-gate.sh <镜像内 profile> <卷里的 profile> <标记文件>" >&2
	exit 2
}

[ "${DSH_GATE_SYNC:-auto}" = "off" ] && exit 0

gate_rel="node_modules/dsh-auth-gate/package.json"

# 读 package.json 的某个字段，读不到就输出空（不报错）。
field() { # <file> <js 表达式，变量名 p>
	[ -f "$1" ] || return 0
	node -e 'try{const p=require(process.argv[1]);const v='"$2"';process.stdout.write(v===undefined?"":String(v))}catch(e){}' "$1" 2>/dev/null || true
}

image_ver="$(field "$seed/$gate_rel" 'p.version')"
volume_ver="$(field "$profile/$gate_rel" 'p.version')"

# 两边缺一个就交给 entrypoint 的播种/报错路径处理，这里不做判断。
[ -n "$image_ver" ] && [ -n "$volume_ver" ] || exit 0

if [ "$image_ver" = "$volume_ver" ]; then
	# 版本一致：如果还没有标记，补一个（把存量卷认领成"镜像管理"）。
	if [ ! -f "$marker" ]; then
		printf '%s\n' "$image_ver" >"$marker" 2>/dev/null || true
	fi
	exit 0
fi

# 人动过（版本和上次镜像写下的不一致）=> 从此归用户管。
if [ -f "$marker" ]; then
	managed="$(cat "$marker" 2>/dev/null || true)"
	if [ -n "$managed" ] && [ "$volume_ver" != "$managed" ]; then
		say "登录门禁是手动安装的（卷里 ${volume_ver}，镜像 ${image_ver}），保持不动"
		exit 0
	fi
fi

# 装过别的插件 => 不整份重播，避免把用户的东西冲掉。
#
# 注意：**不能把 dsh-auth-gate 自己算进比较** —— 两边版本不同时这条依赖必然不同，
# 那样每个"该同步"的场景都会被误判成"装过额外插件"（第一版就是这么写的，4 条用例
# 直接红）。排序后再比，避免键顺序造成假差异。
deps_expr='JSON.stringify(Object.fromEntries(Object.entries(p.dependencies||{}).filter(([k])=>k!=="dsh-auth-gate").sort()))'
image_deps="$(field "$seed/package.json" "$deps_expr")"
volume_deps="$(field "$profile/package.json" "$deps_expr")"
if [ -n "$image_deps" ] && [ -n "$volume_deps" ] && [ "$image_deps" != "$volume_deps" ]; then
	say "profile 里装过额外插件，跳过门禁自动同步（当前 ${volume_ver}，镜像 ${image_ver}）"
	exit 0
fi

# 只有镜像**严格更新**才替换；卷里版本更新（用户升过）就保持。
if ! node -e '
	const parse = (v) => { const i = v.indexOf("-"); const core = (i < 0 ? v : v.slice(0, i)).split(".").map(Number); return { core, pre: i < 0 ? null : v.slice(i + 1).split(".") }; };
	const a = parse(process.argv[1]); const b = parse(process.argv[2]);
	for (let i = 0; i < 3; i += 1) { if ((a.core[i]||0) !== (b.core[i]||0)) process.exit((a.core[i]||0) > (b.core[i]||0) ? 0 : 1); }
	if (a.pre === null || b.pre === null) process.exit(a.pre === null ? (b.pre === null ? 1 : 0) : 1);
	for (let i = 0; i < Math.max(a.pre.length, b.pre.length); i += 1) {
		if (i >= a.pre.length) process.exit(1);
		if (i >= b.pre.length) process.exit(0);
		const x = a.pre[i], y = b.pre[i], nx = /^\d+$/.test(x), ny = /^\d+$/.test(y);
		if (nx && ny) { if (Number(x) !== Number(y)) process.exit(Number(x) > Number(y) ? 0 : 1); }
		else if (nx !== ny) process.exit(nx ? 1 : 0);
		else if (x !== y) process.exit(x > y ? 0 : 1);
	}
	process.exit(1);
' "$image_ver" "$volume_ver" 2>/dev/null; then
	say "卷里的登录门禁（${volume_ver}）比镜像（${image_ver}）新，保持不动"
	exit 0
fi

# 原子重播：先拷到旁边、校验、再换名。中途失败只丢临时目录，原 profile 不受影响。
tmp="${profile}.gate-sync.$$"
rm -rf "$tmp"
if ! cp -a "$seed" "$tmp"; then
	rm -rf "$tmp"
	say "同步登录门禁失败（复制失败），继续用卷里的 ${volume_ver}"
	exit 0
fi
if [ ! -f "$tmp/$gate_rel" ]; then
	rm -rf "$tmp"
	say "同步登录门禁失败（镜像里缺 ${gate_rel}），继续用卷里的 ${volume_ver}"
	exit 0
fi
if ! rm -rf "$profile" || ! mv "$tmp" "$profile"; then
	rm -rf "$tmp"
	say "同步登录门禁失败（替换目录失败），继续用卷里的 ${volume_ver}"
	exit 0
fi
printf '%s\n' "$image_ver" >"$marker" 2>/dev/null || true
say "登录门禁已从 ${volume_ver} 更新到 ${image_ver}"
exit 0
