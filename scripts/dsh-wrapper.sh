#!/bin/sh
# dsh 启动 wrapper（安装为 /usr/local/bin/dsh）。
#
# 为什么需要它：`dsh web` 会挂载 cordis HMR 插件，该插件要求 Node 的
# --expose-internals；npm 自动生成的 bin 软链直接 exec `node <bin.js>`，
# 不带这个参数，会以 "HMR service" 报错退出。这里统一补上。
set -eu

exec node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"
