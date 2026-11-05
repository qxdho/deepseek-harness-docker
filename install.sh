#!/usr/bin/env bash
# dshm 引导安装器：只安装 dshm，不替你启动实例。
#
#   ./install.sh
#
# 之后二选一：
#   A. dshm docker init ...   # 生成配置 -> 编辑 .env -> dshm docker install
#   B. dshm docker install    # 交互式，直接生成并启动
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
*) echo "提示：$bin 不在 PATH 中，请先加入 PATH。" ;;
esac

cat <<'TIP'

下一步二选一：

A. 先初始化，编辑配置，再安装
   sudo dshm docker init --dir /opt/dsh --image ghcr.io/qxdho/deepseek-harness-docker:latest
   sudoedit /opt/dsh/.env          # 至少设置 DSH_AUTH_PASSWORD
   sudo dshm docker install --dir /opt/dsh

B. 直接交互式安装（不需要先有配置文件）
   sudo dshm docker install

TIP
