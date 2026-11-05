#!/usr/bin/env bash
# 从 npm 重新生成 vendor/dsh-auth-gate，并打上本仓库的补丁。
#
#   ./scripts/vendor-gate.sh 0.18.0        # 重新生成
#   ./scripts/vendor-gate.sh --check       # 只校验现有 vendor 与补丁一致
#
# 为什么要有脚本而不是手改：vendor 的是**上游构建产物**（lib/*.js），手改之后没人
# 知道改了哪几行、也没法在下次升级时重放。这里把差异固化成
# vendor/dsh-auth-gate.patch，每次重新拉取后重新应用 —— 补丁打不上就说明上游动了
# 同一段代码，必须人工重看，而不是悄悄漂移。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
vendor="$root/vendor/dsh-auth-gate"
patch_file="$root/vendor/dsh-auth-gate.patch"

usage() { sed -n '2,10p' "$0"; }

# 生成后的目录里必须有这些（少了说明打包内容变了）
verify_layout() {
	local dir="$1" missing=0 f
	for f in package.json cordis.patch.yml lib/index.js lib/host/shared/guard/guard.js lib/cli.js; do
		[ -e "$dir/$f" ] || { echo "缺少 $f" >&2; missing=1; }
	done
	return "$missing"
}

if [ "${1:-}" = "--check" ]; then
	verify_layout "$vendor" || exit 1
	if git -C "$root" apply --check --reverse -p1 --directory=vendor/dsh-auth-gate "$patch_file" 2>/dev/null; then
		echo "vendor 已包含补丁（与 patch 一致）"
		echo "上游版本：$(node -p "require('$vendor/package.json').version")"
		exit 0
	fi
	echo "vendor 与补丁不一致：要么没打补丁，要么被手工改过" >&2
	exit 1
fi

ver="${1:-}"
[ -n "$ver" ] || { usage >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== 拉取 dsh-auth-gate@${ver} =="
(cd "$tmp" && npm pack "dsh-auth-gate@${ver}" --silent >/dev/null && tar xzf ./*.tgz)
verify_layout "$tmp/package" || { echo "上游包结构变了，先看一眼再改脚本" >&2; exit 1; }

rm -rf "$vendor"
cp -a "$tmp/package" "$vendor"
# 只保留运行需要的东西：文档/示例/源码映射不随镜像走，也免得仓库里出现大把无用文件。
rm -rf "$vendor/docs" "$vendor/deploy"
find "$vendor" -name '*.map' -delete

echo "== 应用补丁 =="
if ! git -C "$root" apply -p1 --directory=vendor/dsh-auth-gate "$patch_file"; then
	echo >&2
	echo "补丁打不上 —— 上游很可能改了 guard.js 的同一段代码。" >&2
	echo "请对照 vendor/dsh-auth-gate.patch 手工重看一遍，更新补丁后再跑。" >&2
	echo "（不要用 --reject 硬贴：这是登录边界，宁可停下来看。）" >&2
	exit 1
fi

# 补丁存在的目的就是让门禁认识 resource 路由；打完必须能在代码里看到这两个标记。
grep -q 'unsupported route shape' "$vendor/lib/host/shared/guard/guard.js" ||
	{ echo "补丁应用后找不到预期标记，说明补丁文件本身不对" >&2; exit 1; }

echo
echo "完成。记得："
echo "  1) DSH_AUTH_GATE_VERSION 改成 ${ver}（Dockerfile / docker-compose.yml / .env.example）"
echo "  2) 跑 node vendor/dsh-auth-gate/test/resource-guard.test.mjs"
echo "  3) 打 tag 走 CI 冒烟（arm64 也会跑）"
