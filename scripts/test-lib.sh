#!/usr/bin/env bash
# 测试脚本共用的断言与计数。
#
# 此前每个测试脚本各自抄一份 `ok`/`bad`/`pass`/`fail` 与计数器初始化 —— 6 个文件
# 里同样的三行逐字重复，改一处很容易漏掉另一处。统一到这里。
#
# 用法：
#   . "$(dirname "$0")/test-lib.sh"     # 或 . scripts/test-lib.sh
#   ok "某某通过"
#   bad "某某失败"
#   run_tests                           # 打印小结；返回 0/1，配合退出码使用
#
# 约定：
#   * PASS / FAIL 是本文件维护的全局计数器，调用方不要自己重置；
#   * ok/bad 与 pass/fail 等价，两种命名在现有脚本里都在用，都保留；
#   * 输出统一带两空格缩进与 ANSI 颜色，与本仓库其它命令的输出风格一致。

PASS=0
FAIL=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
ok() { pass "$@"; }
bad() { fail "$@"; }

# 跳过一条（不计入失败，但会在输出里显式可见，避免"静默跳过"被当成功）
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$*"; }

# 小节标题，统一格式
section() { printf '== %s ==\n' "$*"; }

# 打印小结并返回是否全过；脚本末尾应 `run_tests` 后按其返回码退出。
run_tests() {
	printf '\nPASS=%s FAIL=%s\n' "$PASS" "$FAIL"
	[ "$FAIL" = "0" ]
}
