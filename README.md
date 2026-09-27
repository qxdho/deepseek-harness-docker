# dsh 一键部署镜像

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（dsh）网页版打包成
一条命令部署、自带登录的 Docker 服务。浏览器打开就能用，只有你能进。

> 非官方社区项目。dsh 处于预发布阶段，见 [SECURITY.md](SECURITY.md)。

## 快速开始

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
./install.sh          # 只问一次登录密码
```

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
./dshm logs           # 日志
./dshm up             # 启动 / 应用 .env 改动
./dshm restart        # 重启
./dshm down           # 停止（数据保留）
./dshm pw             # 改登录密码
./dshm user add 张三   # 新建用户
./dshm totp enable    # 开启两步验证
./dshm update         # 升级 dsh
./dshm shell          # 进容器
```

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
