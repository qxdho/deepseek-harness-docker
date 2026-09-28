# dsh 一键部署镜像

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（dsh）网页版打包成
一条命令部署、自带登录的 Docker 服务。浏览器打开就能用，只有你能进。

> 非官方社区项目。dsh 处于预发布阶段，见 [SECURITY.md](SECURITY.md)。

## 快速开始

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
./install.sh          # 逐项检查 .env：为空的才问，已配置的直接跳过
```

安装时会逐项检查 `.env`：**已经有值的跳过，只有空着的才询问**（登录密码、用户名、端口、
监听地址、工作区）。两步验证与 API Key 不在安装时询问，需要时直接写进 `.env` 或登录后
在界面里配置。非交互场景（CI/管道）不会卡住：缺失的必填项直接报错，有默认值的用默认值。
想改已有配置就编辑 `.env`。

打开 `http://<服务器IP>:3080/`，用 `admin` + 你的密码登录。

登录后先在「设置 → 模型」填 DeepSeek API Key；或在 `.env` 里加 `DEEPSEEK_API_KEY=sk-...`
后跑 `./dshm up`。

> 默认只绑 `127.0.0.1`。想用 IP 直接访问：`.env` 里 `DSH_BIND=0.0.0.0`，再跑 `./install.sh`。

## 与官方 dsh 的区别

| | 官方 dsh | 本项目 |
|---|---|---|
| 部署 | npm 命令行 | Docker 镜像，一条命令 |
| 认证 | 一次性 token | 登录页 + 密码 + 可选 TOTP + 限速 |
| 对外访问 | 只允许本机 | 代理对外，dsh 仍只监听回环 |
| 局域网/域名 | 设置页不可用、前端报错 | 已修复 |
| 加固 | 需自行配置 | 非 root + 最小权限 + workspace-write |

```
浏览器 → 代理 0.0.0.0:3080 → dsh 127.0.0.1:3079（带登录插件）
```

本项目**不改 dsh 源码**，只用官方扩展机制。

## 配置项

改 `.env` 后跑 `./dshm up` 生效（`restart` 不重建容器，环境变量不会重读）。

| 变量 | 默认 | 说明 |
|---|---|---|
| `DSH_AUTH_PASSWORD` | 无（**必填**） | 首次启动建号；≥14 位且含大小写/数字/符号。之后改密码用 `./dshm pw` |
| `PROXY_PORT` | `3080` | 宿主机端口 |
| `DSH_BIND` | `127.0.0.1` | `0.0.0.0` = 局域网可直连 |
| `DSH_WORKSPACE` | `./workspace` | agent 工作目录，见「工作区权限」 |
| `DSH_UID` / `DSH_GID` | `1000` / `1000` | 容器运行身份。宿主 uid 不是 1000 时改成 `id -u` / `id -g` |
| `DSH_TOTP` | `optional` | `off` / `optional` / `required` |
| `DSH_COOKIE_SECURE` | `0` | **HTTP 必须 0**；HTTPS 建议 `1` |
| `DSH_PUBLIC_HOST` | 空 | 登录页显示的域名 |

构建期变量（改了需重建镜像）：`DSH_VERSION`、`AUTH_GATE_VERSION`、`DEV_TOOLS`、`DSH_IMAGE`。

> `DSH_AUTH_USER` / `DSH_AUTH_PASSWORD` 只在首次启动（无用户文件时）生效。
>
> `AUTH_GATE_VERSION` 只在卷内没有 profile 时生效。要强制重播种：
> ```bash
> docker exec qxdho-dsh rm -rf /home/node/.dsh/profiles/web && ./dshm restart
> ```

## 常用命令

命令按分组组织（`dshm help` 看全部）：

```bash
# 服务
./dshm service up          # 启动 / 应用 .env 改动
./dshm service restart     # 重启
./dshm service down        # 停止（数据保留）
./dshm service status      # 健康 / 端口 / 登录用户
./dshm service logs        # 日志
./dshm service shell       # 进容器
./dshm service update      # 升级 dsh
./dshm service disk        # 磁盘占用（装插件写满磁盘时用）

# 登录与账号
./dshm auth password       # 改登录密码
./dshm auth user add 张三   # 新建用户
./dshm auth totp enable    # 开启两步验证

# 管理面板 / 自身
./dshm admin install       # 安装 Docker 管理面板（宿主机进程）
./dshm self install        # 把 dshm 注册为系统命令（之后任意目录直接用 dshm）
```

> 旧的扁平写法（`./dshm up`、`./dshm pw`、`./dshm user add …`）仍然可用，方便已有脚本。

## 管理面板

`./dshm admin install` 装一个 Docker 管理面板：容器状态、启动/停止/重启、日志、
磁盘占用、一键清理，以及一个跑 `dshm` 命令的命令台。

面板是**宿主机上的一个进程，不额外起容器**，所以 dsh 容器始终碰不到 `docker.sock`：

