#!/usr/bin/env bash
# 容器健康检查：登录页能打开才算健康。
#
# 这一条同时证明：dsh 起来了、dsh-web-startup-auth 加载了、/login 路由已注册。
# 不再经过代理，所以直接访问容器内的 3080。
set -euo pipefail
PORT="${DSH_PORT:-3080}"

code="$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/login" || true)"
[ "$code" = "200" ]
