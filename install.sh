#!/usr/bin/env bash
# dshm 引导安装器。
#
#   ./install.sh                安装 dshm，然后运行 dshm docker install
#   ./install.sh --install-only 只安装 dshm
#
# 当前从本仓库引导；发布后可以换成从 release 下载的 install.sh。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
[ -x "$here/dshm" ] || {
	echo "错误：找不到 $here/dshm" >&2
	exit 1
}
[ -f "$here/templates/compose.yaml" ] || {
	echo "错误：找不到 templates/compose.yaml" >&2
	exit 1
}

only=0
args=()
for a in "$@"; do
	case "$a" in
	--install-only) only=1 ;;
	*) args+=("$a") ;;
	esac
done

if [ "$(id -u)" = "0" ]; then
	lib="${DSHM_LIB_DIR:-/usr/local/lib/dshm}"
	bin="${DSHM_BIN_DIR:-/usr/local/bin}"
else
	lib="${DSHM_LIB_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/dshm/cli}"
	bin="${DSHM_BIN_DIR:-$HOME/.local/bin}"
fi
mkdir -p "$lib/scripts" "$lib/templates" "$bin"

install -m 0755 "$here/dshm" "$lib/dshm"
[ -f "$here/VERSION" ] && install -m 0644 "$here/VERSION" "$lib/VERSION"
for f in "$here"/scripts/*.sh; do
	case "$(basename "$f")" in
	test-* | smoke-* | test-lib.sh) continue ;;
	esac
	install -m 0755 "$f" "$lib/scripts/"
done
install -m 0644 "$here"/templates/* "$lib/templates/"

ln -sfn "$lib/dshm" "$bin/dshm"

echo "已安装 dshm：$lib/dshm"
echo "命令：$bin/dshm"
case ":$PATH:" in
*":$bin:"*) ;;
*)
	echo "提示：$bin 不在 PATH 中，请把它加入 PATH。"
	;;
esac

if [ "$only" = "1" ]; then
	exit 0
fi

echo
exec "$lib/dshm" docker install "${args[@]}"
