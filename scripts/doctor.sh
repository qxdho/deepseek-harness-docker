#!/usr/bin/env bash
# 部署自检用的探针，由 dshm service doctor 调用。
#
# 为什么单独做这个：WebSocket 要穿过「浏览器 → 反向代理 → 本项目代理 → dsh」四段，
# 任何一段没转发 Upgrade/Connection 头，页面照样能打开，只有实时通道（dsh 的
# /api/remote.mux）一直重连。把每一跳单独测一次，才能一眼看出是谁的问题。
#
# 调用方需先定义：hdr / info / ok / warn / die。
# 离线测试：scripts/test-doctor.sh

# 探针路径：代理侧的专用端点，收到升级请求回 101、收到普通 GET 回 426。
# 用它而不是 /api/remote.mux：后者没带会话 Cookie 时必然回 302，无法区分
# 「反代剥掉了升级头」和「链路正常只是没登录」。
DSH_UPGRADE_PROBE_PATH=/__dsh_probe_upgrade

# 握手结果分类：入参是响应首行（可能为空）
#   upgraded          = 101，升级头到达了这一跳
#   upgrade-stripped  = 426，请求到了但升级头被剥掉（反代少配了 Upgrade/Connection）
#   http-ok / 3xx / 4xx / 5xx = 普通 HTTP 响应（探针路径上不该出现，除 426）
#   no-response       = 连接建不起来或没回包（没在听 / 中间设备直接断开）
doctor_classify() {
	case "$1" in
	"") printf '%s' 'no-response' ;;
	# 只看「HTTP/x.y 空格 三位状态码」这个位置，避免把正文里的 101 当成升级成功
	HTTP/*" 101"*) printf '%s' 'upgraded' ;;
	HTTP/*" 426"*) printf '%s' 'upgrade-stripped' ;;
	HTTP/*" "2[0-9][0-9]*) printf '%s' 'http-ok' ;;
	HTTP/*" "3[0-9][0-9]*) printf '%s' 'http-redirect' ;;
	HTTP/*" "[0-9][0-9][0-9]*) printf '%s' 'http-denied' ;;
	*) printf '%s' 'unexpected' ;;
	esac
}

# `GET /` 这一跳的判词。入参：HTTP 状态码、响应正文（前若干字节）。
#
# 为什么不能只看状态码：**两个 401 的含义完全相反**。
#   * dsh-auth-gate 对"非浏览器导航"的未登录请求回 401，正文是它自己的一行 `unauthorized` —— 这是**正常**的（门禁在守卫）；
#   * dsh 自己的会话门回 401，正文是 `dsh web authentication required; …` —— 这表示请求**穿过了**门禁、
#     但没带上 dsh 的 Cookie（登录后的 launch-token 桥接没生效）。
# 只看 401 会把后者当成前者，白白放过线上真实故障。
doctor_index_verdict() { # <code> <body>
	local code="$1" body="$2"
	case "$code" in
	"" | 000) printf '%s' 'unreachable' ;;   # curl 连不上时给的是 000，不是空
	200) printf '%s' 'public' ;;
	30[0-9]) printf '%s' 'gate-nav' ;;
	401)
		case "$body" in
		*dsh\ web\ authentication\ required*) printf '%s' 'bridge-down' ;;
		*) printf '%s' 'gate-api' ;;
		esac
		;;
	*) printf '%s' 'other' ;;
	esac
}

# 直连本机端口的 WS 握手，打印响应首行（拿不到就打印空）
ws_probe_tcp() { # <host> <port> <path>
	local host="$1" port="$2" path="$3" line=""
	# 用 `{ ...; } 2>/dev/null` 而不是给 exec 加 2>/dev/null：连不上时那句
	# "connect: Connection refused" 是 bash 自己打的，只重定向 exec 盖不住。
	if ! { exec 3<>"/dev/tcp/$host/$port"; } 2>/dev/null; then
		printf '%s' ''
		return 0
	fi
	printf 'GET %s HTTP/1.1\r\nHost: %s:%s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n' \
		"$path" "$host" "$port" >&3 2>/dev/null || true
	# 有的服务握手成功后仍会保持连接（甚至是 101 之后马上推送数据），只读首行即可
	IFS= read -r -t 5 line <&3 2>/dev/null || true
	exec 3<&- 3>&- 2>/dev/null || true
	printf '%s' "${line%$'\r'}"
}

# 走公网 URL（http/https）的 WS 握手，打印响应首行。
# curl 遇到 101 会一直挂着等数据，所以限时 6 秒；能拿到 101 就算成功，不看退出码。
ws_probe_url() { # <url>
	local url="$1" out=""
	out="$(curl -s -i -m 6 -o - \
		-H 'Connection: Upgrade' -H 'Upgrade: websocket' \
		-H 'Sec-WebSocket-Version: 13' \
		-H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
		"$url" 2>/dev/null | head -n 1 | tr -d '\r' || true)"
	printf '%s' "$out"
}

# 打印反代的 WebSocket 配置要点（诊断到最后一跳时用）
doctor_proxy_hint() {
	info "反向代理必须转发升级头，否则只有实时通道受影响、页面看起来正常："
	info "  proxy_http_version 1.1;"
	info "  proxy_set_header Upgrade \$http_upgrade;"
	info "  proxy_set_header Connection \$connection_upgrade;   # map \$http_upgrade"
	info "  proxy_read_timeout 3600s;                            # 否则空闲 60s 就被掐断"
	info "1Panel：网站 → 反向代理 → 打开「WebSocket 支持」；宝塔：配置文件里加同样三行"
}
