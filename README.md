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
./dshm version list                        # 看有哪些可直接装的镜像，以及 npm 上可装的 dsh 版本
./dshm version update                      # 拉取已构建的最新镜像（快，推荐）
./dshm version update --to <镜像tag>        # 装指定构建，例如 0.2.0-rc.2-2026.10.01-1（回退用）
./dshm version update --build              # 本地构建（慢）；不指定就用 npm 上的最新版
./dshm version update --build --dsh 0.1.7-rc.2   # 本地构建并指定 dsh 版本
```

**优先用已构建的镜像**：打**镜像 tag** 时 CI 会构建并推送，`version update` 直接拉即可。
只有需要验证未发布的仓库改动、或该 dsh 版本还没有已构建的镜像时，才用 `--build` 本地构建。

### 镜像 tag 是怎么编号的

```
0.2.0-rc.2-2026.10.01-1
└────┬───┘ └────┬────┘ └┬┘
   dsh 版本    构建日期   当天序号
```

| 部分 | 作用 |
|---|---|
| `0.2.0-rc.2` | 一眼看出镜像里装的是哪个 dsh |
| `2026.10.01` | 你的构建日期 |
| `-1` `-2` | **同一天的多次构建互不覆盖**，旧镜像仍可回退 |

> [!IMPORTANT]
> **序号是必需的。** 如果 tag 只是 `<dsh版本>`，那么同一天第二次构建会**同名覆盖**
> 第一次 —— 旧镜像失去引用后可能被回收，你就再也退不回去了。所以本项目不使用
> 纯版本号 tag。`latest` 指向最新构建，但**要精确复现某个构建必须用完整 tag**。

> [!NOTE]
> **`dsh` 在构建期由 npm 装入镜像**，所以换 dsh 版本要重建镜像，没有热切换。
> 这是这类封装项目的通行做法（1Panel 应用商店、同类社区项目都如此）：好处是
> **断网也能起**，且版本组合有问题会在**构建期**就失败，不会等起容器才发现。

### 不用惦记着查版本

dsh 处于预览期、发布很密（实测 4 天发了 4 个版本），所以「不知不觉就落后了」是常态。
本项目用两处自动化解决：

- **仓库自动跟上**：CI 每周查一次上游版本，有新版本就**开一个 PR**，你 review 后合并即可。
  选 PR 而不是直接提交，是因为跨次版本可能有破坏性变更，需要人判断。
- **随手能看到**：`./dshm service status` 会顺带告诉你当前版本、是否有新版、以及升级命令。
  离线环境可设 `DSHM_SKIP_UPDATE_CHECK=1` 跳过这一步。

### 两个更新渠道，权威来源不同

这点容易混淆，务必分清：

| 更新对象 | 权威来源 | 命令 |
|---|---|---|
| **`dsh` 本体（容器里跑的东西）** | **npm registry** | `./dshm version update` |
| **`dshm` 工具（脚本 + 管理面板）** | **你打的 tag** | `./dshm dshm update` |

这两个**完全独立**，谁都不影响谁：

- **dsh 的发布渠道是 npm**，不是 GitHub。`version list` 直接查 npm，所以**即使本仓库
  还没跟上，你看到的 dsh 版本仍然是最新的**。上游每几天发一版（实测 4 天 4 个），
  跟不跟由你决定。
- **`dshm` 只认 tag 更新，绝不跟随 main**。这是刻意的：跟随 main 就等于把「你还没
  决定发布的某个中间提交」装到生产上。在 git 工作区里请用 `git pull`；非 git 部署
  机用 `./dshm dshm update`，它只会拉已发布的 tag。

> [!TIP]
> 一句话记忆：**`dshm version` 管容器，`dshm dshm` 管工具自己。**

## 管理命令

`dshm` 按用途分组，`dshm help` 可查看全部命令；`./dshm dshm install` 可将它注册为系统命令，
之后在任意目录直接调用 `dshm`。

```bash
# 服务
./dshm service up          # 启动，或应用 .env 的改动
./dshm service restart     # 重启
./dshm service down        # 停止（数据保留）
./dshm service status      # 健康状态 / 端口 / 登录用户（附带提示 dsh 是否有新版本）
./dshm service logs        # 查看日志
./dshm service shell       # 进入容器

# dsh 版本
./dshm version             # 看全四个版本（配置 / 镜像 / 实际运行 / npm 最新）
./dshm version list        # 列出 npm 上可装的版本
./dshm version update      # 升级

