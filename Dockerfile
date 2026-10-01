# syntax=docker/dockerfile:1
#
# dsh 一键部署镜像（DeepSeek Harness + dsh-auth-gate 登录门禁）
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
ARG DSH_VERSION=0.2.0-rc.2
ARG PNPM_VERSION=11.7.0
ARG DSH_AUTH_GATE_VERSION=0.16.0
ENV DEBIAN_FRONTEND=noninteractive

# node-pty 在 Linux 没有预编译产物，安装 dsh 时会用 node-gyp 现场编译
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# npm 缓存用 BuildKit cache mount：不进镜像层，重跑这一层时能复用已下载的包
# （node-pty 仍需现场编译，缓存主要省掉重复下载）。
# 不要再跟 `npm cache clean`，那会把 cache mount 清掉，等于白缓存。
RUN --mount=type=cache,target=/root/.npm \
    DSH_TELEMETRY_DISABLED=1 \
    NARB_DISABLE_NATIVE_CACHE=1 \
    npm_config_cache=/tmp/npm-cache \
    npm_config_fund=false \
    npm_config_audit=false

# 基础运行/agent 工具。DSH_DEV_TOOLS=full 时再加编译链，供容器内现场安装带
# 原生依赖的插件（dsh-auth-gate 已预装，不需要它）。
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git ripgrep jq procps tini unzip zip; \
    if [ "${DSH_DEV_TOOLS}" = "full" ]; then \
        apt-get install -y --no-install-recommends python3 make g++ pkg-config vim less; \
    fi; \
    rm -rf /var/lib/apt/lists/*

# Node 运行时 + 已编译好原生依赖的 dsh + pnpm
COPY --from=builder /usr/local/ /usr/local/
# 预置 profile（含 dsh-auth-gate），供首启或空卷 seeding
COPY --from=builder /opt/dsh-seed /opt/dsh-seed

# 上面这条 COPY 会把 /opt/dsh-seed 的属主**重置成 root:root**（覆盖 builder 阶段的
# chown，因为 COPY 默认以 root 身份复制），而且 profile 里带着 pnpm 以 600/700 建的
# 文件（package.json 600、.plugin-manager 700）。两个后果：
#   1. 容器以 node 运行时，entrypoint 的 `cp -a /opt/dsh-seed/profiles/web` 读不了那些
#      600/700 的文件 —— 空数据目录首启会直接失败并**无限重启**。
#   2. compose 与 README 都允许用 DSH_UID/DSH_GID 改成非 1000 的 uid（NAS、桌面发行版），
#      那时连 node 的属主也帮不上忙，只能靠"对所有人可读"这个权限。
# 所以这里显式恢复属主，并把 seed 目录里的文件改成对所有人可读（目录可进入）——
# 这不会让 dsh 以别人身份写入（数据目录是另一份拷贝），只是让播种能读到。
RUN chown -R node:node /opt/dsh-seed \
    && chmod -R a+rX /opt/dsh-seed

# dsh 启动需要 Node 的 --expose-internals（HMR 插件），npm 生成的软链不带该参数，
# 这里用一层 wrapper 保证任何方式调用 dsh 都正确。先删掉 npm 的软链，避免 COPY
# 顺着软链覆盖到 bin.js。
RUN rm -f /usr/local/bin/dsh
COPY scripts/dsh-wrapper.sh /usr/local/bin/dsh
RUN chmod 0755 /usr/local/bin/dsh

# 对外代理（只转发 + 注入，不做鉴权）
# 用 `npm ci` 并带上 package-lock.json：锁定 http-proxy 的确切版本与传递依赖，
# 构建可复现，也避免 lockfile 与 package.json 漂移时被静默忽略。
WORKDIR /app/proxy
COPY proxy/package.json proxy/package-lock.json /app/proxy/
# npm 缓存目录必须在这里建、并交给 node：npm_config_cache=/tmp/npm-cache
# （见上面的 ENV），而容器以 USER node（或 DSH_UID/DSH_GID 指定的 uid）运行。
# 这句原来写在 COPY --from=builder 之后 —— 那时目录还不存在（要到这次 npm ci
# 才创建），`if [ -d ... ]` 恒假、等于没做；于是 NAS 上用 DSH_UID≠1000 时
# 装插件会报 EACCES，而报错信息完全指不到这里。用 1777（粘滞位）让任意 uid 都能写。
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --no-fund --no-audit \
    && mkdir -p /tmp/npm-cache \
    && chown -R node:node /tmp/npm-cache \
    && chmod 1777 /tmp/npm-cache
COPY proxy/index.js /app/proxy/index.js

COPY entrypoint.sh /app/entrypoint.sh
COPY scripts/healthcheck.sh /usr/local/bin/dsh-healthcheck
RUN chmod 0755 /app/entrypoint.sh /usr/local/bin/dsh-healthcheck

# 让空命名卷/空 bind mount 首启就有可用的已装插件 profile
# 注意：/workspace 的这次 chown 只对「命名卷」有效。生产用的是 bind mount
# （docker-compose.yml），挂载会遮蔽这里的属主 —— 宿主目录的属主才是决定性的，
# 因此运行时用 scripts/preflight.sh 和 entrypoint.sh 的检查兜底。详见 DESIGN.md §5.1。
RUN set -eux; \
    mkdir -p "${DSH_HOME}/profiles" /workspace; \
    cp -a /opt/dsh-seed/profiles/web "${DSH_HOME}/profiles/web"; \
    chown -R node:node "${DSH_HOME}" /workspace /app

USER node
WORKDIR /workspace
EXPOSE 3080

# 健康检查要「快」：dsh 本身几秒就能就绪，entrypoint 也是等到 dsh 回环可访问
# 才启动代理，所以健康检查一旦连得上代理，基本就等于就绪了。
#
# 之前是 --interval=30s --start-period=120s，两个都过大：
#   * start-period 内失败不计入 retries，但**失败会重置计时器**；而 120 秒窗口
#     本身要走完，Docker 才会把状态从 starting 翻成 healthy。于是即使容器
#     3 秒就绪，CLI 也要空等约 2 分钟。
#   * interval=30s 意味着窗口结束后还要再等最多 30 秒才跑第一条检查。
# 现在：15 秒内先探（覆盖正常启动），之后每 5 秒一次；retries=6 给冷启动留余量。
HEALTHCHECK --interval=5s --timeout=5s --start-period=15s --retries=6 \
  CMD ["dsh-healthcheck"]

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
