# dsh 自建镜像
#
# 借鉴 smanx 的架构（多阶段构建 + 内部回环 + 外部代理），但修正了它的
# cookie authority 缺陷：代理保留原始 Host（changeOrigin=false），并配合
# dsh 的 --trusted-host，使浏览器会话 cookie 的 authority 端到端一致。
#
# ── 为什么必须多阶段 ────────────────────────────────────────────────────────
# @deepseek-ai/dsh 依赖的原生模块 node-pty 在 npm 包里【只带 macOS/Windows
# 预编译产物】，Linux 下没有任何二进制，安装时必然回退到 node-gyp 从源码编译，
# 需要 python3 + make + g++。node:24-slim 不含这些工具，直接
# `npm install -g @deepseek-ai/dsh` 会报：
#   gyp ERR! find Python ... Could not find any Python installation to use
# 所以先在带工具链的阶段安装并编译，再把成果复制进精简运行镜像，
# 运行镜像不保留编译器（除非显式开启 DEV_TOOLS=full 用于运行时装插件）。

ARG NODE_IMAGE=node:24-bookworm-slim

# ── 阶段 1：安装并编译 ──────────────────────────────────────────────────────
FROM ${NODE_IMAGE} AS builder
ARG DSH_VERSION=0.1.7-rc.2
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ \
 && rm -rf /var/lib/apt/lists/*

# 记录待装版本，便于构建日志核对；同时提前预热 npm 缓存
RUN echo "将安装 @deepseek-ai/dsh@${DSH_VERSION}" \
 && npm install -g --no-fund --no-audit "@deepseek-ai/dsh@${DSH_VERSION}" \
 && dsh --version

# ── 阶段 2：运行镜像 ────────────────────────────────────────────────────────
FROM ${NODE_IMAGE}

# 代理运行所需最小依赖：curl 供健康检查，tini 回收孤儿进程，
# ca-certificates 供 dsh 访问模型 API。git/ripgrep 是 agent 的 bash/搜索工具依赖。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git ripgrep tini \
 && rm -rf /var/lib/apt/lists/*

# 复制 Node 运行时 + 已编译好 node-pty 的 dsh
COPY --from=builder /usr/local/ /usr/local/

# 运行时的可选工具链（仅 DEV_TOOLS=full 时安装，供容器内装插件/编译）
ARG DEV_TOOLS=none
RUN if [ "$DEV_TOOLS" = "full" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends python3 make g++ vim less jq unzip \
      && rm -rf /var/lib/apt/lists/*; \
    fi

# 代理本体
WORKDIR /app/proxy
COPY proxy/package.json /app/proxy/package.json
RUN npm install --omit=dev --no-fund --no-audit \
 && npm cache clean --force
COPY proxy/index.js /app/proxy/index.js

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# 以非 root 运行。node 官方镜像自带 uid 1000 的 node 用户。
# DSH_HOME 必须可写：会话、配置、凭证都落在这里，且要能挂卷持久化。
ENV DSH_HOME=/home/node/.dsh \
    HOME=/home/node \
    DSH_HOST=127.0.0.1 \
    DSH_PORT=3079 \
    PROXY_PORT=3080

RUN mkdir -p "$DSH_HOME" /workspace \
 && chown -R node:node "$DSH_HOME" /workspace /app

USER node
WORKDIR /workspace

# 对外只暴露代理端口（dsh 自己监听回环，不出容器）
EXPOSE 3080

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS --max-time 4 "http://127.0.0.1:${PROXY_PORT}/favicon.svg" >/dev/null \
   || curl -fsS --max-time 4 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PROXY_PORT}/" | grep -qE '200|401' \
   || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