# 登录与账号
./dshm auth password       # 修改登录密码
./dshm auth user add 张三   # 新建用户
./dshm auth totp enable    # 开启两步验证

# 磁盘 / 迁移
./dshm disk                # 磁盘占用与清理命令
./dshm migrate             # 旧命名卷数据迁移

# 管理面板 / dshm 自身
./dshm admin install       # 安装管理面板
./dshm dshm install        # 将 dshm 注册为系统命令
```

| 分组 | 子命令 | 说明 |
|---|---|---|
| `service` | `up` / `down` / `restart` | 启动、停止、重启（`up` 与 `restart` 都会重读 `.env`） |
| `service` | `status` / `logs` / `shell` / `url` | 状态、日志、进容器、一次性 launch URL（排障） |
| `version` | `show`（默认）/ `list` / `update` | 看四个版本、列出已构建镜像与 npm 可装版本、升级 |
| `auth` | `password` / `user` / `totp` | 改密码、增删禁用用户、两步验证 |
| `admin` | `install` / `uninstall` / `url` / `password` / `status` / `logs` | 宿主机管理面板 |
| `dshm` | `version` / `list` / `install` / `uninstall` / `update` | 管理 dshm 自身（对齐 `npm install npm` 的惯例）；**只认 tag** |
| （顶层） | `disk` / `migrate` / `help` | 磁盘占用、数据迁移、帮助 |

> [!NOTE]
> **只保留这一套写法。** 旧的扁平写法（`./dshm up`、`./dshm pw` …）与分组简称
> （`svc` / `login` / `cli` / `panel`）**已全部移除** —— 同时维护两套写法会让帮助变长、
> 新用户不知道该学哪个。误用旧写法时会提示对应的新写法：
>
> ```
> $ ./dshm up
> 错误：命令 'up' 已改为分组写法：dshm service up
> ```

### 版本管理：完整做法

**先建立正确的心智模型**：这个项目里有**两个版本域**，各自的更新方式完全不同。
混起来就会觉得「明明升级了却没变」。

| 版本域 | 管什么 | 真源 | 命令 |
|---|---|---|---|
| **dsh** | 容器里跑的 DeepSeek Harness | **npm registry** | `dshm version …` |
| **dshm**（含管理面板） | 部署管理工具本身 | **你打的 tag** | `dshm dshm …` |

两者**互不影响**：上游发了新 dsh，不代表 dshm 要跟着动；改了 dshm，也不代表 dsh 要升级。

> [!NOTE]
> **管理面板是 dshm 的附属功能，与 dshm 同版本。** 面板二进制的版本号由 CI 从仓库根的
> `VERSION` 文件注入，与 dshm 脚本同源 —— 这是机制保证的，不靠人记。

#### 查

```bash
./dshm version              # 一次看全四个版本（见下）
./dshm version list         # 已构建的镜像 + npm 上可装的 dsh 版本
./dshm service status       # 健康状态（顺带提示 dsh 是否有新版）

./dshm dshm version         # dshm 自己的版本 + 面板是否已装 + 是否有新版（只比 tag）
./dshm dshm list            # 列出全部已发布的 dshm 版本
```

`dshm version` 会列出**四个**可能互不相同的版本：

```
配置里钉的版本：  0.2.0-rc.2      ← 下次构建会得到什么
镜像：            ghcr.io/…:latest ← 拉的哪个镜像
容器内实际运行：  0.2.0-rc.2      ← 真在跑什么
npm 最新：        0.2.0-rc.2      ← 可以要什么
```

**「配置 ≠ 实际运行」时会告警** —— 改了 `.env` 却没 `up` 时就是这种状态，此时
`./dshm service up` 即可应用。

离线环境可设 `DSHM_SKIP_UPDATE_CHECK=1` 跳过联网查询。

#### 升 dsh（容器）

```bash
./dshm version update              # 拉取已构建的最新镜像（快，优先）
./dshm version update --to <镜像tag>  # 装指定构建（回退用）
./dshm version update --build      # 本地构建（慢）；不指定就用 npm 最新版
./dshm version update --build --dsh 0.1.7-rc.2   # 本地构建并指定 dsh 版本
```

| 你的目的 | 用哪个 | 耗时 |
|---|---|---|
| 跟上最新（CI 已构建） | `version update` | 快（拉镜像） |
| 精确装/回退到某次构建 | `version update --to <镜像tag>` | 快（拉镜像） |
| 用 npm 最新版 / 指定版本 | `version update --build [--dsh v]` | 慢（本地构建） |

**为什么换 dsh 版本要重建镜像**：dsh 是**构建期**由 npm 装进镜像的，这是本项目
（以及 1Panel 应用商店、同类项目）的通行做法 —— **断网也能起**，且版本组合有问题会在
**构建期**就失败，不会等起容器才发现。

**回退不会丢数据**：会话、插件、凭据都在 bind mount 的数据目录里。

#### 升 dshm（工具 + 面板）

```bash
./dshm dshm update                 # 装最新已发布版本
./dshm dshm update --to <版本>      # 装/回退到指定版本，如 --to 2026.10.01
```

**只认 tag，绝不跟随 main** —— 以免装到你还没决定发布的中间提交。在 git 工作区里请用
`git pull`；`dshm dshm update` 面向的是没保留 git 仓库的部署机（它默认会在 git 工作区
停下，`--allow-stale` 才继续覆盖）。

**回退到旧版本：`--to` 必须配合 tag 才有意义** —— 所以发布流程是刻意保留给维护者的。

#### 维护者：怎么发布

```bash
# 1. 改 VERSION 文件（唯一真源），提交
git commit -am "chore(release): v2026.10.01" && git push

