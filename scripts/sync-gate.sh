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
# 他自己的选择，重启不该被镜像悄悄改回去。所以同时看四样东西：
#   1. 标记文件 —— 上次由镜像写进去的版本；卷里版本 != 标记 => 人动过，此后不再碰；
#   2. 内容哈希标记 —— 上次由镜像写进去的门禁内容哈希。**只看版本不够**：本仓库
#      vendor 过 0.18.0（修 dsh 0.2.2 的 resource 路由），版本号与上游一样，若只比
#      版本，存量卷会永远停在未打补丁的 0.18.0 —— 登录页 404、门禁整体失效；
#   3. package.json 的 dependencies —— 用户装过别的插件就不整份重播；
#   4. 版本大小 —— 版本不同时只在镜像严格更新时才动。
# 任一“人动过”的条件命中都只是**提示一句然后放过**，绝不报错、绝不阻断启动。
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

gate_pkg_rel="node_modules/dsh-auth-gate/package.json"
gate_dir_rel="node_modules/dsh-auth-gate"
hash_marker="${marker}.sha256"

# 读 package.json 的某个字段，读不到就输出空（不报错）。
field() { # <file> <js 表达式，变量名 p>
	[ -f "$1" ] || return 0
	node -e 'try{const p=require(process.argv[1]);const v='"$2"';process.stdout.write(v===undefined?"":String(v))}catch(e){}' "$1" 2>/dev/null || true
}

# 门禁目录的内容指纹。只对普通文件内容做哈希（不含 mtime/属主），这样镜像里
# 播种出来的目录与卷里的同一份内容会得到相同结果；vendor 补丁改了 guard.js
# 也会得到不同结果 —— 这正是同版本时区分“上游原版”与“打过补丁的构建”所需要的。
gate_hash() { # <profile 目录> -> sha256；目录不存在或工具失败时返回非 0/空
	local dir="$1/$gate_dir_rel"
	[ -d "$dir" ] || return 1
	(
		cd "$dir" &&
			find . -type f -print0 |
			LC_ALL=C sort -z |
			xargs -0 sha256sum
	) 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}'
}

image_ver="$(field "$seed/$gate_pkg_rel" 'p.version')"
volume_ver="$(field "$profile/$gate_pkg_rel" 'p.version')"

# 两边缺一个就交给 entrypoint 的播种/报错路径处理，这里不做判断。
[ -n "$image_ver" ] && [ -n "$volume_ver" ] || exit 0

image_hash="$(gate_hash "$seed" || true)"
volume_hash="$(gate_hash "$profile" || true)"
hash_ok=1
# 镜像内一定带 coreutils；这里仍然留退化路径：哈希算不出来时退回只看版本，
# 不能让一次异常把容器启动卡住。
if [ -z "$image_hash" ] || [ -z "$volume_hash" ]; then
	hash_ok=0
	say "无法计算登录门禁内容哈希，本次只比较版本（${volume_ver} → ${image_ver}）"
fi

managed_ver="$(cat "$marker" 2>/dev/null || true)"
managed_hash="$(cat "$hash_marker" 2>/dev/null || true)"