- 有 root / 可 sudo：装到 `/usr/local/bin` + `/etc/dsh-admin`，用 systemd 常驻、开机自启；
- **没有 root 也能用**：装到 `~/.local/bin` + `~/.config/dsh-admin`，用 pidfile 后台运行
  （不会随开机自启，需要就自己加 crontab）。

```bash
./dshm admin install            # 安装（不需要 sudo 也能装）
./dshm admin url                # 地址（默认 http://127.0.0.1:3090/）
./dshm admin password           # 改面板密码
./dshm admin status | logs
./dshm admin uninstall          # 停止并移除
```

远程访问用 SSH 隧道：`ssh -L 3090:127.0.0.1:3090 user@服务器`，或放到 HTTPS 反代后面。

> ⚠️ 面板持有 `docker.sock`，等于宿主 root。默认只监听 `127.0.0.1`，**不要直接暴露到公网**。
> 面板只调固定几个 Docker Engine 接口（不做任意透传），独立密码 + 会话 cookie（`HttpOnly`、
> `SameSite=Strict`）、写操作要求自定义头防 CSRF。

二进制从 GitHub Releases 下载，也可本机 `go build`（`admin/` 目录，仅标准库、零运行时依赖）。

### 面板里能做什么

- 状态卡（状态/健康/镜像版本/重启次数/端口）、启动/停止/重启、日志、磁盘占用、一键清理缓存。
- **命令台**：在页面里直接跑 `dshm` 命令（`service status`、`auth user list`、`service update 0.1.8`…），
  等价于在服务器上执行。

### 命令台是怎么保证安全的

它不是自由 shell：

- 输入先被拆成**参数数组**，再用 `exec` 直接调用项目里的 `dshm`，**不经过 `sh -c`**，
  所以 `;`、`|`、`` ` ``、`$( )` 都只是普通字符，不构成命令拼接；
- 命令路径必须命中白名单（`service/auth/self/admin` 下的安全子命令）；
- 需要交互输入的命令（`service shell`、`auth password`、`auth user add`…）会被明确拒绝，
  不会让你干等；
- 仍然要求登录 + `X-DSH-Admin` 头。

> ⚠️ 但要想清楚：面板本来就持有 `docker.sock`（等于宿主 root），命令台只是把"顺手提权"的
> 门槛又降低了一点。请务必只监听 `127.0.0.1`、用强密码；不需要命令台就在
> `admin/config.json` 里把 `allow_exec` 改成 `false` 并重启面板。

### 数据 / 挂载

| 容器路径 | 类型 | 宿主机位置 |
|---|---|---|
| dsh `/home/node/.dsh` | 命名卷 `dsh-home` | `/var/lib/docker/volumes/<项目名>_dsh-home/_data` |
| dsh `/workspace` | bind | `<项目目录>/workspace`（可用 `DSH_WORKSPACE` 改） |

面板跑在宿主机上，不占容器的挂载；它的配置在 `/etc/dsh-admin/config.json`
（无 root 时 `~/.config/dsh-admin/config.json`），其中 `allow_exec` 控制命令台开关。

## 界面重启

页面右下角有一个悬浮的「重启 DSH」按钮：**装/更新插件后点一下即可**，不用回命令行。

- 等价于 `./dshm restart`：容器会重建，约十几秒，页面自动刷新回来。
- 鉴权复用登录插件：代理拿浏览器的 Cookie 去问 dsh 的 `/`，只有已登录（200）才允许；
  未登录 401。接口还要求自定义头 `X-DSH-Restart: 1`，跨站请求带不了它（防 CSRF）。
- 依赖 compose 里的 `restart: unless-stopped`（本仓库默认）。若改成 `restart: "no"`，
  点按钮会变成"停止"而不是重启。
- 不想要这个按钮：删掉 `proxy/index.js` 中 `dsh-restart-button` 那段注入再重建镜像。

## HTTPS

在宿主机加一层反代指向 `127.0.0.1:3080`（Nginx / 宝塔 / Cloudflare），开启 **WebSocket 转发**。
启用 HTTPS 后把 `DSH_COOKIE_SECURE` 设为 `1`。

## 数据

dsh 把所有用户数据放在**一个根目录**里（上游叫 `DSH_HOME`，默认 `~/.dsh`）。本项目默认:

```
容器内 /home/node/.dsh  ←  命名卷 dsh-home  ←  宿主 /var/lib/docker/volumes/<项目名>_dsh-home/_data
```

`DSH_HOME` 就是**根目录本身**，不会再拼一层 `.dsh`（`DSH_HOME=/data` 的话数据直接摊在 `/data` 下）。
想换容器内路径，在 `.env` 里改，然后 `./dshm service up`：

```bash
DSH_HOME=/data/.dsh        # 数据出现在 /data/.dsh 下
```

> 自定义路径时镜像里没有那个目录，命名卷首次使用会是 root 属主；预检会先用
> `docker compose create` 把卷物化出来再修属主，所以照常 `./dshm service up` 即可。

### DSH_HOME 里都有什么

| 路径 | 作用 |
|---|---|
| `settings.yaml` | 界面设置：默认模型、UI 偏好 |
| `.credentials.yaml` | 模型 API Key 等凭据 + 会话 cookie 的签名密钥（动它会让所有人重新登录） |
| `.anonymous-user-id` | 匿名使用统计的稳定 ID |
| `profiles/` | profile（`web` 等）：`cordis.yml`、`cordis.patch.yml`、`package.json`、`node_modules`（插件装在这里） |
| `sessions/` | 会话记录（按工作区分目录） |
| `storages/` | 插件 / 工具的状态存储 |
| `attachments/` | 上传的附件 |
| `llm-deepseek/` | DeepSeek provider 的本地状态 / 缓存 |
| `home/` | 给工具用的 HOME 占位目录 |
| `workspace/` | 工作区降级目录（宿主 `/workspace` 不可写时才用） |

**备份就备份整个 `dsh-home` 卷**：登录用户、会话、插件、凭据都在里面。

重建容器不丢，不用重新登录。**不要用 `docker compose down -v`**（会删卷）。

## 工作区权限

`./workspace` 以 bind mount 挂到 `/workspace`，**会遮蔽镜像里的属主**，所以该目录必须让
容器内的 uid（默认 1000）能写。否则 agent 报：

```
EACCES: permission denied, mkdir '/workspace/xxx'
```

`./install.sh` 与 `./dshm up` 会在启动前按容器 uid 检查并自动修正（root 或免密 sudo 时）；
修正不了会报错并给出命令。直接 `docker compose up -d` 时容器自己也会查：**不可写不退出**，
而是降级到 `$DSH_HOME/workspace` 继续启动（避免 `restart: unless-stopped` 造成无限重启），
日志里打横幅。要恢复「不可写就退出」设 `DSH_WORKSPACE_STRICT=1`。

手工修复：

```bash
sudo chown -R 1000:1000 ./workspace && ./dshm up

