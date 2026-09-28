# dsh Docker 部署

先说清楚：**这个项目的代码和文档基本都是 AI 写的**。功能我跑通了，也在自己用，但它没经过
严格测试——真要拿它上生产，请自己把代码看一遍。

另外，这是个非官方项目，和 DeepSeek 没有关系；dsh 本身也还在预发布阶段。

## 这个项目是干什么的

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（简称 dsh）是个 agent 工具：
你在网页上跟 AI 说话，它能执行命令、读写文件，在指定的工作区里替你干活。

官方版本是 npm 安装、命令行启动、只监听本机、用一次性 token 登录。想把它长期架在服务器上、
用浏览器访问，还得自己解决持久化、登录、反代这些琐事。这个项目就是把 dsh 打进 Docker 镜像，
顺便把这些补齐：

```
浏览器 ──▶ proxy（0.0.0.0:3080）──▶ dsh（127.0.0.1:3079）
                                      ├── 工作区     ← 挂在宿主目录
                                      └── 数据目录   ← 挂在宿主目录（设置 / 凭据 / 会话 / 插件）
```

主要包含这几块：

- **一键安装脚本 `install.sh`**：检查 `.env`，空着的才问、有值的跳过，然后拉镜像、检查目录、启动。
- **登录插件**：用 [dsh-auth-gate](https://github.com/TecFancy/dsh-auth-gate) 做登录页、密码、
  可选两步验证和登录限流，替掉官方的一次性 token。
- **proxy**：dsh 只肯监听回环地址（`--host 0.0.0.0` 会被官方拒绝），对外访问靠它转发。
  它还顺手修了局域网/域名下设置页打不开的问题。
- **`dshm` 命令**：部署管理，按 `service` / `auth` / `admin` / `self` 分组。
- **管理面板**：跑在宿主机上的一个小程序，看状态、启停重启、看日志、看磁盘、清缓存，
  也能在网页里跑 dshm 命令。
- **配置灵活**：数据目录、工作区、端口、监听地址、容器 uid 都能改，默认值开箱可用。
- **非 root**：容器以普通用户运行，`cap_drop: ALL`、`no-new-privileges`，文件写入限制在工作区内。

这个项目不改 dsh 的源码，走的是官方扩展机制。

## 装之前需要

- Docker，带 compose v2。
- 一个放数据的目录。默认用宿主机的 `/dsh`，它在根目录下，第一次创建需要 sudo。
  不想用 sudo 就换个地方，见下面「数据放哪」。

## 快速开始

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
./install.sh
```

安装时会逐项检查 `.env`：**有值的跳过，空着的才问**（登录密码、用户名、端口、监听地址、
数据目录、工作区）。密码要求至少 14 位，且同时有大写、小写、数字和符号。

装完打开 `http://<服务器IP>:3080/`，用户名 `admin`，密码是你刚设的。

默认只绑 `127.0.0.1`，也就是只有宿主机自己能访问，服务器上一般还要自己加一层 Nginx 之类的
反代。想先用 IP 直接访问测试：把 `.env` 里的 `DSH_BIND` 改成 `0.0.0.0`，再跑一次 `./install.sh`。

登录后到「设置 → 模型」里填 DeepSeek API Key；也可以先在 `.env` 写
`DEEPSEEK_API_KEY=sk-...`，然后 `./dshm service up`。

## 常用命令

`dshm` 按用途分了几组，`dshm help` 看全部：

```bash
# 服务
./dshm service up          # 启动，或应用 .env 的改动
./dshm service restart     # 重启
./dshm service down        # 停止（数据保留）
./dshm service status      # 健康 / 端口 / 登录用户
./dshm service logs        # 看日志
./dshm service shell       # 进容器
./dshm service update      # 升级 dsh
./dshm service disk        # 磁盘占用

# 登录与账号
./dshm auth password       # 改登录密码
./dshm auth user add 张三   # 新建用户
./dshm auth totp enable    # 开启两步验证

# 管理面板 / 自身
./dshm admin install       # 安装管理面板
./dshm self install        # 把 dshm 注册成系统命令，之后任意目录直接敲 dshm
```

旧的平铺写法（`./dshm up`、`./dshm pw`、`./dshm user add ...`）也还能用，只是文档里不再写了。

## 管理面板

它不是容器，是跑在宿主机上的一个程序。默认装在 `/dsh-manager` 一个目录里：

```
/dsh-manager/dsh-admin        程序
/dsh-manager/config.json      配置（密码哈希、会话密钥、监听地址等）
/dsh-manager/dsh-admin.pid    进程号（没有 systemd 时才有）
/dsh-manager/dsh-admin.log    日志（没有 systemd 时才有）
```

能做的事：看容器状态和健康、启动/停止/重启、看日志、看 Docker 的磁盘占用、清掉 dangling
镜像和构建缓存，另外有一个命令台——在网页里直接跑 `dshm` 命令（只放行白名单里的命令，
不是自由 shell）。

```bash
./dshm admin install     # 安装（默认目录 /dsh-manager）
./dshm admin url         # 打印地址，默认 http://127.0.0.1:3090/
./dshm admin password    # 改面板密码
./dshm admin status      # 面板在不在跑
./dshm admin uninstall   # 停止并卸载
```

有 root 或免密 sudo 时，用 systemd 常驻、开机自启；没有就用 pidfile 后台跑（不会开机自启）。
默认只监听 `127.0.0.1`，远程看用 SSH 隧道：
`ssh -L 3090:127.0.0.1:3090 user@服务器`。

想换安装目录，`.env` 里写 `DSH_ADMIN_DIR=$HOME/dsh-manager`——放到自己家里就不需要 sudo。

有一点要明白：**面板持有 `docker.sock`，等于宿主 root**。所以它默认只听 `127.0.0.1`，
不要直接暴露到公网。

## 配置

改完 `.env` 要跑 `./dshm service up` 才生效。注意不是 `restart`——`restart` 不会重建容器，
环境变量不会重新读。

| 变量 | 默认 | 说明 |
|---|---|---|
| `DSH_AUTH_PASSWORD` | 无（必填） | 首次启动建号用；至少 14 位，含大小写/数字/符号。之后改密码用 `./dshm auth password` |
| `PROXY_PORT` | `3080` | 宿主机端口 |
| `DSH_BIND` | `127.0.0.1` | 改成 `0.0.0.0` 局域网可直连 |
| `DSH_HOME_HOST` | `/dsh` | 宿主机上的数据目录。在根目录下，首次创建要 sudo；也可以写 `$HOME/dsh` |
| `DSH_HOME` | `/dsh` | 容器内的数据目录，就是根目录本身，不会再拼一层 `.dsh` |
| `DSH_WORKSPACE` | `/dsh/workspace` | 宿主机上的工作区目录，默认跟着数据目录走 |
| `DSH_WORKSPACE_CONTAINER` | `/workspace` | 容器内的工作区路径 |
| `DSH_UID` / `DSH_GID` | `1000` / `1000` | 容器以什么身份运行。宿主 uid 不是 1000 时改成 `id -u` / `id -g` |
| `DSH_TOTP` | `optional` | `off` / `optional` / `required` |
| `DSH_COOKIE_SECURE` | `0` | 用 HTTPS 才设成 `1`；纯 HTTP 必须是 `0` |
| `DSH_PUBLIC_HOST` | 空 | 登录页上显示的域名 |
| `DSH_ADMIN_DIR` | `/dsh-manager` | 管理面板的安装目录 |

还有几个构建期变量（改了要重建镜像）：`DSH_VERSION`、`AUTH_GATE_VERSION`、`DEV_TOOLS`、
`DSH_IMAGE`。其余项的含义都写在 `.env.example` 的注释里。

两点容易踩：

- 用户名和密码只在**第一次启动**（还没有用户文件时）用到。
- `AUTH_GATE_VERSION` 只在 profile 不存在时生效。想强制重新播种：
  `docker exec qxdho-dsh rm -rf /dsh/profiles/web && ./dshm service up`。

## 数据放哪

数据目录和工作区都是 bind 挂载，两边路径都能配：

```bash
DSH_HOME_HOST=/dsh                    # 宿主机数据目录
DSH_HOME=/dsh                         # 容器内挂载点
DSH_WORKSPACE=/dsh/workspace          # 宿主机工作区
DSH_WORKSPACE_CONTAINER=/workspace    # 容器内工作区路径
```

`DSH_HOME` 就是根目录本身，不会再拼一层 `.dsh`（写 `/data` 的话数据就摊在 `/data` 下面）。
宿主目录的属主必须是容器里的 uid（默认 1000）——预检会查，能改就改，改不了会告诉你怎么办。

数据目录里主要是这些东西：

| 路径 | 内容 |
|---|---|
| `settings.yaml` | 界面设置：默认模型、UI 偏好 |
| `.credentials.yaml` | 模型 API Key 等凭据，以及会话 cookie 的签名密钥（动它所有人要重新登录） |
| `profiles/` | profile（`web` 等）：配置文件和 `node_modules`，**插件装在这里** |
| `sessions/` | 会话记录 |
| `storages/` | 插件和工具的状态数据 |
| `attachments/` | 上传的附件 |
| `llm-deepseek/` | DeepSeek provider 的本地缓存 |
| `home/` | 给工具用的 HOME 占位目录 |

**备份就是备份这个目录**：登录用户、会话、插件、凭据都在里面。也别手滑 `rm -rf /dsh`。

### 从旧版本升级

旧版本把数据存在命名卷 `dsh-home` 里，现在改成 bind 挂载了。升级后如果起来看着像全新安装，
跑一次这个把数据搬过来：

```bash
./dshm service migrate-home
```

它会把旧卷复制到 `DSH_HOME_HOST`（源卷只读挂载，不动原数据），确认没问题后再按提示删旧卷。

## 目录属主不对会怎样

宿主机上的目录如果属主是 root（比如你没走 `dshm`，直接 `docker compose up`，目录是 dockerd
替你建的），容器里以 uid 1000 运行的进程就写不进去。现象是容器反复重启，或者 agent 报：

```
EACCES: permission denied, mkdir '/workspace/xxx'
```

`./install.sh` 和 `./dshm service up` 在启动前都会检查，有 root 或免密 sudo 时直接修；
修不了就打印命令让你自己执行。

工作区不可写时，容器不会退出，而是降级到 `$DSH_HOME/.workspace` 继续启动，日志里打横幅——
这是为了避免 `restart: unless-stopped` 把它拖成无限重启。想让它在不可写时直接退出，设
`DSH_WORKSPACE_STRICT=1`。

手工修：

```bash
sudo chown -R 1000:1000 /dsh && ./dshm service up

# 或者换成你自己拥有的目录，不需要 sudo
mkdir -p ~/dsh-data
# 然后改 .env：
#   DSH_HOME_HOST=$HOME/dsh-data
#   DSH_WORKSPACE=$HOME/dsh-data/workspace
./dshm service up
```

宿主 uid 不是 1000（macOS Docker Desktop、群晖之类），在 `.env` 里让容器也用你的身份：

```bash
DSH_UID=1001          # id -u
DSH_GID=1001          # id -g
```

## 常见问题

**页面打不开**：`./dshm service logs` 看日志，首次启动要等十几秒。

**容器一直重启**：多半是数据目录或工作区的属主不对，日志里会直接写出来。

**代理一直刷 `socket hang up`，日志里有 `disabling profile plugin row "storage-domain"`**：
profile 是旧镜像播种的，缺 peer 软链。新版启动时会自动补齐；旧镜像上重新播种一次：

```bash
docker exec qxdho-dsh rm -rf /dsh/profiles/web && ./dshm service up
```

**装完插件崩了，或日志里有 `No space left on device`**：磁盘满了。先看占用，再清缓存：

```bash
./dshm service disk
docker exec qxdho-dsh rm -rf /dsh/.npm /tmp/npm-cache
docker image prune -a && docker builder prune
```

**密码对但一直弹回登录页**：`DSH_COOKIE_SECURE=1` 却在用 HTTP，改回 `0`。

**旧版本升级**：容器名从 `dsh` 改成了 `qxdho-dsh`，先把旧容器删掉：`docker rm -f dsh`。

## 第三方组件

- [dsh-auth-gate](https://github.com/TecFancy/dsh-auth-gate)（MIT，v0.15.0）——登录页、会话、
  两步验证、限速、token 换 Cookie
- `http-proxy`（MIT）、`tini`、`pnpm`、`node:24-bookworm-slim`

## 许可证

MIT。DeepSeek Harness 和 dsh-auth-gate 按各自许可证授权。

安全相关的说明见 [SECURITY.md](SECURITY.md)。
