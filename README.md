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
监听地址、工作区、两步验证、API Key）。非交互场景（CI/管道）不会卡住：缺失的必填项直接报错，
有默认值的用默认值。想改已有配置就编辑 `.env`。

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

```bash
./dshm                # 全部命令
./dshm status         # 健康 / 端口 / 登录用户
./dshm disk           # 磁盘占用（装插件写满磁盘时用）
./dshm logs           # 日志
./dshm up             # 启动 / 应用 .env 改动
./dshm restart        # 重启
./dshm down           # 停止（数据保留）
./dshm pw             # 改登录密码
./dshm user add 张三   # 新建用户
./dshm totp enable    # 开启两步验证
./dshm update         # 升级 dsh
./dshm shell          # 进容器
./dshm install-self   # 把 dshm 注册为系统命令（之后任意目录直接用 dshm）
./dshm admin install  # 安装 Docker 管理面板（宿主 / 容器二选一）
```

## 管理面板

`./dshm admin install` 装一个独立的 Docker 管理面板：容器状态、启动/停止/重启、日志、
磁盘占用与一键清理。安装时可选择形态：

| | 宿主（推荐） | 容器 |
|---|---|---|
| 权限边界 | **只有宿主进程持有 docker.sock，任何容器都碰不到** | 只有 `qxdho-admin` 容器挂 socket，dsh 容器不挂 |
| 依赖 | 单个静态二进制；有 systemd 用 systemd，没有就 pidfile | 免 root，随 compose 管理 |
| 适用 | 自己的 VPS / 有 root 或 sudo | 群晖、macOS、无 root、面板托管的环境 |

```bash
./dshm admin install            # 交互选择宿主 / 容器
./dshm admin install --host     # 直接指定
./dshm admin install --container
./dshm admin url                # 地址（默认 http://127.0.0.1:3090/）
./dshm admin password           # 改面板密码
./dshm admin status | logs
./dshm admin uninstall --host   # 卸载
```

远程访问用 SSH 隧道：`ssh -L 3090:127.0.0.1:3090 user@服务器`，或放到 HTTPS 反代后面。

> ⚠️ 面板持有 `docker.sock`，等于宿主 root。默认只监听 `127.0.0.1`，**不要直接暴露到公网**。
> 面板只调固定几个 Docker Engine 接口（不做任意透传），独立密码 + 会话 cookie（`HttpOnly`、
> `SameSite=Strict`）、写操作要求自定义头防 CSRF。

宿主二进制从 GitHub Releases 下载，也可本机 `go build`（`admin/` 目录，仅标准库、零运行时依赖）。

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

| 位置 | 内容 |
|---|---|
| 命名卷 `dsh-home` | 配置、模型凭据、会话、登录用户 |
| `./workspace` | agent 工作文件 |

重建容器不丢，不用重新登录。**不要用 `docker compose down -v`**（会删卷）。

卷的实际位置：`/var/lib/docker/volumes/<项目名>_dsh-home/_data`。

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
