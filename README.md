# dsh Docker 部署

> 本项目的代码与文档主要由 AI 生成。作者已在本机完成基本验证，但未经系统性测试，
> 用于生产环境前请自行审阅代码与配置。
>
> 本项目为非官方项目，与 DeepSeek 无关。dsh 目前处于预发布阶段。

## 项目定位

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（下称 dsh）是一个 agent 工具：
用户在网页端与模型交互，模型可执行命令、读写文件，并在指定的工作区内完成任务。

官方发布的 dsh 以 npm 安装、命令行启动，仅监听回环地址，认证使用一次性 token。若需长期部署在
服务器上供浏览器访问，还需自行处理数据持久化、认证与反向代理等问题。本项目将 dsh 封装为 Docker
镜像，并补齐上述缺口。

```
浏览器 ──▶ proxy（0.0.0.0:3080）──▶ dsh（127.0.0.1:3079）
                                      ├── 工作区
                                      └── 数据目录（配置 / 凭据 / 会话 / 插件）
```

主要包含以下部分：

- **安装脚本** `install.sh`：检查 `.env`，缺失项才提示输入，已有配置直接沿用；随后拉取镜像、
  检查目录并启动服务。
- **登录插件**：[dsh-auth-gate](https://github.com/TecFancy/dsh-auth-gate) 提供登录页、密码认证、
  可选两步验证与登录限流，替代官方的一次性 token。
- **proxy**：dsh 仅支持监听回环地址（官方拒绝 `--host 0.0.0.0`），对外访问由其转发；同时修复了
  局域网与域名访问时设置页不可用的问题。
- **`dshm` 命令**：部署管理工具，按 `service`、`auth`、`admin`、`self` 分组。
- **管理面板**：运行于宿主机的管理程序，提供状态查看、启停、日志、磁盘占用与缓存清理，
  并内置一个执行 dshm 命令的控制台。
- **配置项**：数据目录、工作区、端口、监听地址、容器 uid 均可配置，默认值可直接使用。
- **非 root 运行**：容器以普通用户启动，启用 `cap_drop: ALL` 与 `no-new-privileges`，
  文件写入限制在工作区内。

本项目不修改 dsh 源码，仅使用官方扩展机制。

## 环境要求

- Docker，含 compose v2。
- 一个用于存放数据的目录。默认为宿主机 `/dsh`，位于根目录，首次创建需要 sudo。
  若不便使用 sudo，可改用其他目录，参见「数据目录」。

## 快速开始

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
./install.sh
```

安装脚本会逐项检查 `.env`：已有合法值的跳过；未配置但有默认值的项（用户名、端口、监听地址、
数据目录、工作区、容器内路径）**直接采用默认值，不逐个询问**；只有必填且没有默认值的项
（登录密码）才要求输入。不合规的历史值会被默认值覆盖并给出提示，例如旧版的
旧键 `DSH_HOME=/home/node/.dsh` 会改为 `DSH_HOME_CONTAINER=/dsh`、空的工作区挂载点会补成 `/workspace`。
密码要求至少 14 位，且同时包含大写字母、小写字母、数字与符号。

完成后访问 `http://<服务器IP>:3080/`，用户名 `admin`，密码为上述设置值。

服务默认只绑定 `127.0.0.1`，即仅宿主机可访问，通常还需在宿主机上配置反向代理。如需先用 IP
直接访问测试，将 `.env` 中的 `DSH_BIND` 改为 `0.0.0.0`，再次执行 `./install.sh`。

模型的密钥可在登录后于「设置 → 模型」中填写，也可在 `.env` 中设置
`DEEPSEEK_API_KEY=sk-...` 后执行 `./dshm service up`。

## 常用命令

`dshm` 按用途分组，`dshm help` 可查看全部命令。

```bash
# 服务
./dshm service up          # 启动，或应用 .env 的改动
./dshm service restart     # 重启
./dshm service down        # 停止（数据保留）
./dshm service status      # 健康状态 / 端口 / 登录用户
./dshm service logs        # 查看日志
./dshm service shell       # 进入容器
./dshm service update      # 升级：默认拉取 GHCR 上的新镜像
./dshm service update --build   # 强制本地重建镜像（改了仓库代码时）
./dshm service disk        # 磁盘占用

# 登录与账号
./dshm auth password       # 修改登录密码
./dshm auth user add 张三   # 新建用户
./dshm auth totp enable    # 开启两步验证

# 管理面板 / 自身
./dshm admin install       # 安装管理面板
./dshm self install        # 将 dshm 注册为系统命令，之后可在任意目录调用
```

原有的扁平写法（`./dshm up`、`./dshm pw`、`./dshm user add ...`）仍然可用，但不再写入文档。

### 升级行为

`./dshm service update` 默认**拉取镜像，不在本地重新构建**。镜像由 CI 构建并推送至 GHCR，
本地重建既慢又不会带来新版本。仅在拉取失败，或需要验证仓库内未发布的改动时，使用
`./dshm service update --build` 强制本地构建。两种方式都会在完成后等待容器进入健康状态，
未健康则打印日志并以非 0 退出。

指定版本时可直接传入版本号（写入 `DSH_IMAGE` 后拉取），例如
`./dshm service update 0.1.7-rc.2`。

## 管理面板

管理面板不是容器，而是运行在宿主机上的一个程序，默认安装于 `/dsh-manager` 目录：

```
/dsh-manager/dsh-admin        程序
/dsh-manager/config.json      配置（密码哈希、会话密钥、监听地址等）
/dsh-manager/dsh-admin.pid    进程号（无 systemd 时生成）
/dsh-manager/dsh-admin.log    日志（无 systemd 时生成）
```

功能包括：查看容器状态与健康检查结果、启动/停止/重启、查看日志、查看 Docker 磁盘占用、
清理 dangling 镜像与构建缓存，以及在网页端执行 dshm 命令的控制台（仅放行白名单内的命令，
并非自由 shell）。

```bash
./dshm admin install     # 安装，默认目录 /dsh-manager
./dshm admin url         # 输出地址，默认 http://127.0.0.1:3090/
./dshm admin password    # 修改面板密码
./dshm admin status      # 查看运行状态
./dshm admin uninstall   # 停止并卸载
```

若存在 root 或免密 sudo，面板以 systemd 常驻并开机自启；否则以 pidfile 在后台运行，不随开机自启。
默认仅监听 `127.0.0.1`，远程访问建议使用 SSH 隧道：
`ssh -L 3090:127.0.0.1:3090 user@服务器`。

如需更换安装目录，在 `.env` 中设置 `DSH_ADMIN_DIR=$HOME/dsh-manager`，置于用户目录下即无需 sudo。

需要注意，面板持有 `docker.sock`，权限等同于宿主机 root。因此默认只监听 `127.0.0.1`，
不应直接暴露至公网。

## 配置项

修改 `.env` 后需执行 `./dshm service up` 生效。`restart` 不会重建容器，环境变量不会重新读取。

键名约定：本项目自己的配置一律 `DSH_` 前缀；宿主侧路径以 `_HOST` 结尾，容器侧路径以
`_CONTAINER` 结尾。旧键（`PROXY_PORT`、`DSH_WORKSPACE`、`DSH_HOME`、`DSH_TOTP`、
`AUTH_GATE_VERSION`、`DEV_TOOLS`）会在启动时自动改名，值不变。

**宿主侧**

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DSH_HTTP_PORT` | `3080` | 宿主发布端口（容器内代理固定 3080，与它无关） |
| `DSH_BIND` | `127.0.0.1` | 宿主监听地址；改为 `0.0.0.0` 后局域网可直连 |
| `DSH_HOME_HOST` | `/dsh` | 宿主机数据目录。位于根目录，首次创建需要 sudo；也可设为其他目录，如 `/home/user/dsh`。必须为绝对路径 |
| `DSH_WORKSPACE_HOST` | `/dsh/workspace` | 宿主机工作区目录，默认跟随数据目录。必须为绝对路径 |
| `DSH_UID` / `DSH_GID` | `1000` / `1000` | 容器运行身份。宿主 uid 非 1000 时改为 `id -u` / `id -g` |
| `DSH_DISK_MIN_MB` | `256` | 启动时要求的最小磁盘余量（MB） |
| `DSH_WORKSPACE_STRICT` | `0` | 置 `1` 后工作区不可写即退出（而非降级启动） |
| `DSH_ADMIN_DIR` | `/dsh-manager` | 管理面板安装目录。该值由 `dshm` 读取，可使用 `$HOME` 写法 |

**容器侧**

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DSH_HOME_CONTAINER` | `/dsh` | 容器内数据目录，即 bind 挂载的目标路径。该值即根目录本身，不会追加 `.dsh` |
| `DSH_WORKSPACE_CONTAINER` | `/workspace` | 容器内工作区路径 |

**登录与反向代理**

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DSH_AUTH_USER` | `admin` | 登录用户名 |
| `DSH_AUTH_PASSWORD` | 无（必填） | 首次启动建号使用；至少 14 位，含大小写字母、数字与符号。后续修改用 `./dshm auth password` |
| `DSH_AUTH_TOTP` | `optional` | `off`、`optional`、`required` |
| `DSH_COOKIE_SECURE` | `0` | 使用 HTTPS 时设为 `1`；纯 HTTP 必须为 `0` |
| `DSH_PUBLIC_HOST` | 空 | 登录页显示的域名 |
| `DSH_TRUST_XFF` | `0` | 置 `1` 后代理信任 `X-Forwarded-For`，用于反代后的客户端地址识别。仅在确有反代改写该头时开启 |
| `DSH_CLIENT_IP_HEADER` | `x-forwarded-for` | dsh 自身从哪个请求头取客户端 IP |

**构建期**（修改后需重建镜像）：`DSH_VERSION`、`DSH_AUTH_GATE_VERSION`、`DSH_DEV_TOOLS`。
`DSH_IMAGE` 决定拉取或构建哪个镜像，`./dshm service update` 会按需写入。
其余配置项的含义见 `.env.example` 注释。

上游 dsh 自己的变量（`DSH_HOME`、`DSH_HOST`、`DSH_PORT`、`DSH_PERMISSION_MODE`、
`DSH_TELEMETRY_DISABLED`）由镜像与 compose 注入，不要写进 `.env`。

两点需要留意：

- 用户名与密码仅在**首次启动**（尚无用户文件时）生效。
- `DSH_AUTH_GATE_VERSION` 仅在 profile 不存在时生效。如需强制重新播种：
  `docker exec qxdho-dsh rm -rf /dsh/profiles/web && ./dshm service up`。

## 数据目录

数据目录与工作区均为 bind 挂载，两侧路径均可配置：

```bash
DSH_HOME_HOST=/dsh                     # 宿主机数据目录
DSH_HOME_CONTAINER=/dsh                # 容器内挂载点
DSH_WORKSPACE_HOST=/dsh/workspace      # 宿主机工作区
DSH_WORKSPACE_CONTAINER=/workspace     # 容器内工作区路径
```

`DSH_HOME_CONTAINER` 即根目录本身，不会追加 `.dsh`（设为 `/data` 时数据直接位于 `/data` 下）。
宿主机目录的属主必须是容器内的 uid（默认 1000）。预检会检查并在权限允许时修正，
否则输出修复命令。

数据目录的主要内容：

| 路径 | 内容 |
|---|---|
| `settings.yaml` | 界面设置：默认模型、UI 偏好 |
| `.credentials.yaml` | 模型 API Key 等凭据，以及会话 cookie 的签名密钥（修改后需重新登录） |
| `profiles/` | profile（`web` 等）：配置文件与 `node_modules`，插件安装在此 |
| `sessions/` | 会话记录 |
| `storages/` | 插件与工具的状态数据 |
| `attachments/` | 上传的附件 |
| `llm-deepseek/` | DeepSeek provider 的本地缓存 |
| `home/` | 供工具使用的 HOME 占位目录 |

备份即备份该目录，登录用户、会话、插件与凭据均在其中。请勿误删。

### 从旧版本升级

旧版本将数据存放于命名卷 `dsh-home`，现改为 bind 挂载。该迁移已内置，升级流程只需：

```bash
git pull --ff-only      # 取到新版脚本
docker rm -f dsh        # 旧容器名，视旧版本而定；也可先 docker ps -a 确认
./install.sh            # 检测到旧卷且宿主目录为空时，先自动迁移再启动
```

自动迁移只在「存在旧命名卷」且「`DSH_HOME_HOST` 为空目录」时执行：源卷以只读方式挂载，
复制完成后**不删除原卷**，因此随时可以回退。仍有容器挂着旧卷时，只停止名称或镜像属于本项目的
容器；若占用者是其他容器，则跳过迁移并提示。

其他情况可手工执行：

```bash
./dshm service migrate-home
```

目标目录非空时该命令会拒绝执行，以免覆盖已有数据。

## 目录属主与权限

宿主机目录若属主为 root（例如未使用 `dshm`，直接执行 `docker compose up`，目录由 dockerd 创建），
容器内以 uid 1000 运行的进程将无法写入，表现为容器反复重启，或 agent 报错：

```
EACCES: permission denied, mkdir '/workspace/xxx'
```

`./install.sh` 与 `./dshm service up` 会在启动前检查，存在 root 或免密 sudo 时直接修正，
否则输出命令供手工执行。

工作区不可写时，容器不会退出，而是降级到数据根下的 `.workspace`（容器内 `$DSH_HOME/.workspace`）
以避免 `restart: unless-stopped` 造成无限重启。如需在不可写时直接退出，设置
`DSH_WORKSPACE_STRICT=1`。

手工修复：

```bash
sudo chown -R 1000:1000 /dsh && ./dshm service up

# 或改用自己拥有的目录，无需 sudo
mkdir -p /home/user/dsh-data
# 然后修改 .env（须写绝对路径：Compose 不展开 ~ 与 $HOME）：
#   DSH_HOME_HOST=/home/user/dsh-data
#   DSH_WORKSPACE_HOST=/home/user/dsh-data/workspace
./dshm service up
```

若宿主 uid 不是 1000（macOS Docker Desktop、群晖等），在 `.env` 中令容器使用相同身份：

```bash
DSH_UID=1001          # id -u
DSH_GID=1001          # id -g
```

## 常见问题

**页面无法打开**：执行 `./dshm service logs` 查看日志。首次启动需要十几秒。

**容器反复重启**：通常是数据目录或工作区属主不正确，日志中会给出说明。

**代理持续输出 `socket hang up`，日志含 `disabling profile plugin row "storage-domain"`**：
profile 由旧镜像播种，缺少 peer 软链。新版本会在启动时自动补齐；旧镜像上可重新播种：

```bash
docker exec qxdho-dsh rm -rf /dsh/profiles/web && ./dshm service up
```

**安装插件后崩溃，或日志含 `No space left on device`**：磁盘已满。查看占用并清理：

```bash
./dshm service disk
docker exec qxdho-dsh rm -rf /dsh/.npm /tmp/npm-cache
docker image prune -a && docker builder prune
```

**密码正确但反复跳回登录页**：`DSH_COOKIE_SECURE=1` 却在使用 HTTP，改回 `0`。

**从旧版本升级**：容器名已由 `dsh` 改为 `qxdho-dsh`，先删除旧容器（`docker rm -f dsh`）。
旧版数据在命名卷 `dsh-home` 中，`./install.sh` 与 `./dshm service up` 会在检测到旧卷且宿主
目录为空时自动迁移；若被跳过，执行 `./dshm service migrate-home`，详见「从旧版本升级」。

**升级后数据不见了**：宿主目录里已有其他内容，自动迁移因此跳过了。执行
`./dshm service migrate-home` 查看原因（目标非空会被明确拒绝）。

## 第三方组件

- [dsh-auth-gate](https://github.com/TecFancy/dsh-auth-gate)（MIT，v0.15.0）：登录页、会话、
  两步验证、限速、token 换 Cookie
- `http-proxy`（MIT）、`tini`、`pnpm`、`node:24-bookworm-slim`

## 许可证

MIT。DeepSeek Harness 与 dsh-auth-gate 按各自许可证授权。

安全相关说明见 [SECURITY.md](SECURITY.md)。