# 2. 打 tag 并推送 —— CI 会构建面板二进制并发布 release
git tag v2026.10.01 && git push origin v2026.10.01
```

**镜像要单独打 tag 构建**：推 `main` 不会构建镜像（多平台构建要几分钟），需要时推一个
**镜像 tag**（`git tag 0.2.0-rc.2-2026.10.01-3 && git push origin 0.2.0-rc.2-2026.10.01-3`），
CI 会在原生 amd64/arm64 runner 上并行构建并合并成多平台镜像，序号保证同一天多次构建
**互不覆盖**。

**仓库自己也不会落后**：CI 每周查一次上游 dsh 版本，有新版本就**开 PR**（见
`.github/workflows/update-versions.yml`），你 review 后合并即可，不必手工改
`Dockerfile` / `docker-compose.yml` / `.env.example` 里的 `DSH_VERSION`。

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
`DSH_IMAGE` 决定拉取或构建哪个镜像，`./dshm version update` 会按需写入。其余配置项含义见
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
其他容器，则跳过迁移并提示。其他情况可手工执行 `./dshm migrate`；目标目录非空时该命令
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
./dshm disk        # 查看占用并给出清理命令
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
  - **改动前**：跑一遍离线测试（自动发现 `scripts/test-*.sh`），确认没有回归

    ```bash
    ./scripts/test-all.sh
    ```

### 维护者：发布一个版本

发布是维护者动作，**不在 `dshm` 里** —— 普通用户既没有推送权限，也不该关心 tag 和
release。用 `scripts/release.sh`：

```bash
./scripts/release.sh --dry-run    # 先看它要做什么
./scripts/release.sh              # 自动取当天日期；当天已发过则自动加 -1/-2
./scripts/release.sh 2026.10.02   # 指定版本号
```

它会依次：预检（分支 / 工作区 / 与远端同步 / tag 未占用）→ 写 `VERSION` → 提交 →
打同名 tag → 推送 → 等 CI 产出 release。

> [!IMPORTANT]
> **dshm 发布 tag（`v*`）必须等于 `v` + `VERSION` 的内容**（CI 强制校验）。包名、release
> 下载地址、脚本里写死的版本号全都从这一个号派生 —— 两者脱节会发出一个「自更新 404」的
> release。详见 [DESIGN.md](DESIGN.md) 第 10 节。

**镜像要单独打 tag 构建**：推 `main` **不再**构建镜像（多平台构建要几分钟，日常推 main
多数时候并不需要新镜像）。需要新镜像时打一个 **镜像 tag**：

```bash
git tag 0.2.0-rc.2-2026.10.01-3 && git push origin 0.2.0-rc.2-2026.10.01-3
```

tag 名形如 `<dsh版本>-<日期>-<序号>`，序号保证同一天多次构建互不覆盖、可回退。CI 会在
两个原生 runner 上并行构建 amd64 / arm64 并合并成多平台镜像，同时为该 tag 发一份 release
（这样 `./dshm dshm update --to <该 tag>` 也能用）。

## 许可证

本项目基于 [MIT](./LICENSE) 协议发布。你可以自由使用、修改和分发本项目代码，但需保留原始版权声明。

DeepSeek Harness 与 `dsh-auth-gate` 按其各自许可证单独授权；本项目为非官方项目，与上游项目及其
作者无隶属或背书关系。
