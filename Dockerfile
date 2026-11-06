# syntax=docker/dockerfile:1
#
# dsh-docker v2：dsh + dsh-web-startup-auth
#
# 架构：
#   浏览器 -> dsh 0.0.0.0:3080（web profile + dsh-web-startup-auth）
#
# 与 v1 的区别：
#   * 不再有反向代理；dsh-web-startup-auth 替换 dsh 的 startup，允许监听 0.0.0.0。
#   * 不再有 dsh-auth-gate / vendor 补丁 / sync-gate。
#   * 登录页、会话、API/WebSocket 门禁由 dsh-web-startup-auth 在 dsh 进程内完成。
#   * 账号在 dsh 启动前由 entrypoint 预置，避免“第一个访问的人成为管理员”。

ARG NODE_IMAGE=node:24-bookworm-slim@sha256:c86ecead9e55a5210ac1727de38a4ca840bf03dcaf34dc9749addbf383b1920c

# ── 阶段 1：安装 dsh 并预置 web-auth profile ────────────────────────────────
FROM ${NODE_IMAGE} AS builder
ARG DSH_VERSION=0.2.2-rc.1
ARG PNPM_VERSION=11.7.0
ARG DSH_WEB_AUTH_VERSION=0.1.14
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN --mount=type=cache,target=/root/.npm \
    npm install -g --no-fund --no-audit \
      "pnpm@${PNPM_VERSION}" \
      "@deepseek-ai/dsh@${DSH_VERSION}" \
 && test "$(dsh --version)" = "${DSH_VERSION}"

ENV DSH_HOME=/opt/dsh-seed \
    HOME=/opt/dsh-seed

RUN set -eux; \
    mkdir -p "${DSH_HOME}"; \
    DSH_BIN="$(npm root --global)/@deepseek-ai/dsh/lib/bin.js"; \
    node --expose-internals "$DSH_BIN" --profile web --dump-config >/dev/null; \
    node --expose-internals "$DSH_BIN" plugin --profile web add "dsh-web-startup-auth@${DSH_WEB_AUTH_VERSION}"; \
    test -f "${DSH_HOME}/profiles/web/node_modules/dsh-web-startup-auth/lib/auth.js"; \
    test -f "${DSH_HOME}/profiles/web/node_modules/dsh-web-startup-auth/lib/startup.js"; \
    # dsh 默认把首次工作区放在 <Documents>/deepseek-harness；容器没有
    # xdg-user-dir/Documents，首次登录会报“无法创建默认工作区”。显式指到挂载的
    # /workspace，避免用户第一次打开页面就卡住。
    patch="${DSH_HOME}/profiles/web/cordis.patch.yml"; \
    if [ -f "$patch" ]; then \
      sed -i '/^\[\]$/d' "$patch"; \
      printf '\n- id: workspace-controller\n  config:\n    documentsDirectory: /workspace\n' >> "$patch"; \
    else \
      printf -- '- id: workspace-controller\n  config:\n    documentsDirectory: /workspace\n' > "$patch"; \
    fi; \
    # 构建期冒烟：证明凭据存储真的能写、能读，然后删掉测试文件。
    node --input-type=module -e 'const {registerCredentials}=await import(process.argv[1]); registerCredentials("build-smoke","build-smoke-password")' \
      "${DSH_HOME}/profiles/web/node_modules/dsh-web-startup-auth/lib/credential-store.js"; \
    test -s "${DSH_HOME}/web-auth.json"; \
    rm -f "${DSH_HOME}/web-auth.json"; \
    # pnpm 在构建期记录的绝对路径进入数据卷后必然失配；删掉让运行期重算。
    rm -f "${DSH_HOME}/profiles/web/node_modules/.modules.yaml"; \
    node --expose-internals "$DSH_BIN" --version

RUN chown -R node:node /opt/dsh-seed \
    && chmod -R a+rX /opt/dsh-seed

# ── 阶段 2：运行镜像 ────────────────────────────────────────────────────────
FROM ${NODE_IMAGE}

ARG DSH_DEV_TOOLS=none

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/node \
    DSH_HOME=/home/node/.dsh \
    DSH_HOST=0.0.0.0 \
    DSH_PORT=3080 \
    DSH_PERMISSION_MODE=workspace-write \
    DSH_TELEMETRY_DISABLED=1 \
    NARB_DISABLE_NATIVE_CACHE=1 \
    npm_config_cache=/tmp/npm-cache \
    npm_config_fund=false \
    npm_config_audit=false

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git ripgrep jq procps tini unzip zip; \
    if [ "${DSH_DEV_TOOLS}" = "full" ]; then \
        apt-get install -y --no-install-recommends python3 make g++ pkg-config vim less; \
    fi; \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/ /usr/local/
COPY --from=builder /opt/dsh-seed /opt/dsh-seed

# dsh 启动需要 Node 的 --expose-internals（HMR 插件）；npm 的软链不带该参数。
RUN rm -f /usr/local/bin/dsh
COPY scripts/dsh-wrapper.sh /usr/local/bin/dsh
RUN chmod 0755 /usr/local/bin/dsh

COPY entrypoint.sh /app/entrypoint.sh
COPY scripts/seed-auth.mjs /app/scripts/seed-auth.mjs
COPY scripts/healthcheck.sh /usr/local/bin/dsh-healthcheck
RUN chmod 0755 /app/entrypoint.sh /usr/local/bin/dsh-healthcheck

# 运行时 /workspace 通常是 bind mount；这里的 chown 只对命名卷生效。
RUN set -eux; \
    mkdir -p "${DSH_HOME}/profiles" /workspace /tmp/npm-cache; \
    cp -a /opt/dsh-seed/profiles/web "${DSH_HOME}/profiles/web"; \
    chown -R node:node "${DSH_HOME}" /workspace /app /tmp/npm-cache; \
    chmod 1777 /tmp/npm-cache

USER node
WORKDIR /workspace
EXPOSE 3080

HEALTHCHECK --interval=5s --timeout=5s --start-period=20s --retries=6 \
  CMD ["dsh-healthcheck"]

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
