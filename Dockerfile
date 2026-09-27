# syntax=docker/dockerfile:1
#
# dsh 一键部署镜像（DeepSeek Harness + dsh-auth-gate 登录门禁）
#
# 架构：
#   浏览器 -> 代理 0.0.0.0:3080 -> dsh 127.0.0.1:3079（web profile + dsh-auth-gate）
#
# 要点：
#   * dsh 官方拒绝 --host 0.0.0.0，所以 dsh 只听回环，对外由代理承担。
#   * 登录、会话、可选 TOTP 由 dsh-auth-gate 插件在 dsh 进程内完成；
#     它还负责把 dsh 的一次性 launch token 自动桥接成会话 Cookie，
#     所以用户永远不需要看到或复制 token。
#   * 代理只做三件事：监听 0.0.0.0、把 Host/Origin 一致改写成回环 authority、
#     往 HTML 里注入 crypto.randomUUID 补丁和 __DSH_TRANSPORT__.ownsHost。
#     它不做鉴权。
#   * 不改 dsh 任何文件。dsh 升级不会让代理或补丁失效。

ARG NODE_IMAGE=node:24-bookworm-slim

# ── 阶段 1：安装 dsh 并预置插件 ─────────────────────────────────────────────
FROM ${NODE_IMAGE} AS builder
ARG DSH_VERSION=0.1.7-rc.2
ARG PNPM_VERSION=11.7.0
ARG AUTH_GATE_VERSION=0.15.0
ENV DEBIAN_FRONTEND=noninteractive

# node-pty 在 Linux 没有预编译产物，安装 dsh 时会用 node-gyp 现场编译
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g --no-fund --no-audit \
      "pnpm@${PNPM_VERSION}" \
      "@deepseek-ai/dsh@${DSH_VERSION}" \
 && test "$(dsh --version)" = "${DSH_VERSION}" \
 && npm cache clean --force

# 预置一个带 dsh-auth-gate 的 web profile。装进镜像后，首次启动无需联网装插件。
ENV DSH_HOME=/opt/dsh-seed
RUN set -eux; \
    mkdir -p "${DSH_HOME}"; \
    DSH_BIN="$(npm root --global)/@deepseek-ai/dsh/lib/bin.js"; \
    node --expose-internals "$DSH_BIN" --profile web --dump-config >/dev/null; \
    node --expose-internals "$DSH_BIN" plugin --profile web add "dsh-auth-gate@${AUTH_GATE_VERSION}"; \
    # dsh-auth-gate 的 CLI 直接跑时需要 dsh 提供的 peer 依赖，补软链后可在
    # 容器内用 CLI 建用户（dsh 进程本身自行解析这些 peer，不受影响）。
    ln -sfn "$(npm root --global)/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-storage-domain" \
            "${DSH_HOME}/profiles/web/node_modules/@deepseek-ai/dsh-storage-domain"; \
    ln -sfn "$(npm root --global)/@deepseek-ai/dsh/node_modules/@deepseek-ai/cordis" \
            "${DSH_HOME}/profiles/web/node_modules/@deepseek-ai/cordis"; \
    # 构建期冒烟：证明 CLI 真能建用户，然后删掉这个临时用户文件
    printf '%s\n' 'build-smoke-only' \
      | node "${DSH_HOME}/profiles/web/node_modules/dsh-auth-gate/lib/cli.js" user add build-smoke --password-stdin; \
    test -s "${DSH_HOME}/auth/users.yaml"; \
    rm -rf "${DSH_HOME}/auth"; \
    node --expose-internals "$DSH_BIN" --version

# ── 阶段 2：运行镜像 ────────────────────────────────────────────────────────
FROM ${NODE_IMAGE}

ARG DSH_VERSION=0.1.7-rc.2
ARG DEV_TOOLS=none

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/node \
    DSH_HOME=/home/node/.dsh \
    DSH_HOST=127.0.0.1 \
    DSH_PORT=3079 \
    PROXY_PORT=3080 \
    DSH_PERMISSION_MODE=workspace-write \
    DSH_TELEMETRY_DISABLED=1 \
    NARB_DISABLE_NATIVE_CACHE=1

# 基础运行/agent 工具。DEV_TOOLS=full 时再加编译链，供容器内现场安装带
# 原生依赖的插件（dsh-auth-gate 已预装，不需要它）。
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git ripgrep jq procps tini unzip zip; \
    if [ "${DEV_TOOLS}" = "full" ]; then \
        apt-get install -y --no-install-recommends python3 make g++ pkg-config vim less; \
    fi; \
    rm -rf /var/lib/apt/lists/*

# Node 运行时 + 已编译好原生依赖的 dsh + pnpm
COPY --from=builder /usr/local/ /usr/local/
# 预置 profile（含 dsh-auth-gate），供首启或空卷 seeding
COPY --from=builder /opt/dsh-seed /opt/dsh-seed

# dsh 启动需要 Node 的 --expose-internals（HMR 插件），npm 生成的软链不带该参数，
# 这里用一层 wrapper 保证任何方式调用 dsh 都正确。先删掉 npm 的软链，避免 COPY
# 顺着软链覆盖到 bin.js。
RUN rm -f /usr/local/bin/dsh
COPY scripts/dsh-wrapper.sh /usr/local/bin/dsh
RUN chmod 0755 /usr/local/bin/dsh

# 对外代理（只转发 + 注入，不做鉴权）
WORKDIR /app/proxy
COPY proxy/package.json /app/proxy/package.json
RUN npm install --omit=dev --no-fund --no-audit && npm cache clean --force
COPY proxy/index.js /app/proxy/index.js

COPY entrypoint.sh /app/entrypoint.sh
COPY scripts/healthcheck.sh /usr/local/bin/dsh-healthcheck
RUN chmod 0755 /app/entrypoint.sh /usr/local/bin/dsh-healthcheck

# 让空命名卷/空 bind mount 首启就有可用的已装插件 profile
RUN set -eux; \
    mkdir -p "${DSH_HOME}/profiles" /workspace; \
    cp -a /opt/dsh-seed/profiles/web "${DSH_HOME}/profiles/web"; \
    chown -R node:node "${DSH_HOME}" /workspace /app

USER node
WORKDIR /workspace
EXPOSE 3080

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD ["dsh-healthcheck"]

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