# 替换用的临时/备份路径。所有替换都遵循「先备份、再换名、失败回滚」：
# 原实现先 `rm -rf` 再 `mv`，中途失败或被杀会把旧目录和新副本一起丢掉。
tmp=""
backup=""
gate_tmp=""
gate_bak=""
cleanup() {
	# 目录已备份但新目录没落位 => 把备份还回去。
	if [ -n "${gate_bak:-}" ] && [ -d "$gate_bak" ] && [ ! -e "$profile/$gate_dir_rel" ]; then
		mv "$gate_bak" "$profile/$gate_dir_rel" 2>/dev/null || true
	fi
	if [ -n "${backup:-}" ] && [ -d "$backup" ] && [ ! -e "$profile" ]; then
		mv "$backup" "$profile" 2>/dev/null || true
	fi
	[ -n "${gate_tmp:-}" ] && rm -rf "$gate_tmp" 2>/dev/null || true
	[ -n "${tmp:-}" ] && rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

# 内容完全一致：补标记即可（存量卷由旧版本 sync-gate 认领）。
if [ "$hash_ok" = "1" ] && [ "$image_hash" = "$volume_hash" ]; then
	printf '%s\n' "$image_ver" >"$marker" 2>/dev/null || true
	printf '%s\n' "$image_hash" >"$hash_marker" 2>/dev/null || true
	exit 0
fi

# 人动过：内容与上次镜像写入的不一致（优先看内容哈希），或版本与标记不一致。
# 顺序很重要：先看哈希，才能识别“同版本但被手动换成上游原版/别的构建”。
if [ "$hash_ok" = "1" ] && [ -n "$managed_hash" ] && [ "$volume_hash" != "$managed_hash" ]; then
	say "登录门禁内容被手动改过（卷里 ${volume_ver}，镜像 ${image_ver}），保持不动"
	exit 0
fi
if [ -n "$managed_ver" ] && [ "$volume_ver" != "$managed_ver" ]; then
	say "登录门禁是手动安装的（卷里 ${volume_ver}，镜像 ${image_ver}），保持不动"
	exit 0
fi

# 版本相同但内容不同：这是 vendor 补丁的升级路径（0.18.0 的上游原版
# vs 本仓库打过 resource 路由补丁的 0.18.0）。**只替换门禁目录**，不动 profile 的
# 其它内容 —— 这样即使卷里装过别的插件，也不会被整份重播冲掉。
if [ "$image_ver" = "$volume_ver" ]; then
	if [ "$hash_ok" != "1" ] || [ "$image_hash" = "$volume_hash" ]; then
		# 内容相同或无法计算哈希：无需替换，补标记即可。
		printf '%s\n' "$image_ver" >"$marker" 2>/dev/null || true
		[ "$hash_ok" = "1" ] && printf '%s\n' "$image_hash" >"$hash_marker" 2>/dev/null || true
		exit 0
	fi

	gate_tmp="${profile}/node_modules/.dsh-auth-gate.gate-sync.$$"
	gate_bak="${profile}/node_modules/.dsh-auth-gate.gate-bak.$$"
	rm -rf "$gate_tmp" "$gate_bak"
	if ! cp -a "$seed/$gate_dir_rel" "$gate_tmp"; then
		say "同步登录门禁失败（复制失败），继续用卷里的 ${volume_ver}"
		exit 0
	fi
	if [ ! -f "$gate_tmp/package.json" ]; then
		say "同步登录门禁失败（镜像里缺 ${gate_dir_rel}/package.json），继续用卷里的 ${volume_ver}"
		exit 0
	fi
	if ! mv "$profile/$gate_dir_rel" "$gate_bak"; then
		say "同步登录门禁失败（无法备份原门禁目录），继续用卷里的 ${volume_ver}"
		exit 0
	fi
	if ! mv "$gate_tmp" "$profile/$gate_dir_rel"; then
		if mv "$gate_bak" "$profile/$gate_dir_rel" 2>/dev/null; then
			say "同步登录门禁失败（替换目录失败），已恢复原门禁（${volume_ver}）"
		else
			say "同步登录门禁失败（替换目录失败），且原门禁恢复失败；备份在 ${gate_bak}"
		fi
		exit 0
	fi
	gate_tmp=""
	rm -rf "$gate_bak" 2>/dev/null || true
	gate_bak=""
	printf '%s\n' "$image_ver" >"$marker" 2>/dev/null || true
	printf '%s\n' "$image_hash" >"$hash_marker" 2>/dev/null || true
	say "登录门禁同版本内容更新（版本 ${image_ver}，仅替换门禁目录，其他插件保留）"
	exit 0
fi

# ── 以下只处理版本不同的情况 ──────────────────────────────────────────────

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
if node -e '
	const parse = (v) => { const i = v.indexOf("-"); const core = (i < 0 ? v : v.slice(0, i)).split(".").map(Number); return { core, pre: i < 0 ? null : v.slice(i + 1).split(".") }; };
	const a = parse(process.argv[1]); const b = parse(process.argv[2]);
	for (let i = 0; i < 3; i += 1) { if ((a.core[i]||0) !== (b.core[i]||0)) process.exit((a.core[i]||0) > (b.core[i]||0) ? 0 : 1); }
	if (a.pre === null || b.pre === null) process.exit(a.pre === null ? (b.pre === null ? 1 : 0) : 1);
	for (let i = 0; i < Math.max(a.pre.length, b.pre.length); i += 1) {
		if (i >= a.pre.length) process.exit(1);
		if (i >= b.pre.length) process.exit(0);
		const x = a.pre[i], y = b.pre[i], nx = /^\d+$/.test(x), ny = /^\d+$/.test(y);
		if (nx && ny) { if (Number(x) !== Number(y)) process.exit(Number(x) > Number(y) ? 0 : 1); }
		else if (nx !== ny) { process.exit(nx ? 1 : 0); }
		else if (x !== y) { process.exit(x > y ? 0 : 1); }
	}
	process.exit(1);
' "$image_ver" "$volume_ver" 2>/dev/null; then
	:
else
	say "卷里的登录门禁（${volume_ver}）比镜像（${image_ver}）新，保持不动"
	exit 0
fi

# 先拷到旁边、校验、再把旧 profile 改名备份、新目录换名到位；任一步失败都回滚。
# 原来的 `rm -rf "$profile"` 在 `mv` 失败或进程中途被杀时会同时丢掉原目录和副本，
# 与“原 profile 不受影响”的注释不符。
tmp="${profile}.gate-sync.$$"
backup="${profile}.gate-backup.$$"
rm -rf "$tmp" "$backup"
if ! cp -a "$seed" "$tmp"; then
	say "同步登录门禁失败（复制失败），继续用卷里的 ${volume_ver}"
	exit 0
fi
if [ ! -f "$tmp/$gate_pkg_rel" ]; then
	say "同步登录门禁失败（镜像里缺 ${gate_pkg_rel}），继续用卷里的 ${volume_ver}"
	exit 0
fi
if [ ! -e "$profile" ] || ! mv "$profile" "$backup"; then
	say "同步登录门禁失败（无法备份原 profile），继续用卷里的 ${volume_ver}"
	exit 0
fi
if ! mv "$tmp" "$profile"; then
	# 回滚：把原 profile 放回去，避免卷里只剩临时目录。
	if mv "$backup" "$profile" 2>/dev/null; then
		say "同步登录门禁失败（替换目录失败），已恢复原 profile（${volume_ver}）"
	else
		say "同步登录门禁失败（替换目录失败），且原 profile 恢复失败；备份在 ${backup}"
	fi
	exit 0
fi
tmp=""
rm -rf "$backup" 2>/dev/null || true
backup=""
printf '%s\n' "$image_ver" >"$marker" 2>/dev/null || true
[ "$hash_ok" = "1" ] && printf '%s\n' "$image_hash" >"$hash_marker" 2>/dev/null || true
if [ "$hash_ok" = "1" ]; then
	say "登录门禁版本更新：${volume_ver} 更新到 ${image_ver}（内容 ${volume_hash%"${volume_hash#???????}"}… → ${image_hash%"${image_hash#???????}"}…）"
else
	say "登录门禁版本更新：${volume_ver} 更新到 ${image_ver}"
fi
exit 0
