#!/usr/bin/env bash
# 维护者发布工具 —— **不是给普通用户用的**。
#
# 用户侧只有 `dshm`（部署管理）；发布是维护者动作：普通用户既没有推送权限，也不该
# 关心 tag、release 这些概念。所以它放在 scripts/ 下，与 CI、测试脚本一类，
# 不随 dshm 分发。
#
#   ./scripts/release.sh                自动取当天版本号并发布
#   ./scripts/release.sh 2026.10.01-2   指定版本号发布
#   ./scripts/release.sh --dry-run      只打印将要执行的动作，不做任何改动
#
# 它替我挡住我之前连续犯的三个错（都是手工流程里踩的）：
#   1. 日期写错（写成明天）        —— 自动取当天 UTC 日期
#   2. 同一天重发忘了加序号        —— 检测当天已有 tag，自动提议 -1/-2
#   3. tag 与 VERSION 脱节导致包名对不上 —— 同时写 VERSION 和 tag，并校验一致
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"
. "$here/log.sh"

# 与 CI 校验保持同一套格式：日期，可选 -N 序号（同一天重发时加）
VERSION_RE='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-[0-9]+)?$'

dry=0
want=""
while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run | -n) dry=1 ;;
	-h | --help)
		cat <<EOF

${B}发布 dshm${RST}（维护者用）

  ./scripts/release.sh [版本号] [--dry-run]

  版本号形如 2026.10.01，同一天第二次发布写 2026.10.01-1。
  不指定时自动取当天日期；若当天已发过，自动提议下一个序号。

  做的事：校验 → 写 VERSION → 提交 → 打同名 tag → 推送 → 等 CI 产出 release。

${DIM}为什么 tag 必须等于 v + VERSION：包名、release 下载地址、脚本里写死的版本号
全从这一个号派生。两者脱节会导致 dshm 自更新去请求一个不存在的包（404）。${RST}
EOF
		exit 0
		;;
	-*) die "未知参数：$1（用 --help 看用法）" ;;
	*) [ -z "$want" ] || die "只接受一个版本号"; want="$1" ;;
	esac
	shift
done

# ── 确定版本号 ──────────────────────────────────────────────────────────────
day="$(date -u +%Y.%m.%d)"

# 当天已有的版本号（含序号），用于自动提议下一个
existing_for_day() {
	git tag -l "v${day}*" 2>/dev/null | sed 's/^v//' | grep -E "^${day}(-[0-9]+)?$" || true
}

if [ -z "$want" ]; then
	# 已有 -N 的最大序号 + 1；当天没有任何 tag 就用裸日期。
	# 用 `|| true` 让「当天还没有 tag」时 grep 的非 0 退出码不触发 set -e。
	day_tags="$(existing_for_day | sort | tr '\n' ' ' || true)"
	info "当天已有版本：${day_tags:-（无）}"

	max=0
	has_plain=0
	for v in $day_tags; do
		case "$v" in
		"$day") has_plain=1 ;;
		"$day"-[0-9]*)
			n="${v##*-}"
			[ "$n" -gt "$max" ] 2>/dev/null && max="$n"
			;;
		esac
	done
	if [ "$has_plain" = "1" ] || [ "$max" -gt 0 ]; then
		want="${day}-$((max + 1))"
		info "当天已有发布，自动取下一个序号：${want}"
	else
		want="$day"
	fi
fi

printf '%s' "$want" | grep -qE "$VERSION_RE" \
	|| die "版本号格式不对：${want}
      应为 YYYY.MM.DD，或同一天重发时加序号 YYYY.MM.DD-N（如 2026.10.01-1）"

tag="v${want}"

# ── 预检 ────────────────────────────────────────────────────────────────────
hdr "发布前检查"

command -v git >/dev/null 2>&1 || die "需要 git"
git rev-parse --git-dir >/dev/null 2>&1 || die "当前目录不是 git 仓库"

cur_branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$cur_branch" = "main" ] || die "当前在分支 ${cur_branch} 上，发布必须在 main"
ok "分支 main"

[ -z "$(git status --porcelain)" ] || die "工作区不干净，先提交或 stash 再发布：
$(git status --short | sed 's/^/      /')"
ok "工作区干净"

if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
	die "tag ${tag} 已存在。
      同一天重发请换序号（下一个：${want}-$((0)) 之类），或先确认是不是重复执行。"
fi
ok "tag ${tag} 尚未占用"

info "拉取远端状态…"
git fetch -q origin main
local_head="$(git rev-parse HEAD)"
remote_head="$(git rev-parse origin/main)"
if [ "$local_head" != "$remote_head" ]; then
	die "本地 main 与远端不一致（本地 ${local_head%"${local_head#???????}"}，远端 ${remote_head%"${remote_head#???????}"}）。
      先 git pull 或 git push。"
fi
ok "与远端 main 同步（${local_head%"${local_head#???????}"}）"

# ── 执行 ────────────────────────────────────────────────────────────────────
hdr "将发布 v${want}"

printf '    VERSION 文件：  %s → %s\n' "$(tr -d ' \t\r\n' <VERSION 2>/dev/null || echo '（无）')" "$want"
printf '    tag：           %s\n' "$tag"
printf '    提交信息：      chore(release): %s\n' "$tag"

if [ "$dry" = "1" ]; then
	printf '\n'
	warn "--dry-run：以上动作均未执行"
	exit 0
fi

printf '\n'
printf '%s' "$want" >VERSION
git add VERSION
git commit -q -m "chore(release): ${tag}"
ok "已提交 VERSION=${want}（$(git rev-parse --short HEAD)）"

git tag "$tag"
ok "已打 tag ${tag}"

info "推送 main 与 tag…"
git push -q origin main
git push -q origin "$tag"
ok "已推送"

# ── 等 CI 把 release 建出来 ─────────────────────────────────────────────────
hdr "等待 CI 产出 release"
info "tag ${tag} 的 release 需要 CI 构建面板二进制并打包 dshm"
info "查看进度：https://github.com/qxdho/deepseek-harness-docker/actions"

if ! command -v curl >/dev/null 2>&1; then
	warn "没有 curl，跳过自动等待。请自行确认 CI 结果。"
	exit 0
fi

url="https://github.com/qxdho/deepseek-harness-docker/releases/download/${tag}/dshm-${tag}.tar.gz"
for i in $(seq 1 60); do
	if curl -fsSL -o /dev/null --max-time 20 "$url" 2>/dev/null; then
		printf '\n'
		ok "发布包已就绪：dshm-${tag}.tar.gz"
		info "验证：./dshm dshm list && ./dshm dshm update --to ${want}"
		exit 0
	fi
	printf '\r    等待发布包…（%ds）' "$((i * 15))"
	sleep 15
done

printf '\n'
warn "等了约 15 分钟仍未见到发布包：${url}"
warn "请检查 CI 是否失败（尤其 tag 与 VERSION 一致性校验、发布步骤）"
exit 1
