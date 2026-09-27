# dsh 一键部署镜像

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh`）的
Web 界面打包成一个**可直接部署、自带登录**的 Docker 服务。你只需要一条命令，就能在服务器或 NAS 上
拥有一个**只有你能进**的 AI 编程 Agent 网页界面。

> 非官方社区项目。dsh 仍处于预发布阶段，请阅读 [SECURITY.md](SECURITY.md)。

---

## 这是什么

DeepSeek Harness（简称 dsh）是一个能在你机器上跑命令、读写文件、调用模型的 AI 编程 Agent。
官方的 Web 界面有几个"开箱即用"上的麻烦：

1. **只能监听本机回环**——官方故意拒绝 `--host 0.0.0.0`，所以没法直接对外访问；
2. **启动 token 很烦**——每次启动打印一串带 token 的网址，要手动复制才能登录；
3. **没有登录功能**——谁连上谁能用，而它能执行命令，风险很高；
4. **局域网 IP 访问会坏**——浏览器安全上下文限制导致前端报错、设置页不可用。

**这个项目就是把这四个问题一次性解决掉**，让你 clone 下来跑一条命令就能用。

---

## 能干什么（功能总览）

| 功能 | 说明 |
|---|---|
| 🔐 **登录门禁** | 用户名 + 密码登录页，可选两步验证（TOTP），带登录限速与防爆破 |
| 🙈 **不用再贴 token** | dsh 的一次性启动 token 由登录插件在容器内自动换成会话 Cookie，用户永远看不到 |
| 🚀 **一条命令部署** | `./install.sh` 只问一次密码，其余全自动（写配置、拉镜像/构建、启动、等健康） |
| 🌐 **局域网/域名可正常用** | 自动修复 `crypto.randomUUID` 缺失和"设置页不可用"的前端限制 |
| 💾 **数据持久化** | 配置、模型凭据、会话、登录用户都在数据卷里，重建容器不丢、不用重新登录 |
| 🛠️ **管理命令** | `./dshctl` 一键 up/down/logs/status/改密码/升级 |
| ⬆️ **自更新** | 宿主侧 `./dshctl update` 或容器内 `dsh-update`，两条升级路径 |
| 🛡️ **安全加固** | 非 root、`cap_drop: ALL`、`no-new-privileges`、文件沙箱 `workspace-write`（Landlock） |
| 🤖 **内置 agent 工具链** | git、ripgrep、jq、curl、rsync 等常用命令开箱可用 |
| 🏗️ **自动构建** | GitHub Actions 构建 amd64 + arm64 镜像并推送 GHCR，并跑真实容器冒烟测试 |
| 🔒 **配合宿主机 HTTPS** | Docker 内不做 TLS，交给你宿主机已有的反代（Nginx/宝塔/Cloudflare） |

**它不是什么**：不是多租户平台（不隔离多个不信任的用户）、不是官方产品、不内置 TLS 证书。

---

## 30 秒开始

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
./install.sh
```

`install.sh` 会：生成 `.env` → **问你一次登录密码** → 拉取 GHCR 镜像（拉不到就本地构建）→ 启动 →
等待健康 → 打印访问地址。

然后浏览器打开 `http://<服务器IP>:3080/`，用 `admin` + 你的密码登录。

> 默认只绑定 `127.0.0.1`（配合宿主机反代）。想先用 IP 直接访问，在 `.env` 里设 `DSH_BIND=0.0.0.0` 再跑一次。

---

## 功能详解

### 1. 登录门禁：终于不用再复制 token

dsh 原生流程是：启动时生成一个一次性 token，打印成 `http://.../?token=xxx`，你要复制它访问一次才能
换来会话 Cookie。

