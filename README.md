<p align="center">
  <b>deepseek-harness-docker</b><br/>
  <sub>把 DeepSeek Harness 封装为一条命令部署、自带登录的 Docker 服务</sub>
</p>

<p align="center">
  <a href="./LICENSE"><img alt="许可证" src="https://img.shields.io/badge/license-MIT-b8863b?style=flat-square&labelColor=101f38"></a>
  <a href="https://github.com/qxdho/deepseek-harness-docker/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/qxdho/deepseek-harness-docker?style=flat-square&labelColor=101f38&color=b8863b"></a>
  <a href="https://github.com/qxdho/deepseek-harness-docker/issues"><img alt="Issues" src="https://img.shields.io/github/issues/qxdho/deepseek-harness-docker?style=flat-square&labelColor=101f38&color=b8863b"></a>
  <a href="./SECURITY.md"><img alt="安全策略" src="https://img.shields.io/badge/security-policy-b8863b?style=flat-square&labelColor=101f38"></a>
</p>

<p align="center">
  <b>简体中文</b> · <a href="./README_EN.md">English</a>
</p>

<p align="center">
  <a href="#项目定位">项目定位</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="#管理命令">管理命令</a> ·
  <a href="#管理面板">管理面板</a> ·
  <a href="#配置项">配置项</a> ·
  <a href="#数据目录与权限">数据目录与权限</a> ·
  <a href="#https-与反向代理">HTTPS 与反向代理</a> ·
  <a href="#常见问题">常见问题</a> ·
  <a href="#第三方组件">第三方组件</a> ·
  <a href="#许可证">许可证</a>
</p>

> [!IMPORTANT]
> 本项目的代码与文档主要由 AI 生成。作者已在本机完成基本验证，但**未经系统性测试**，
> 用于生产环境前请自行审阅代码与配置。

> [!NOTE]
> 本项目为**非官方项目**，与 DeepSeek 无关；dsh 目前处于预发布阶段。安全边界与已知风险见
> [SECURITY.md](./SECURITY.md)，设计取舍见 [DESIGN.md](./DESIGN.md)。

## 项目定位

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（下称 dsh）是一个 agent 工具：
用户在网页端与模型交互，模型可执行命令、读写文件，并在指定工作区内完成任务。

官方发布的 dsh 以 npm 安装、命令行启动，仅监听回环地址，认证使用一次性 token。若需长期部署在
服务器上供浏览器访问，还需自行处理数据持久化、认证与反向代理等问题。本项目将 dsh 封装为 Docker
镜像，并补齐上述缺口。

```
浏览器 ──▶ proxy（0.0.0.0:3080）──▶ dsh（127.0.0.1:3079）
                                      ├── 工作区
                                      └── 数据目录（配置 / 凭据 / 会话 / 插件）
```

| 官方 dsh 的问题 | 本项目的做法 |
|---|---|
| 只允许监听本机，无法对外访问 | 增加一层代理对外，dsh 自身仍只监听回环 |
| 每次启动要手动复制带 token 的网址 | 登录插件在容器内把一次性 token 换成会话 Cookie，token 不出现 |
| 没有登录功能，谁能连上谁就能用 | 登录插件提供登录页、密码认证、可选两步验证与登录限流 |

主要包含以下部分：

- **安装脚本** `install.sh`：检查 `.env`，缺失项才提示输入，已有配置直接沿用；随后拉取镜像、
  准备目录并启动服务。