# 或换成你自己的目录（不需要 sudo）
mkdir -p ~/dsh-workspace
echo 'DSH_WORKSPACE=~/dsh-workspace' >> .env
./dshm up
```

**宿主 uid 不是 1000**（macOS Docker Desktop、群晖等）：`.env` 里设

```bash
DSH_UID=1001          # id -u
DSH_GID=1001          # id -g
```

容器即以你的身份运行，bind mount 属主天然匹配。`./dshm up` 会用一次性 root 容器把
`dsh-home` 卷的属主也改成同一 uid（幂等）。改这两个值后必须 `./dshm up`。

## 常见问题

**页面打不开** → `./dshm logs`。首次启动约十几秒。

**docker 一直重启** → 宿主工作区属主不对，日志含 `/workspace 不可写`。见「工作区权限」。

**代理一直报 `socket hang up`，日志含 `disabling profile plugin row "storage-domain"`** →
卷里的 profile 是旧镜像播种的，缺 peer 软链。新版 entrypoint 每次启动会自动补齐（无需处理）；
旧镜像上强制重播种一次即可：

```bash
docker exec qxdho-dsh rm -rf /home/node/.dsh/profiles/web && ./dshm up
```

**装了插件后崩了 / 代理刷 `ECONNREFUSED` / 日志含 `No space left on device`** → 磁盘被插件依赖
和 npm 缓存写满了。满了之后 dsh 起来也会退出，代理只会刷连接被拒。看占用并清理：

```bash
./dshm disk                                                   # 宿主 + 卷 + 最占空间的目录
docker exec qxdho-dsh rm -rf /home/node/.dsh/.npm /tmp/npm-cache
docker image prune -a && docker builder prune                 # 宿主上的镜像/构建缓存
```

新版已把插件安装的 npm 缓存移到 `/tmp/npm-cache`（不写持久卷）并在每次启动清掉，启动时也会
检查剩余空间并给出提示；但根治仍是给 Docker 数据目录留足磁盘。

**密码对但弹回登录页** → `DSH_COOKIE_SECURE=1` 却在用 HTTP，改回 `0`。

**旧版本升级** → 容器名已从 `dsh` 改为 `qxdho-dsh`，先清理旧容器：

```bash
docker rm -f dsh && ./dshm up
```

## 第三方组件

- [`dsh-auth-gate`](https://github.com/TecFancy/dsh-auth-gate)（MIT，v0.15.0）——登录页、会话、TOTP、限速、token→Cookie 桥接
- `http-proxy`（MIT）、`tini`、`pnpm`、`node:24-bookworm-slim`

## 许可证

MIT。DeepSeek Harness 与 `dsh-auth-gate` 按各自许可单独授权。