本镜像内置 [`dsh-auth-gate`](https://github.com/TecFancy/dsh-auth-gate) 插件：

- 你看到的是**正常的登录页**（用户名 + 密码）；
- 登录成功后，插件**自动**在容器内部完成 token → Cookie 的交换，你完全看不到 token；
- 可选 **TOTP 两步验证**（`off` / `optional` / `required` 三档）；
- 带**登录限速**（连续输错会临时锁定来源）和**防重放**；
- 设置页里有**退出登录**和**自助改密码**；
- 提供用户管理命令（增删用户、改密、启用/禁用 TOTP）。

> 单实例多账号可以，但**不是多租户隔离**——所有账号共享同一个 dsh 实例和文件系统。

### 2. 一条命令部署

`./install.sh` 把"看文档、改配置、构建、启动、检查"压成了**输入一次密码**。
它还会在拉不到镜像时**自动回退到本地构建**，所以你即使不把 GHCR 包设为公开也能部署。

### 3. 局域网 / 域名访问修复

直接访问 dsh 时，非 localhost 的页面会遇到两个前端限制：

- `crypto.randomUUID` 在浏览器**非安全上下文**（普通 HTTP + 局域网 IP）里不存在，导致实时通道挂起；
- 客户端 `isLoopback` 判定为假，**设置页无法编辑**。

本镜像的代理会往页面注入一小段脚本解决这两点，所以**用局域网 IP 或域名访问也功能完整**。

### 4. 数据持久化

| 容器内路径 | 内容 | 存储 |
|---|---|---|
| `/home/node/.dsh` | dsh 配置、模型凭据、会话记录、登录用户、Cookie 签名密钥 | 命名卷 `dsh-home` |
| `/workspace` | agent 的工作目录 | 宿主目录 `./workspace` |

**重建/升级容器都不会丢**，登录状态也保持。

### 5. 管理与自更新

`./dshctl` 是宿主侧管理命令：

```bash
./dshctl up [--build]   # 启动 / 本地构建后启动
./dshctl down           # 停止（保留数据卷）
./dshctl restart        # 重启
./dshctl logs           # 跟随日志
./dshctl status         # 健康 / 端口 / 登录用户
./dshctl url            # 打印一次性 launch URL（排障用）
./dshctl shell          # 进容器
./dshctl password       # 交互式改登录密码
./dshctl update [版本]   # 升级 dsh 并重建
./dshctl version        # 显示容器内 dsh 版本
```

两条升级路径：
- **宿主侧**（可复现，推荐）：`./dshctl update` 改版本号并重建；
- **容器内**（快）：`docker exec -it dsh dsh-update`，写入持久化目录，重启生效。

### 6. 安全加固

- 容器以**非 root**（uid 1000）运行；
- `cap_drop: ALL` + `no-new-privileges:true`；
- dsh 只监听容器回环，**唯一对外监听是代理**；
- 文件沙箱默认 `workspace-write`（Linux 上由 **Landlock** 强制，不需要额外权限）；
- 不挂载 Docker socket、宿主根目录等敏感路径。

> 安全沙箱能减少 Agent 自己犯错的代价，但**不是**对抗恶意代码的隔离边界。详见 [SECURITY.md](SECURITY.md)。

### 7. 自动构建与验证

`.github/workflows/build.yml`：每次推送都会

- 构建 **linux/amd64 + linux/arm64** 多架构镜像并推送到 GHCR；
- 单独起一个真实容器跑**冒烟测试**（健康、未登录跳转、登录闭环、会话保持、代理注入、未认证 API 拒绝）。

### 8. 内置 agent 工具链

镜像里预装了 `git`、`ripgrep`、`jq`、`curl`、`rsync`、`sqlite3`、`python3` 等常用命令，以及 `pnpm`。
需要更完整的编译环境（给带原生依赖的插件用）时，用 `DEV_TOOLS=full` 重新构建。

---

## 架构

```
浏览器
  │  http://<服务器IP>:3080  或  https://你的域名（宿主机反代终结 TLS）
  ▼
代理（容器内 0.0.0.0:3080，Node 实现）
  │  ① Host/Origin 一致改写为 127.0.0.1:3079
  │  ② 往 HTML 注入 crypto.randomUUID 补丁 + __DSH_TRANSPORT__.ownsHost
  ▼
dsh（127.0.0.1:3079，只监听回环）
  └─ web profile + dsh-auth-gate 插件
        负责登录 / 会话 / TOTP / launch token 自动桥接
```

设计要点：

- **代理不做鉴权**，鉴权在插件里；
- **代理不改 dsh 任何文件**，所以 dsh 升级不会让它失效；
- 因为 Host 被一致改写成回环，**不需要配置 `--trusted-host`**。

---

## 配置项

全部在 `.env`。改完 `./dshctl restart` 生效；标 **构建期** 的要重新构建（`./install.sh`）。
模板见 [.env.example](.env.example)。

### 部署与镜像（构建期）

| 变量 | 默认 | 作用 | 什么时候改 |
|---|---|---|---|
| `DSH_IMAGE` | `ghcr.io/qxdho/deepseek-harness-docker:latest` | 用哪个镜像启动 | 想用本地构建的镜像 |
| `DSH_VERSION` | `0.1.7-rc.2` | 镜像内置的 dsh 版本 | 想升级/固定 dsh |
| `AUTH_GATE_VERSION` | `0.15.0` | 登录插件版本 | 插件升级 |
| `DEV_TOOLS` | `none` | `full` 额外装 `python3/make/g++`，供容器内装带原生依赖的插件 | 要装复杂插件 |

### 网络与入口（运行期）

| 变量 | 默认 | 作用 | 什么时候改 |
|---|---|---|---|
| `PROXY_PORT` | `3080` | 宿主机端口 | 端口冲突 |
| `DSH_BIND` | `127.0.0.1` | `127.0.0.1` 只宿主机可访问（配合反代）；`0.0.0.0` 局域网可直连 | 想先用 IP 测试 |
| `DSH_WORKSPACE` | `./workspace` | agent 的工作目录 | 让它读写你的项目 |

### 登录与安全（运行期）

| 变量 | 默认 | 作用 | 什么时候改 |
|---|---|---|---|
| `DSH_AUTH_USER` | `admin` | 管理员用户名（只在**首次建号**时生效） | 首次启动前改 |
| `DSH_AUTH_PASSWORD` | 无（**必填**） | 首次启动用它建号 | `install.sh` 会问；之后 `./dshctl password` |
| `DSH_TOTP` | `optional` | `off` / `optional` / `required` | 想强制两步验证设 `required` |
| `DSH_COOKIE_SECURE` | `0` | 设 `1` 会话 Cookie 带 `Secure` | **可选**：走 HTTPS 建议设 1；纯 HTTP 必须保持 0 |
| `DSH_PUBLIC_HOST` | 空 | 登录页显示的域名 | **可选**：用域名访问时填 |

### 容器内进阶项（默认已设好，一般不用动）

在 `docker-compose.yml` 的 `environment:` 里覆盖：

| 变量 | 默认 | 作用 |
|---|---|---|
| `DSH_PERMISSION_MODE` | `workspace-write` | 文件沙箱：`read-only` / `workspace-write` / `danger-full-access` |
| `DSH_TELEMETRY_DISABLED` | `1` | 关闭遥测 |
| `DSH_PORT` | `3079` | dsh 在容器内监听的回环端口 |
| `NARB_DISABLE_NATIVE_CACHE` | `1` | 避免原生插件缓存落到 `noexec` 的 `/tmp` |

---

## HTTPS

**不需要在 Docker 里做，也不用额外配置。** 在宿主机上加一层 TLS 反代（Nginx、宝塔、Cloudflare 等），
指向 `127.0.0.1:3080` 即可。

反代需要**转发 WebSocket**（dsh 的实时通道要用）：

```nginx
location / {
    proxy_pass http://127.0.0.1:3080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;   # SSE / 长连接
    proxy_buffering off;
}
```

上了 HTTPS 后，**可选**（非必须）设置：

```ini
DSH_COOKIE_SECURE=1                 # 会话 Cookie 带 Secure，更安全
DSH_PUBLIC_HOST=dsh.example.com     # 登录页显示你的域名
```

> 唯一要记住的相反情况：**用 HTTP 访问时 `DSH_COOKIE_SECURE` 必须是 `0`**（默认就是 `0`），
> 否则浏览器会拒收 `Secure` Cookie，表现为"密码对但一直弹回登录页"。

---

## 目录结构

```
install.sh               一条命令部署
dshctl                   宿主侧管理命令
Dockerfile               多阶段构建：装 dsh + 预置登录插件 profile + 代理
docker-compose.yml       服务定义（镜像、端口、环境变量、卷、权限）
entrypoint.sh            启动脚本：播种 profile、建管理员、起 dsh 与代理
proxy/index.js           对外代理：转发 + Host/Origin 改写 + HTML 注入
scripts/dsh-wrapper.sh   dsh 启动包装（补 --expose-internals）
scripts/healthcheck.sh   容器健康检查
scripts/dsh-update       容器内自更新
scripts/smoke-test.sh    冒烟测试（CI 与本地都可用）
.github/workflows/       多架构构建 + GHCR 推送 + 冒烟测试
README.md / README.en.md 文档
SECURITY.md              安全模型
DESIGN.md                设计决策与验证记录
```

---

## 常见问题

**Q：`install.sh` 会问我什么？**
只问一次登录密码（`.env` 里已有密码就不问）。其他全部自动。

**Q：页面打不开 / 502？**
`./dshctl logs` 看日志。首次启动要装/初始化，可能 1–2 分钟。另外确认 `DSH_BIND`：默认 `127.0.0.1`
只有宿主机能访问。

**Q：密码没错但一直弹回登录页？**
多半是 `DSH_COOKIE_SECURE=1` 却在用 HTTP 访问。改成 `0`，或真的上 HTTPS。
（浏览器 F12 → Cookies 里看不到 `dsh_auth` 即是此因；curl 测不出来。）

**Q：设置页显示不可用？**
正常不会。若出现，说明代理注入没生效，检查容器里 `proxy/index.js` 是否在跑。

**Q：怎么改登录密码？**
`./dshctl password admin`。

**Q：怎么开启两步验证？**
```bash
docker exec -it dsh node /home/node/.dsh/profiles/web/node_modules/dsh-auth-gate/lib/cli.js \
  user totp enable admin
```
按提示把 `otpauth://` 导入验证器应用。

**Q：怎么升级 dsh？**
`./dshctl update`（宿主侧，推荐）或 `docker exec -it dsh dsh-update`（容器内）。

**Q：不把它放在公网可以吗？**
可以。默认只绑 `127.0.0.1`，本机或 SSH 隧道访问都行。

---

## 许可证

MIT。DeepSeek Harness 与其插件按其各自许可单独授权。
