#!/usr/bin/env bash
# 容器健康检查：**登录门禁的页面能打开**才算健康。
#
#   /auth/login 必须返回 200 —— 这一条就同时证明了三件事：
#     dsh 起来了、代理转发通了、dsh-auth-gate 插件挂上了。
#
# 以前这里还有一条兜底：`/` 返回 200/302/401 也算健康。它把「门禁没挂上」这种
# 最危险的状态报成了 healthy —— dsh 自己的令牌门会让 `/` 回 401，于是插件整体
# 没加载时容器照样 green（2026-11-05 的 0.2.2-rc.1 就是这样：门禁消失、容器健康）。
# 这个镜像永远带门禁（entrypoint 会 die），所以不需要那条兜底。
set -euo pipefail
PORT="${PROXY_PORT:-3080}"

code="$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/auth/login" || true)"
[ "$code" = "200" ]
