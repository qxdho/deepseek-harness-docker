#!/usr/bin/env bash
# scripts/doctor.sh 的离线测试。
#
#   ./scripts/test-doctor.sh
#
# 为什么值得测：这个命令的结论会影响用户去改 nginx 还是改容器。分类规则错了，
# 就会把"反代没转发升级头"误判成"代理坏了"，让人白折腾一整晚。
#
# 覆盖：
#   1. doctor_classify 对各状态行的分类（纯函数，边界最多）
#   2. ws_probe_tcp 直连握手：101 / 非升级响应 / 没人监听
#   3. ws_probe_url 经 URL 握手（走 curl）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/test-lib.sh"

[ -f "$HERE/doctor.sh" ] || { echo "缺少 $HERE/doctor.sh"; exit 1; }

# doctor.sh 只用到这几个输出函数
hdr() { :; }
info() { :; }
ok() { :; }
warn() { :; }
die() {
	echo "die: $*" >&2
	exit 1
}
# shellcheck source=scripts/doctor.sh
. "$HERE/doctor.sh"

sandbox="$(mktemp -d "$HERE/.doctor-test.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT

section "1. doctor_classify 分类"
check() { # <期望> <输入说明> <输入>
	local want="$1" label="$2" got
	got="$(doctor_classify "$3")"
	[ "$got" = "$want" ] && pass "$label → $got" || fail "$label：期望 $want，实际 $got（输入：$3）"
}
check upgraded "101" "HTTP/1.1 101 Switching Protocols"
check upgraded "101 带额外头顺序" "HTTP/1.1 101 Web Socket Protocol Handshake"
check http-redirect "302" "HTTP/1.1 302 Found"
check http-ok "200" "HTTP/1.1 200 OK"
check http-denied "401" "HTTP/1.1 401 Unauthorized"
check http-denied "502" "HTTP/1.1 502 Bad Gateway"
check upgrade-stripped "426（升级头被剥掉）" "HTTP/1.1 426 Upgrade Required"
check no-response "空行（连接建不起来/超时）" ""
check unexpected "莫名其妙的内容" "not-http-at-all"
# 关键区分：不带空格的状态行不能被当成 101（比如版本号里恰好含 101 的路径）
check http-denied "410 正文里含 101（只看状态码位置）" "HTTP/1.1 410 Gone (101 bytes)"
check unexpected "非 HTTP 首行" "upstream closed"

section "1b. doctor_index_verdict 判词（两个 401 含义相反）"
check_idx() { # <期望> <说明> <code> <body>
	local want="$1" label="$2" got
	got="$(doctor_index_verdict "$3" "$4")"
	[ "$got" = "$want" ] && pass "$label → $got" || fail "$label：期望 $want，实际 $got（code=$3）"
}
check_idx public "200（可直接访问）" "200" "<html>"
check_idx gate-nav "302（门禁引导登录页）" "302" ""
check_idx gate-api "401 + 门禁自己的 unauthorized（守卫正常）" "401" "unauthorized"
check_idx bridge-down "401 + dsh 自己的文案（桥接失效）" "401" \
	"dsh web authentication required; reopen the URL printed by dsh web."
check_idx unreachable "curl 连不上（000）" "000" ""
check_idx unreachable "空 code" "" ""
check_idx other "其它状态码" "500" "boom"

section "2. ws_probe_tcp 直连握手"
port=$(((RANDOM % 2000) + 21000))
if command -v node >/dev/null 2>&1; then
	cat >"$sandbox/up.js" <<'JS'
const http = require('http');
const port = Number(process.argv[2]);
const mode = process.argv[3];
const s = http.createServer((req, res) => { res.writeHead(302, { location: '/auth/login' }); res.end(); });
s.on('upgrade', (req, socket) => {
  // 探测脚本连上就关是常态，socket 上的错误必须吞掉，否则进程会被未处理的
  // 'error' 事件带走 —— 后面 curl 那一跳就会变成"连不上"，用例假失败。
  socket.on('error', () => {});
  if (mode === 'reject') { socket.end('HTTP/1.1 401 Unauthorized\r\n\r\n'); return; }
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n');
});
s.on('clientError', (err, socket) => socket.destroy());
s.listen(port, '127.0.0.1', () => console.log('ready'));
JS
	node "$sandbox/up.js" "$port" upgrade >"$sandbox/up.log" 2>&1 &
	up_pid=$!
	node "$sandbox/up.js" "$((port + 1))" reject >"$sandbox/rej.log" 2>&1 &
	rej_pid=$!
	trap 'kill "$up_pid" "$rej_pid" 2>/dev/null || true; rm -rf "$sandbox"' EXIT
	# 等服务起来：用被测函数本身重试，别用「连上就断」的探针（会让 stub 收到
	# 突然断开的 socket，在旧 stub 上直接把进程带走）
	got=""
	# 10 秒窗口：CI 上 node 冷启动 + runner 负载可能比本地慢得多（原来 3 秒，
	# 在 CI 上真的等不到 —— 报出来还是"断言失败"，掩盖了真实原因）
	for _ in $(seq 1 100); do
		got="$(ws_probe_tcp 127.0.0.1 "$port" /api/remote.mux)"
		[ -n "$got" ] && break
		sleep 0.1
	done

	if [ -z "$got" ]; then
		# stub 起不来时**必须整体跳过**：之前只 skip 一句就继续往下跑，后面的断言
		# 拿着空值报出三条假失败（CI 上真踩到过）。这里把 stub 的输出打出来，
		# 否则连"为什么起不来"都看不到。
		skip "stub 未就绪，跳过握手用例（端口 ${port}）"
		[ -f "$sandbox/up.log" ] && sed 's/^/    stub: /' "$sandbox/up.log" | head -5
		got=""
	else
		[ "$(doctor_classify "$got")" = "upgraded" ] \
			&& pass "直连能升级：$got" || fail "直连未升级：$got"

		got="$(ws_probe_tcp 127.0.0.1 "$((port + 1))" /api/remote.mux)"
		[ "$(doctor_classify "$got")" = "http-denied" ] \
			&& pass "对端拒绝升级（401）也能读到状态行：$got" || fail "拒绝升级的状态行读错了：$got"

		got="$(ws_probe_tcp 127.0.0.1 "$((port + 2))" /api/remote.mux)"
		[ "$(doctor_classify "$got")" = "no-response" ] \
			&& pass "没人监听 → no-response（不挂死）" || fail "没人监听时结果不对：$got"

		got="$(ws_probe_url "http://127.0.0.1:${port}/api/remote.mux")"
		[ "$(doctor_classify "$got")" = "upgraded" ] \
			&& pass "经 URL（curl）也能升级：$got" || fail "curl 路径未升级：$got"
	fi

	got="$(ws_probe_url "http://127.0.0.1:$((port + 3))/api/remote.mux")"
	[ "$(doctor_classify "$got")" = "no-response" ] \
		&& pass "URL 连不上 → no-response" || fail "URL 连不上时结果不对：$got"

	kill "$up_pid" "$rej_pid" 2>/dev/null || true
	wait "$up_pid" "$rej_pid" 2>/dev/null || true
else
	skip "未安装 node，跳过握手用例"
fi

run_tests
