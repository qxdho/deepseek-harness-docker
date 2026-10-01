#!/usr/bin/env bash
# 容器健康检查：登录页可访问即视为健康。
# 未登录访问 / 会 302 到 /auth/login；/auth/login 本身应返回 200。
set -euo pipefail
PORT="${PROXY_PORT:-3080}"

code="$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/auth/login" || true)"
[ "$code" = "200" ] && exit 0

code="$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" || true)"
case "$code" in 200 | 302 | 401) exit 0 ;; esac

exit 1
