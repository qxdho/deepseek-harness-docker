#!/usr/bin/env bash
# 终端输出样式的共享实现（颜色 + hdr/info/ok/warn/die 五个函数）。
#
# 为什么抽出来：dshm 与 scripts/release.sh 需要完全一致的输出风格，各写一份必然会
# 慢慢跑偏（改一处颜色、漏另一处）。这里只放**纯输出**函数，不依赖调用方的任何变量，
# 也不产生副作用 —— 任何脚本 source 它都不会有意外的行为。
#
# 用法（注意用 BASH_SOURCE 取本文件所在目录，这样调用方在任意工作目录下都能 source 到）：
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/log.sh"
#
# 注意：dshm 的 ok() 是「打一行绿色 ✓」，与 test-lib.sh 里作为
# pass 别名的 ok() 语义不同。两者互不引用，不要混用。

# 只在交互式终端上色，重定向到文件/管道时输出纯文本（CI 日志更干净）
if [ -t 1 ]; then
	B=$'\033[1m'
	DIM=$'\033[2m'
	GRN=$'\033[32m'
	RED=$'\033[31m'
	YEL=$'\033[33m'
	RST=$'\033[0m'
else
	B=; DIM=; GRN=; RED=; YEL=; RST=
fi

# 小节标题
hdr() { printf '\n%s==> %s%s\n' "$B" "$*" "$RST"; }
# 普通信息（缩进四级，便于看出层级）
info() { printf '    %s\n' "$*"; }
# 成功
ok() { printf '    %s✓%s %s\n' "$GRN" "$RST" "$*"; }
# 警告：不中断
warn() { printf '    %s!%s %s\n' "$YEL" "$RST" "$*"; }
# 致命错误：打印后退出 1
die() { printf '\n%s错误：%s%s\n\n' "$RED" "$*" "$RST" >&2; exit 1; }
