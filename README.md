# dsh 一键部署镜像

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（dsh）的网页版，打包成
**一条命令部署、自带登录**的 Docker 服务。浏览器打开就能用，而且只有你能进。

> 非官方社区项目。dsh 仍处于预发布阶段，详见 [SECURITY.md](SECURITY.md)。

---

## 快速开始

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
./install.sh          # 只问你一次登录密码
```

然后浏览器打开 `http://<服务器IP>:3080/`，用 `admin` + 你的密码登录。

登录后第一件事：**配置模型**——在网页「设置 → 模型」里填 DeepSeek API Key，
或者直接在 `.env` 里加一行 `DEEPSEEK_API_KEY=sk-...` 再 `./dshm restart`。

> 默认只绑 `127.0.0.1`（给宿主机反代用）。想先用 IP 直接访问：把 `.env` 的 `DSH_BIND` 改成 `0.0.0.0`，再跑一次 `./install.sh`。

---

## 它解决什么问题

dsh 是能在你机器上执行命令、读写文件的 AI 编程 Agent。官方版直接放服务器上有三个麻烦，本项目都解决了：

| 官方的问题 | 本项目 |
|---|---|
| 只能监听本机，没法对外访问 | 加一层代理对外，dsh 仍只监听回环 |
| 每次启动要手动复制带 token 的网址 | 登录插件在容器内自动把 token 换成 Cookie，你看不到 token |
| 没有登录功能，谁连上谁能用 | 加登录页 + 密码 + 可选两步验证（TOTP） |

---

## 和官方 dsh 的区别

| | 官方 dsh | 本项目 |
|---|---|---|
| 部署 | npm 命令行，无 Docker 方案 | Docker 镜像，一条命令 |
| 认证 | 一次性 token，没有登录页/用户/TOTP | 登录页 + 密码 + 可选 TOTP + 限速 |
| 对外访问 | 只允许本机 | 代理对外，dsh 保持回环 |
| 局域网/域名 | 设置页不可用、前端报错 | 已修复 |
| 加固 | 有沙箱，需自行配置 | 预设非 root / 最小权限 / workspace-write |

**本项目不改 dsh 源码**，只用它官方的扩展机制。

```
浏览器 → 代理(0.0.0.0:3080) → dsh(127.0.0.1:3079，带登录插件)
```

---

## 用到的第三方组件

- **`dsh-auth-gate`**（[TecFancy](https://github.com/TecFancy/dsh-auth-gate)，MIT，v0.15.0）：
  登录页、会话、TOTP、登录限速、用户管理、以及 token → Cookie 的自动桥接。
  **"登录"和"不用贴 token"这两个体验是它提供的。**
- `http-proxy`（MIT）：转发代理；`tini`：容器 init；`pnpm`：装插件；`node:24-bookworm-slim`：基础镜像。

**本项目在这些之上做的**：对外代理与 Host/Origin 改写（因此不用配 `--trusted-host`）、
前端兼容注入（修复 `randomUUID` 与"设置页不可用"）、镜像构建与首启初始化、
`--expose-internals` 启动包装、加固默认值、`install.sh` / `dshm` / 健康检查 / 冒烟测试、CI 构建与发布、文档。

---

## 配置项

全部在 `.env`。**改完运行 `./dshm restart` 生效。**

**你会用到的：**

| 变量 | 默认 | 说明 |
|---|---|---|
| `DSH_AUTH_PASSWORD` | 无（**必填**） | 首次启动建号用（**≥14 位且含大小写/数字/符号**）；之后改密码用 `./dshm password` |
| `PROXY_PORT` | `3080` | 宿主机端口 |
| `DSH_BIND` | `127.0.0.1` | `127.0.0.1`=只有宿主机能访问（配反代）；`0.0.0.0`=局域网可直连 |
| `DSH_WORKSPACE` | `./workspace` | agent 的工作目录 |
| `DSH_TOTP` | `optional` | 两步验证：`off` / `optional` / `required` |
| `DSH_COOKIE_SECURE` | `0` | **HTTP 必须 0**；上 HTTPS 建议改 `1` |
| `DSH_PUBLIC_HOST` | 空 | 登录页显示的域名（可选，不影响功能） |

**一般不用改的（构建期，改了要跑 `./install.sh` 重建）：**

| 变量 | 默认 | 说明 |
|---|---|---|
| `DSH_VERSION` | `0.1.7-rc.2` | 镜像内置的 dsh 版本 |
| `AUTH_GATE_VERSION` | `0.15.0` | 内置登录插件版本 |
| `DEV_TOOLS` | `none` | `full` 时额外装编译链，供容器内装带原生依赖的插件 |
| `DSH_IMAGE` | GHCR `latest` | 用哪个镜像启动 |

> ⚠️ `DSH_AUTH_USER` / `DSH_AUTH_PASSWORD` 只在**首次启动**（还没有用户文件时）生效；
> 之后改密码用 `./dshm password`。

---

## 常用命令

```bash
./install.sh          # 一条命令部署
./dshm                # 查看全部命令（帮助）
./dshm status         # 健康 / 端口 / 登录用户
./dshm logs           # 看日志
./dshm restart        # 重启
./dshm down           # 停止（数据保留）
./dshm pw             # 改登录密码（输入有星号）
./dshm user list      # 列出登录用户
./dshm user add 张三   # 新建用户
./dshm totp enable    # 开启两步验证
./dshm update         # 升级 dsh
./dshm shell          # 进容器
```

---

## HTTPS

**不用在 Docker 里配。** 宿主机加一层反代指向 `127.0.0.1:3080` 即可（Nginx / 宝塔 / Cloudflare 都行），
记得开启 **WebSocket 转发**。上了 HTTPS 后可把 `DSH_COOKIE_SECURE` 改成 `1`。

---

## 数据

| 位置 | 内容 |
|---|---|
| 命名卷 `dsh-home` | 配置、模型凭据、会话、登录用户 |
| `./workspace` | agent 的工作文件 |

重建容器不丢，也不用重新登录。

---

## 常见问题

**页面打不开？** `./dshm logs`。首次启动要 1–2 分钟。

**密码对但一直弹回登录页？** 多半是 `DSH_COOKIE_SECURE=1` 却在用 HTTP，改回 `0`。

**怎么改密码？** `./dshm password`

**怎么开两步验证？**
```bash
docker exec -it dsh node /home/node/.dsh/profiles/web/node_modules/dsh-auth-gate/lib/cli.js user totp enable admin
```

---

## 许可证

MIT。DeepSeek Harness 与 `dsh-auth-gate` 按其各自许可单独授权。
