# dsh-docker

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（dsh）封装成**一条命令安装、自带登录、可升级回滚**的 Docker 部署，并配套独立管理工具 `dshm`。

> **非官方项目**，与 DeepSeek 无关。dsh 仍处于预发布阶段。
> v2 正在重构；旧的 v1 文档归档在 [docs/legacy-v1/](docs/legacy-v1/README-v1.md)。

## v2 架构

```text
浏览器 ──▶ dsh 0.0.0.0:3080（dsh-web-startup-auth）
              ├── /dsh        数据：用户、会话、插件、凭据
              └── /workspace  工作区
```

- 不再有反向代理；
- 不再 vendor `dsh-auth-gate`；
- 登录页、会话、API/WebSocket 门禁由 `dsh-web-startup-auth` 在 dsh 进程内完成；
- 管理员账号在 dsh 启动前预置，避免“第一个访问的人成为管理员”；
- 宿主侧反向代理负责 HTTPS；**必须**给 Cookie 补 `Secure`（见下文）。

## 快速开始

环境：Linux、Docker + Compose v2。

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker

# 只安装 dshm，不启动实例
sudo ./install.sh
```

安装完成后二选一。

### 一键安装（只装 dshm）

不 clone 仓库时，从 release 下载安装器并校验：

```bash
TAG=v2026.11.06-1
BASE=https://github.com/qxdho/deepseek-harness-docker/releases/download/$TAG

curl -fsSLO "$BASE/install.sh"
curl -fsSLO "$BASE/install.sh.sha256"
sha256sum -c install.sh.sha256
sudo bash install.sh
```

`install.sh` 还会下载 `dshm-$TAG.tar.gz`，并用同名 `.sha256` 强制校验后才安装。

注意：**它只安装 dshm 工具本身**，不会拉镜像、不会启动 dsh-docker；装完仍要执行下面的 A 或 B。

如果不想手动校验，也可以直接：

```bash
curl -fsSL "$BASE/install.sh" | sudo bash
```

但仍建议至少固定 `TAG`，不要用浮动分支。

### A. 先初始化，编辑配置，再安装

```bash
sudo dshm docker init --dir /opt/dsh \
  --image ghcr.io/qxdho/deepseek-harness-docker:0.2.2-rc.1-2026.11.06-1

sudoedit /opt/dsh/.env        # 至少设置 DSH_AUTH_PASSWORD、端口、路径
sudo dshm docker install --dir /opt/dsh
```

`init` 只生成 `docker-compose.yml` / `.env`，不拉镜像、不启动。  
适合先把密码、域名、端口、数据路径都想清楚再安装。

### B. 直接交互式安装

```bash
sudo dshm docker install
```

会依次生成配置、问登录密码，然后拉镜像、启动、等 `/login` 返回 200。

默认布局：

```text
/opt/dsh/                  # 实例目录
├── docker-compose.yml
├── .env                   # 配置真源（含密码，权限 600）
├── state.json             # 安装后由 dshm 写入
├── data/                  # -> 容器 /dsh
└── workspace/             # -> 容器 /workspace
```

安装完成后访问 `http://127.0.0.1:3080/`。默认只绑本机，远程访问请配反代或 SSH 隧道。

> 镜像由 GitHub Actions 构建并推到 GHCR。当前 v2 tag：`0.2.2-rc.1-2026.11.06-1`；
> 在 v2 镜像成为 `latest` 之前，不要用 `latest` 安装，否则会得到 v1。

## dshm 命令

```bash
dshm update                    # 更新 dshm 自己
dshm version                   # dshm / 镜像 / 容器版本
dshm docker init [选项]          # 只生成配置，不启动
dshm docker install [选项]
dshm docker status|logs|up|down|restart|shell|url
dshm docker update [--to tag]  # 更新 dsh-docker 镜像
dshm docker rollback           # 回退到上一个镜像
dshm docker config show|get|set|edit
dshm docker auth reset         # 重置登录密码
dshm docker doctor
dshm docker uninstall [--purge]
```

`--dir PATH` 或 `DSHM_APP_DIR=...` 可指定实例目录。

