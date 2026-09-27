#!/bin/sh
# dsh 启动 wrapper（安装为 /usr/local/bin/dsh）。
#
# 为什么需要它：`dsh web` 会挂载 cordis HMR 插件，该插件要求 Node 的
# --expose-internals；npm 自动生成的 bin 软链直接 exec `node <bin.js>`，
# 不带这个参数，会以 "HMR service" 报错退出。这里统一补上。
#
# 同时优先使用被 `dsh-update` 自更新到持久化目录的版本。
set -eu

persist_root="${DSH_HOME:-/home/node/.dsh}/npm-global/lib/node_modules"
image_root=/usr/local/lib/node_modules

for root in "$persist_root" "$image_root"; do
	bin="$root/@deepseek-ai/dsh/lib/bin.js"
	if [ -f "$bin" ]; then
		exec node --expose-internals "$bin" "$@"
	fi
done

echo "dsh wrapper: 找不到 @deepseek-ai/dsh（已查找 $persist_root 与 $image_root）" >&2
exit 127