- **登录插件**：[dsh-auth-gate](https://github.com/TecFancy/dsh-auth-gate) 提供登录页、密码认证、
  可选两步验证与登录限流，替代官方的一次性 token。
- **proxy**：dsh 拒绝 `--host 0.0.0.0`，对外访问由其转发；同时修复局域网与域名访问时设置页不可用的问题。
- **`dshm` 命令**：部署管理工具，按 `service`、`auth`、`admin`、`self` 分组。
- **管理面板**：运行于宿主机的管理程序，提供状态、启停、日志、磁盘占用与缓存清理，并内置一个
  执行 dshm 命令的控制台。
- **非 root 运行**：容器以普通用户启动，启用 `cap_drop: ALL` 与 `no-new-privileges`，
  文件写入限制在工作区内（Landlock `workspace-write`）。

本项目**不修改 dsh 源码**，仅使用官方扩展机制。

## 快速开始

环境要求：Docker（含 compose v2），以及一个用于存放数据的目录。默认为宿主机 `/dsh`，位于根目录，
首次创建需要 sudo；不便使用 sudo 时可改用其他目录，见[数据目录与权限](#数据目录与权限)。

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
./install.sh          # 只询问一次登录密码
```

安装脚本会逐项检查 `.env`：已有合法值的跳过；未配置但有默认值的项（用户名、端口、监听地址、
数据目录、工作区、容器内路径）**直接采用默认值，不逐个询问**；只有必填且没有默认值的项
（登录密码）才要求输入。密码至少 14 位，且需同时包含大写字母、小写字母、数字与符号。

读取配置后会打印一份**生效配置**清单（端口、数据目录、工作区、运行身份、登录与镜像等），
每项标注「默认」或「已改」。

完成后访问 `http://<服务器IP>:3080/`，用户名 `admin`，密码为上述设置值。

> [!TIP]
> 服务默认只绑定 `127.0.0.1`，即仅宿主机可访问，通常还需在宿主机上配置反向代理。
> 如需先用 IP 直接访问测试，把 `.env` 中的 `DSH_BIND` 改为 `0.0.0.0`，再次执行 `./install.sh`。

模型的密钥可在登录后于「设置 → 模型」中填写，也可在 `.env` 中设置 `DEEPSEEK_API_KEY=sk-...`
后执行 `./dshm service up`。

### 手动部署

不使用安装脚本时，等价流程为：

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
cp .env.example .env     # 按注释修改，至少设置 DSH_AUTH_PASSWORD
docker compose pull      # 拉取 GHCR 上构建好的镜像
docker compose up -d     # 启动服务
```

### 升级

```bash
./dshm service update --latest      # 推荐：向 npm 查最新 dsh 版本并本地构建
./dshm service update               # 拉取 GHCR 上的新镜像（不在本地重建）
./dshm service update --build       # 本地重建（改了仓库代码时）
./dshm service update 0.2.0-rc.2 --build   # 指定 dsh 版本
./dshm service versions             # 列出 npm 上可装的 dsh 版本
```

镜像由 CI 构建并推送至 GHCR，本地重建既慢又不会带来新版本；仅在拉取失败或需要验证未发布的
仓库改动时才使用 `--build`。两种方式都会等待容器进入健康状态，未健康则打印日志并以非 0 退出。

> [!IMPORTANT]
> **`dsh` 在构建期由 npm 装入镜像**，所以换 dsh 版本需要**本地重建**，没有热切换。
> 而 `Dockerfile` / `docker-compose.yml` / `.env.example` 里的 `DSH_VERSION` 是**发布时写死的**，
> 因此直接 `--build` 只会构建出那个旧版本。
>
> 用 **`--latest`** 才会先向 npm 查询最新版并写回 `.env` 再构建。

### 两个更新渠道，权威来源不同

这点容易混淆，务必分清：

| 更新对象 | 权威来源 | 命令 |
|---|---|---|
| **`dsh` 本体** | **npm registry** | `./dshm service update --latest` |
| **`dshm` 脚本自身** | **GitHub 仓库** | `./dshm self update` |

- **dsh 的发布渠道是 npm**，不是 GitHub。`service versions` / `--latest` 都直接查 npm，
  所以**即使 GitHub 仓库不是最新，你看到的 dsh 版本仍然是最新的**。
- **`dshm` 是脚本，随仓库走**。`./dshm self update` 从 GitHub 拉取，适合没保留 git 仓库的
  部署机。在 git 工作区里它会先检查本地是否落后于远端 `main`：落后则停下提醒你用 `git pull`，
  不会静默覆盖你的本地改动（`--allow-stale` 可强制覆盖，`--force` 可重新下载）。

## 管理命令

`dshm` 按用途分组，`dshm help` 可查看全部命令；`./dshm self install` 可将它注册为系统命令，
之后在任意目录直接调用 `dshm`。

```bash
# 服务
./dshm service up          # 启动，或应用 .env 的改动
./dshm service restart     # 重启
./dshm service down        # 停止（数据保留）
./dshm service status      # 健康状态 / 端口 / 登录用户
./dshm service logs        # 查看日志
./dshm service shell       # 进入容器
./dshm service update      # 升级
./dshm service disk        # 磁盘占用与清理命令

# 登录与账号
./dshm auth password       # 修改登录密码
./dshm auth user add 张三   # 新建用户
./dshm auth totp enable    # 开启两步验证

# 管理面板 / 自身
./dshm admin install       # 安装管理面板
./dshm self install        # 将 dshm 注册为系统命令
```

| 分组 | 子命令 | 说明 |
|---|---|---|
| `service` | `up` / `down` / `restart` | 启动、停止、重启（`up` 与 `restart` 都会重读 `.env`） |
| `service` | `status` / `logs` / `disk` | 状态、日志、磁盘占用与清理命令 |
| `service` | `update` / `version` / `shell` | 升级、查看容器内 dsh 版本、进入容器 |
| `service` | `versions` | 列出 npm 上可装的 dsh 版本（标出当前与最新） |
| `service` | `url` / `migrate-home` | 一次性 launch URL（排障）、旧命名卷数据迁移 |
| `auth` | `password` / `user` / `totp` | 改密码、增删禁用用户、两步验证 |
| `admin` | `install` / `uninstall` / `url` / `password` / `status` / `logs` | 宿主机管理面板 |
| `self` | `install` / `uninstall` / `update` | 注册为系统命令、从 GitHub 更新 dshm 自身 |

原有的扁平写法（`./dshm up`、`./dshm pw`、`./dshm user add ...`）仍然可用，但不再写入文档。

## 管理面板

管理面板不是容器，而是运行在宿主机上的一个程序，默认安装于 `/dsh-manager`：

```
/dsh-manager/dsh-admin        程序
/dsh-manager/config.json      配置（密码哈希、会话密钥、监听地址等）
/dsh-manager/dsh-admin.pid    进程号（无 systemd 时生成）
/dsh-manager/dsh-admin.log    日志（无 systemd 时生成）
```

功能包括查看容器状态与健康检查结果、启动/停止/重启、查看日志、查看 Docker 磁盘占用、清理
dangling 镜像与构建缓存，以及在网页端执行 dshm 命令的控制台（仅放行白名单内的命令，并非自由 shell）。

若存在 root 或免密 sudo，面板以 systemd 常驻并开机自启；否则以 pidfile 在后台运行，不随开机自启。
如需更换安装目录，在 `.env` 中设置 `DSH_ADMIN_DIR=$HOME/dsh-manager`，置于用户目录下即无需 sudo。

> [!WARNING]
> 面板持有 `docker.sock`，**权限等同于宿主机 root**。因此它默认只监听 `127.0.0.1`，
> 不应直接暴露至公网。远程访问建议使用 SSH 隧道：
> `ssh -L 3090:127.0.0.1:3090 user@服务器`。

## 配置项

修改 `.env` 后需执行 `./dshm service up` 生效；`restart` 不会重建容器，环境变量不会重新读取。

键名约定：本项目自己的配置一律 `DSH_` 前缀；宿主侧路径以 `_HOST` 结尾，容器侧路径以
`_CONTAINER` 结尾。旧键（`PROXY_PORT`、`DSH_WORKSPACE`、`DSH_HOME`、`DSH_TOTP`、
`AUTH_GATE_VERSION`、`DEV_TOOLS`）会在启动时自动改名，值不变。

**宿主侧**

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DSH_HTTP_PORT` | `3080` | 宿主发布端口（容器内代理固定 3080，与它无关） |
| `DSH_BIND` | `127.0.0.1` | 宿主监听地址；改为 `0.0.0.0` 后局域网可直连 |
| `DSH_HOME_HOST` | `/dsh` | 宿主机数据目录。位于根目录，首次创建需要 sudo；必须为绝对路径 |
| `DSH_WORKSPACE_HOST` | `/dsh/workspace` | 宿主机工作区目录。与数据目录相互独立，须为绝对路径 |
| `DSH_UID` / `DSH_GID` | `1000` / `1000` | 容器运行身份。宿主 uid 非 1000 时改为 `id -u` / `id -g` |
| `DSH_DISK_MIN_MB` | `256` | 启动时要求的最小磁盘余量（MB） |
| `DSH_WORKSPACE_STRICT` | `0` | 置 `1` 后工作区不可写即退出（而非降级启动） |
| `DSH_ADMIN_DIR` | `/dsh-manager` | 管理面板安装目录。由 `dshm` 读取，可使用 `$HOME` 写法 |

**容器侧**

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DSH_HOME_CONTAINER` | `/dsh` | 容器内数据目录，即 bind 挂载的目标路径。该值即根目录本身，不会追加 `.dsh` |
| `DSH_WORKSPACE_CONTAINER` | `/workspace` | 容器内工作区路径 |

**登录与反向代理**

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DSH_AUTH_USER` | `admin` | 登录用户名 |
| `DSH_AUTH_PASSWORD` | 无（**必填**） | 首次启动建号使用；至少 14 位，含大小写字母、数字与符号。后续修改用 `./dshm auth password` |
| `DSH_AUTH_TOTP` | `optional` | `off`、`optional`、`required` |
| `DSH_COOKIE_SECURE` | `0` | 使用 HTTPS 时设为 `1`；纯 HTTP 必须为 `0` |
| `DSH_PUBLIC_HOST` | 空 | 登录页显示的域名 |
| `DSH_TRUST_XFF` | `0` | 置 `1` 后代理信任 `X-Forwarded-For`。仅在确有反代改写该头时开启 |
| `DSH_CLIENT_IP_HEADER` | `x-forwarded-for` | dsh 自身从哪个请求头取客户端 IP |

**构建期**（修改后需重建镜像）：`DSH_VERSION`、`DSH_AUTH_GATE_VERSION`、`DSH_DEV_TOOLS`；
`DSH_IMAGE` 决定拉取或构建哪个镜像，`./dshm service update` 会按需写入。其余配置项含义见
`.env.example` 注释。

> [!NOTE]
> 上游 dsh 自己的变量（`DSH_HOME`、`DSH_HOST`、`DSH_PORT`、`DSH_PERMISSION_MODE`、
> `DSH_TELEMETRY_DISABLED`）由镜像与 compose 注入，不要写进 `.env`。

> [!WARNING]
> - 用户名与密码仅在**首次启动**（尚无用户文件时）生效。之后改密码必须用 `./dshm auth password`。
> - `DSH_AUTH_GATE_VERSION` 仅在 profile 不存在时生效。强制重新播种：
>   ```bash
>   docker exec qxdho-dsh rm -rf /dsh/profiles/web
>   ./dshm service up
>   ```
> - 改了 `DSH_UID` / `DSH_GID` 或各路径后必须 `./dshm service up`；`restart` 不会重建容器。

## 数据目录与权限

数据目录与工作区均为 bind 挂载，两侧路径均可配置：

```bash
DSH_HOME_HOST=/dsh                     # 宿主机数据目录
DSH_HOME_CONTAINER=/dsh                # 容器内挂载点
DSH_WORKSPACE_HOST=/dsh/workspace      # 宿主机工作区
DSH_WORKSPACE_CONTAINER=/workspace     # 容器内工作区路径
```

`DSH_HOME_CONTAINER` 即根目录本身，不会追加 `.dsh`（设为 `/data` 时数据直接位于 `/data` 下）。

数据目录的主要内容：

| 路径 | 内容 |
|---|---|
| `settings.yaml` | 界面设置：默认模型、UI 偏好 |
| `.credentials.yaml` | 模型 API Key 等凭据，以及会话 cookie 的签名密钥（修改后需重新登录） |
| `profiles/` | profile（`web` 等）：配置文件与 `node_modules`，**插件安装在此** |
| `sessions/` | 会话记录 |
| `storages/` | 插件与工具的状态数据 |
| `attachments/` | 上传的附件 |
| `llm-deepseek/` | DeepSeek provider 的本地缓存 |
| `home/` | 供工具使用的 HOME 占位目录 |

备份即备份该目录，登录用户、会话、插件与凭据均在其中。请勿误删。

### 目录属主

宿主机目录若属主为 root（例如未使用 `dshm`、直接执行 `docker compose up`，目录由 dockerd 创建），
容器内以 uid 1000 运行的进程将无法写入，表现为容器反复重启，或 agent 报错：

```
EACCES: permission denied, mkdir '/workspace/xxx'
```

`./install.sh` 与 `./dshm service up` 会在启动前检查，存在 root 或免密 sudo 时直接修正，否则输出
命令供手工执行。工作区不可写时容器**不会退出**，而是降级到数据根下的 `.workspace`，以避免
`restart: unless-stopped` 造成无限重启；如需在不可写时直接退出，设置 `DSH_WORKSPACE_STRICT=1`。

**宿主用户不是 uid 1000**（macOS Docker Desktop、群晖等）时，在 `.env` 中写：

```bash
DSH_UID=1001          # id -u 的结果
DSH_GID=1001          # id -g 的结果
```

容器即以该身份运行，bind mount 属主天然匹配；`./dshm service up` 还会用一次性 root 容器把数据
目录属主改成同一 uid（幂等）。

### 权限被改乱了？一条命令自愈

属主或权限被改乱（手工 `chmod`、面板操作、别的工具）之后，**不需要记住该改成什么** ——
`./dshm service up` 的启动前预检会：

- 属主不是容器 uid → 自动 `chown`（有 root 或免密 sudo 时），否则打印可直接复制的命令
- 目录被改得过宽（组/其他用户可写）→ 自动收紧，去掉 `g+w,o+w`
- 目录不存在 → 按 `umask 0022` 创建（不会建出 777 目录）

即：**先把权限随便改坏，再跑一次 `./dshm service up` 即可恢复。**

> 容器入口本身固定了 `umask 0022`。默认 umask 可能是 `0000`/`0002`，那样新建文件会是
> 666/777 —— **带着可执行位**。你在数据目录里 `git clone` 时，工作区文件就被加上可执行位，
> `git status` 从此一堆「已修改」而 `git diff` 为空。固定为 0022 后新建文件是 644/755，
> 与 git 的期望一致。

### 从旧版本升级

旧版本将数据存放于命名卷 `dsh-home`，现改为 bind 挂载。迁移已内置：

```bash
git pull --ff-only      # 取到新版脚本
docker rm -f dsh        # 旧容器名，视旧版本而定；也可先 docker ps -a 确认
./install.sh            # 检测到旧卷且宿主目录为空时，先自动迁移再启动
```

自动迁移只在「存在旧命名卷」且「`DSH_HOME_HOST` 为空目录」时执行：源卷以只读方式挂载，复制完成后
**不删除原卷**，因此随时可以回退。仍有容器挂着旧卷时，只停止名称或镜像属于本项目的容器；若占用者是
其他容器，则跳过迁移并提示。其他情况可手工执行 `./dshm service migrate-home`；目标目录非空时该命令
会拒绝执行，以免覆盖已有数据。

## HTTPS 与反向代理

容器本身只提供 HTTP。HTTPS 建议在**宿主机反向代理**上终结（Nginx / 宝塔 / Cloudflare 均可），
并**务必开启 WebSocket 转发**。启用后把 `.env` 的 `DSH_COOKIE_SECURE` 设为 `1`，
`DSH_PUBLIC_HOST` 设为你的域名。

```nginx
server {
    listen 443 ssl;
    server_name dsh.example.com;

    ssl_certificate     /etc/letsencrypt/live/dsh.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dsh.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;   # WebSocket
        proxy_set_header Connection "upgrade";
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

> [!TIP]
> 登录限速按客户端 IP 分桶，且只信任来自回环的 `X-Forwarded-For`。确有反向代理改写该头时，
> 把 `DSH_TRUST_XFF` 设为 `1` 并按需调整 `DSH_CLIENT_IP_HEADER`。

## 常见问题

<details>
<summary><b>页面打不开？</b></summary>

<br/>

先看日志：`./dshm service logs`。首次启动需要十几秒，`./dshm service up` 会打印等待进度。

</details>

<details>
<summary><b>日志含 <code>credentials-local: /dsh/.credentials.yaml is readable beyond its owner (mode 777)</code> 或 <code>EACCES: permission denied, open '/dsh/.credentials.yaml'</code>，容器反复重启？</b></summary>

<br/>

dsh 要求凭据文件**只有属主能读写**：权限过宽（`777`、`640`）会被拒绝加载，
而收紧成 `600` 之后若属主仍是 `root`，容器里的 uid 1000 同样读不了（`EACCES`）。
两种情况都来自这个文件本身的权限/属主，通常源自旧命名卷，或在宿主机上被执行过
`chmod -R 777` / `chown` —— **不要对数据目录做 `chmod -R 777`**。

`./dshm service up` 的预检会在启动前改属主并收紧权限；新版镜像的 entrypoint 每次启动
也会再检查一次，读不了时直接打印宿主机上的修复命令。手工修复（`DSH_UID`/`DSH_GID`
取自 `.env`，默认 1000）：

```bash
sudo chown -R 1000:1000 /dsh                                          # 属主统一到容器 uid
sudo chmod 600 /dsh/.credentials.yaml /dsh/settings.yaml /dsh/auth/users.yaml
./dshm service up
```

</details>

<details>
<summary><b>容器反复重启、页面打不开？</b></summary>

<br/>

多为宿主机目录属主不对，日志中会有「不可写」诊断。见[目录属主](#目录属主)。最快修复：

```bash
sudo chown -R 1000:1000 /dsh /dsh/workspace   # 换成你实际的 DSH_HOME_HOST / DSH_WORKSPACE_HOST
./dshm service up
```

</details>

<details>
<summary><b>agent 报 <code>EACCES: permission denied</code>？</b></summary>

<br/>

工作区属主不对，见[目录属主](#目录属主)。

</details>

<details>
<summary><b>密码正确但一直弹回登录页？</b></summary>

<br/>

多半是 `DSH_COOKIE_SECURE=1` 却在用 HTTP 访问。改回 `0` 后执行 `./dshm service up`。

</details>

<details>
<summary><b>忘记登录密码？</b></summary>

<br/>

```bash
./dshm auth password
```

</details>

<details>
<summary><b>想改用非 root 的数据目录？</b></summary>

<br/>

在 `.env` 中同时改宿主与容器两侧路径，例如放到用户目录下：

```bash
DSH_HOME_HOST=$HOME/dsh
DSH_WORKSPACE_HOST=$HOME/dsh-workspace
```

面板目录同理：`DSH_ADMIN_DIR=$HOME/dsh-manager`。修改后执行 `./dshm service up`。

</details>

<details>
<summary><b>磁盘被占满 / 想清理？</b></summary>

<br/>

```bash
./dshm service disk        # 查看占用并给出清理命令
```

容器启动时也要求数据目录与工作区至少有 `DSH_DISK_MIN_MB`（默认 256MB）余量，不足会打印清理指引。

</details>

## 第三方组件

本项目为打包与部署层，主要依赖如下：

| 组件 | 用途 | 许可证 | 来源 |
|---|---|---|---|
| DeepSeek Harness (`@deepseek-ai/dsh`) | 被封装的上游服务本体 | 见上游仓库 | https://github.com/deepseek-ai/deepseek-harness |
| `dsh-auth-gate` | 登录页、会话、两步验证、登录限速、token→Cookie 桥接 | MIT | https://github.com/TecFancy/dsh-auth-gate |
| `http-proxy` | 对外转发代理 | MIT | https://github.com/http-party/node-http-proxy |
| `tini` | 容器 init | MIT | https://github.com/krallin/tini |
| `pnpm` | 插件管理 | MIT | https://github.com/pnpm/pnpm |
| `node:24-bookworm-slim` | 基础镜像 | MIT | https://hub.docker.com/_/node |

上游组件的版权与许可证归其各自作者所有；本仓库不包含也不修改上游源码，仅通过官方 npm 包与镜像引用。

## 参与贡献

欢迎通过 [Issue](https://github.com/qxdho/deepseek-harness-docker/issues) 反馈问题，或提交 Pull Request。

- **流程**：Fork → 新建分支 → 提交改动 → 创建 PR
- **提交信息**：遵循 [Conventional Commits](https://www.conventionalcommits.org/)（`feat:` / `fix:` / `docs:` / `chore:`）
- **改动前**：先跑一遍离线测试，确认没有回归

  ```bash
  ./scripts/test-preflight.sh && ./scripts/test-env-config.sh && \
  ./scripts/test-migrate-home.sh && (cd proxy && node test-inject.js)
  ```

## 许可证

本项目基于 [MIT](./LICENSE) 协议发布。你可以自由使用、修改和分发本项目代码，但需保留原始版权声明。

DeepSeek Harness 与 `dsh-auth-gate` 按其各自许可证单独授权；本项目为非官方项目，与上游项目及其
作者无隶属或背书关系。