## 配置

编辑 `/opt/dsh/.env` 后执行 `dshm docker up` 重建容器。注意：`dshm docker restart` 不会重新读取环境变量。

| 变量 | 默认 | 说明 |
|---|---|---|
| `DSH_HTTP_PORT` | `3080` | 宿主端口 |
| `DSH_BIND` | `127.0.0.1` | 绑定地址；`0.0.0.0` 允许局域网 |
| `DSH_HOME_HOST` | `/opt/dsh/data` | 数据目录 |
| `DSH_WORKSPACE_HOST` | `/opt/dsh/workspace` | 工作区 |
| `DSH_AUTH_USER` | `admin` | 登录用户名 |
| `DSH_AUTH_PASSWORD` | 必填 | **仅首次安装**用于预置管理员 |
| `DSH_PUBLIC_HOST` | 空 | 对外域名；会传给 dsh 作为 `--trusted-host/--public-url` |
| `DSH_COOKIE_SECURE` | `0` | 只影响对外 URL 的 scheme；Cookie Secure 由反代补 |
| `DSH_IMAGE` | GHCR latest | 镜像 tag |
| `DSH_UID` / `DSH_GID` | `1000` | 容器运行身份 |

改密码：

```bash
dshm docker auth reset
```

## HTTPS 与反向代理

容器只提供 HTTP。HTTPS 在宿主机 Nginx / 1Panel / Cloudflare 终止，并**务必开启 WebSocket 转发**。

```nginx
server {
    listen 443 ssl;
    server_name dsh.example.com;

    ssl_certificate     /etc/letsencrypt/live/dsh.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dsh.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 关键：dsh-web-startup-auth 只看容器内是否 TLS，
        # 反代终止 HTTPS 时必须由 Nginx 给 Set-Cookie 补 Secure。
        proxy_cookie_flags ~ secure;
    }
}
```

`.env` 里设置：

```ini
DSH_BIND=127.0.0.1
DSH_PUBLIC_HOST=dsh.example.com
DSH_COOKIE_SECURE=1
```

> 1Panel/OpenResty 需支持 `proxy_cookie_flags`（Nginx 1.19+）。

## 升级、回退、自更新

```bash
dshm docker update                 # 拉最新镜像并重建
dshm docker update --to <tag>      # 指定镜像
dshm docker rollback               # 回到上一个镜像
dshm update                        # 只更新 dshm 自己
```

- `dshm docker update` 会记录 `previous_image`；新版本不健康时自动回滚；
- `dshm update` 只认 dshm 的发布 tag，不跟随 main；
- 数据始终在 `/opt/dsh/data`，升级/回退不迁移数据。

## 从 v1（/dsh）迁移到 /opt/dsh

见 [docs/MIGRATION-v2.md](docs/MIGRATION-v2.md)。核心原则：

- **先复制，不删 `/dsh`**；
- 新实例先用 3081 端口验证，再切 3080；
- v2 会备份旧 gate profile 并重播；
- 旧用户/旧会话不迁移，用 `DSH_AUTH_PASSWORD` 预置新管理员；
- 旧镜像和 `/dsh` 保留，直到验证完成。

## 安全

- 默认只绑 `127.0.0.1`；不要在没有 TLS 的情况下直接暴露到公网；
- `.env` 含密码，权限 600；
- 容器非 root、`cap_drop: ALL`、`no-new-privileges`；
- 工作区/数据目录是 bind mount，属主必须与容器 uid 匹配；
- v2 不再有 TOTP（旧 gate 的功能），需要 TOTP 请暂留 v1；
- HTTPS 反代必须给 Cookie 补 `Secure`。

更完整的 v1 安全边界见归档文档；v2 的边界随重构继续补充。

## 开发

```bash
./scripts/test-all.sh          # 离线测试（需要 bash/curl/node；Go 测试需要 go）
```

CI 在 `.github/workflows/build.yml`：一次 push 一个 workflow；`image` 变更时才构建镜像并跑 `scripts/smoke-v2.sh`。

## 许可证

MIT，见 [LICENSE](LICENSE)。
