#!/usr/bin/env bash
# 部署自检用的探针，由 dshm service doctor 调用。
#
# 为什么单独做这个：WebSocket 要穿过「浏览器 → 反向代理 → 本项目代理 → dsh」四段，
# 任何一段没转发 Upgrade/Connection 头，页面照样能打开，只有实时通道（dsh 的
# /api/remote.mux）一直重连。把每一跳单独测一次，才能一眼看出是谁的问题。
#
# 调用方需先定义：hdr / info / ok / warn / die。
# 离线测试：scripts/test-doctor.sh

# 握手结果分类：入参是响应首行（可能为空）
#   upgraded      = 101，链路通
#   http-ok       = 2xx（有些服务对未认证的升级请求直接回普通响应）
#   http-redirect = 3xx（同上的常见形态，说明代理转发是通的）
#   http-denied   = 4xx/5xx
#   no-response   = 连接建不起来或超时没回包（代理没在听 / 上游挂了）
doctor_classify() {
	case "$1" in
	"") printf '%s' 'no-response' ;;
	# 只看「HTTP/x.y 空格 三位状态码」这个位置，避免把正文里的 101 当成升级成功
	HTTP/*" 101"*) printf '%s' 'upgraded' ;;
	HTTP/*" "2[0-9][0-9]*) printf '%s' 'http-ok' ;;
	HTTP/*" "3[0-9][0-9]*) printf '%s' 'http-redirect' ;;
	HTTP/*" "[0-9][0-9][0-9]*) printf '%s' 'http-denied' ;;
	*) printf '%s' 'unexpected' ;;
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
