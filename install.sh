#!/usr/bin/env bash
# dshm 引导安装器：只安装 dshm，不启动 dsh-docker 实例。
#
# 本地仓库：./install.sh
# 远程安装：curl -fsSLO .../install.sh && sudo bash install.sh
#
# 远程模式会下载 dshm-<tag>.tar.gz，并强制校验同名 .sha256。
set -euo pipefail

REPO="${DSHM_REPO:-https://github.com/qxdho/deepseek-harness-docker}"
TAG="${DSHM_RELEASE_TAG:-v2026.11.06-1}"

self="${BASH_SOURCE[0]:-}"
here=""
if [ -n "$self" ] && [ -f "$self" ]; then
	here="$(cd "$(dirname "$self")" && pwd)"
fi

tmp=""
cleanup() { [ -n "$tmp" ] && rm -rf "$tmp" || true; }
trap cleanup EXIT

if [ -n "$here" ] && [ -x "$here/dshm" ] && [ -f "$here/templates/compose.yaml" ]; then
	src="$here"
else
	command -v curl >/dev/null 2>&1 || { echo "需要 curl" >&2; exit 1; }
	command -v tar >/dev/null 2>&1 || { echo "需要 tar" >&2; exit 1; }
	command -v sha256sum >/dev/null 2>&1 || { echo "需要 sha256sum" >&2; exit 1; }

	tmp="$(mktemp -d)"
	base="${REPO}/releases/download/${TAG}"
	pkg="dshm-${TAG}.tar.gz"
	echo "下载 ${base}/${pkg}"
	curl -fsSL -o "$tmp/$pkg" "${base}/${pkg}"
	curl -fsSL -o "$tmp/${pkg}.sha256" "${base}/${pkg}.sha256"
	( cd "$tmp" && sha256sum -c "${pkg}.sha256" )
	tar -xzf "$tmp/$pkg" -C "$tmp"
	src="$tmp/dshm-${TAG}"
	[ -x "$src/dshm" ] || { echo "发布包缺少 dshm" >&2; exit 1; }
	[ -f "$src/templates/compose.yaml" ] || { echo "发布包缺少 templates" >&2; exit 1; }
fi

if [ "$(id -u)" = "0" ]; then
	lib="${DSHM_LIB_DIR:-/usr/local/lib/dshm}"
	bin="${DSHM_BIN_DIR:-/usr/local/bin}"
else
	lib="${DSHM_LIB_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/dshm/cli}"
	bin="${DSHM_BIN_DIR:-$HOME/.local/bin}"
fi
mkdir -p "$lib/scripts" "$lib/templates" "$bin"

install -m 0755 "$src/dshm" "$lib/dshm"
[ -f "$src/VERSION" ] && install -m 0644 "$src/VERSION" "$lib/VERSION"
for f in "$src"/scripts/*.sh; do
	case "$(basename "$f")" in
	test-* | smoke-* | test-lib.sh) continue ;;
	esac
	install -m 0755 "$f" "$lib/scripts/"
done
install -m 0644 "$src"/templates/* "$lib/templates/"

ln -sfn "$lib/dshm" "$bin/dshm"

echo "已安装 dshm：$lib/dshm"
echo "命令：$bin/dshm"
case ":$PATH:" in
*":$bin:"*) ;;
*) echo "提示：$bin 不在 PATH 中，请先加入 PATH。" ;;
esac

cat <<'TIP'

下一步二选一：

A. 先初始化，编辑配置，再安装
   sudo dshm docker init --dir /opt/dsh --image ghcr.io/qxdho/deepseek-harness-docker:0.2.2-rc.1-2026.11.06-1
   sudoedit /opt/dsh/.env          # 至少设置 DSH_AUTH_PASSWORD
   sudo dshm docker install --dir /opt/dsh

B. 直接交互式安装（不需要先有配置文件）
   sudo dshm docker install

TIP
