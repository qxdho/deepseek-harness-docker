#!/usr/bin/env bash
# scripts/update-versions.sh 的离线单测。
#
# 不碰真实仓库（用 DSH_UPDATE_REPO_ROOT 指向临时副本），也不碰真实 npm
# （用 DSH_NPM_REGISTRY 指向本地假 registry）。重点守住三件事：
#   1. --check 不改文件，退出码只在「确实有可自动更新的项」时为 1
#   2. 写入后 Dockerfile / docker-compose.yml / .env.example 三处的值必须一致 ——
#      这是整个脚本最核心的不变量：三处不一致会导致「compose 传给构建的版本」
#      与「Dockerfile 默认值」不同，排查起来很费劲
#   3. 幂等：写完之后再跑不应再改
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/test-lib.sh"

tmp="$(mktemp -d)"
repo="$tmp/repo"
mkdir -p "$repo"
cp "$root/Dockerfile" "$root/docker-compose.yml" "$root/.env.example" "$repo/"

# 假 registry：按包名返回预设的 latest。端口固定但选不常用的，避免与其它测试撞。
port=15977
node -e '
const http = require("node:http");
const port = Number(process.argv[1]);
http.createServer((q, r) => {
  const p = decodeURIComponent(q.url);
  let v = "9.9.9";
  if (p.includes("dsh-auth-gate")) v = "9.8.8";
  if (p.includes("pnpm")) v = "9.7.7";
  r.writeHead(200, { "content-type": "application/json" });
  r.end(JSON.stringify({ "dist-tags": { latest: v } }));
}).listen(port, "127.0.0.1");
' "$port" &
srv=$!
cleanup() { kill "$srv" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
sleep 1

upd() { DSH_UPDATE_REPO_ROOT="$repo" DSH_NPM_REGISTRY="http://127.0.0.1:$port" "$here/update-versions.sh" "$@"; }
pin() { # <Dockerfile 里的 ARG 名>
	awk -F= -v k="ARG $1=" 'index($0,k)==1{print substr($0,length(k)+1)}' "$repo/Dockerfile"
}
compose_val() { # <键名>
	grep -oE "$1: \\\$\{$1:-[^}]*\}" "$repo/docker-compose.yml" | sed 's/.*:-//; s/}//'
}
env_val() { # <键名>
	awk -F= -v k="$1=" 'index($0,k)==1{print substr($0,length(k)+1)}' "$repo/.env.example"
}

echo "== 版本更新脚本 =="

# 起始状态应是仓库当前的钉住值
before_dsh="$(pin DSH_VERSION)"
if [ -n "$before_dsh" ]; then
	pass "能从 Dockerfile 读到当前钉住的 dsh 版本（$before_dsh）"
else
	fail "读不到 Dockerfile 里的 DSH_VERSION（awk 提取逻辑有问题）"
fi

# ── --check 不应改动文件 ──────────────────────────────────────────────────
sum_before="$(cat "$repo/Dockerfile" "$repo/docker-compose.yml" "$repo/.env.example" | sha256sum)"
set +e
upd --check >"$tmp/check.out" 2>&1
rc=$?
set -e
sum_after="$(cat "$repo/Dockerfile" "$repo/docker-compose.yml" "$repo/.env.example" | sha256sum)"
if [ "$sum_before" = "$sum_after" ]; then
	pass "--check 不改动任何文件"
else
	fail "--check 竟然改了文件"
fi
if [ "$rc" = "1" ]; then
	pass "--check 在有可更新项时返回 1（供 CI 判断）"
else
	fail "--check 应返回 1，实际 $rc"
fi
if grep -q "DSH_VERSION" "$tmp/check.out"; then
	pass "--check 列出了 DSH_VERSION"
else
	fail "--check 没有列出 DSH_VERSION：$(cat "$tmp/check.out")"
fi

# ── 写入模式 ──────────────────────────────────────────────────────────────
upd >"$tmp/write.out" 2>&1 || true
d="$(pin DSH_VERSION)"
if [ "$d" = "9.9.9" ]; then
	pass "写入后 Dockerfile 的 DSH_VERSION 变成假 registry 的值"
else
	fail "Dockerfile 未被更新，实际 '${d}'"
fi

# 三处一致 —— 核心不变量
c="$(compose_val DSH_VERSION)"
e="$(env_val DSH_VERSION)"
if [ "$d" = "$c" ] && [ "$d" = "$e" ]; then
	pass "dsh 版本三处一致（Dockerfile=$d compose=$c .env.example=$e）"
else
	fail "dsh 版本三处不一致：Dockerfile=$d compose=$c .env.example=$e"
fi

d2="$(pin DSH_AUTH_GATE_VERSION)"
c2="$(compose_val DSH_AUTH_GATE_VERSION)"
e2="$(env_val DSH_AUTH_GATE_VERSION)"
if [ "$d2" = "9.8.8" ] && [ "$d2" = "$c2" ] && [ "$d2" = "$e2" ]; then
	pass "auth-gate 版本也被更新且三处一致（$d2）"
else
	fail "auth-gate 不一致：Dockerfile=$d2 compose=$c2 .env.example=$e2"
fi

# ── 幂等 ──────────────────────────────────────────────────────────────────
sum2="$(cat "$repo/Dockerfile" "$repo/docker-compose.yml" "$repo/.env.example" | sha256sum)"
upd >"$tmp/again.out" 2>&1 || true
sum3="$(cat "$repo/Dockerfile" "$repo/docker-compose.yml" "$repo/.env.example" | sha256sum)"
if [ "$sum2" = "$sum3" ]; then
	pass "重复执行不再改动（幂等）"
else
	fail "重复执行又改了文件"
fi
case "$(cat "$tmp/again.out")" in
*"没有需要写入的变化"*) pass "重复执行提示无变化" ;;
*) fail "重复执行未提示无变化：$(cat "$tmp/again.out")" ;;
esac

# ── pnpm 有意不自动改，且不应触发 --check 的退出码 1 ──────────────────────
# 此时只剩 pnpm 有新版（假 registry 里 pnpm=9.7.7，而仓库钉的是 11.7.0）。
# 若 --check 仍返回 1，定时任务会因为构建工具的小版本更新反复开空 PR。
set +e
upd --check >"$tmp/pnpm.out" 2>&1
rc2=$?
set -e
if [ "$rc2" = "0" ]; then
	pass "只剩 pnpm 有新版时 --check 返回 0（不会反复开空 PR）"
else
	fail "只剩 pnpm 有新版时 --check 应返回 0，实际 $rc2"
fi
case "$(cat "$tmp/pnpm.out")" in
*"不自动改"*) pass "pnpm 的新版本只提示、不自动改" ;;
*) fail "pnpm 条目缺少「不自动改」提示" ;;
esac
p="$(pin PNPM_VERSION)"
if [ "$p" != "9.7.7" ]; then
	pass "pnpm 版本确实未被改动（仍是 $p）"
else
	fail "pnpm 被自动改了（不应改）"
fi

# ── registry 不可达时必须保留现值，不能写空 ──────────────────────────────
bad_repo="$tmp/bad"
cp -r "$repo" "$bad_repo"
sum_bad_before="$(cat "$bad_repo/Dockerfile" | sha256sum)"
DSH_UPDATE_REPO_ROOT="$bad_repo" DSH_NPM_REGISTRY="http://127.0.0.1:1" \
	"$here/update-versions.sh" >"$tmp/bad.out" 2>&1 || true
sum_bad_after="$(cat "$bad_repo/Dockerfile" | sha256sum)"
if [ "$sum_bad_before" = "$sum_bad_after" ]; then
	pass "registry 不可达时不改动文件（不会写入空版本号）"
else
	fail "registry 不可达时文件被改动"
fi

run_tests
