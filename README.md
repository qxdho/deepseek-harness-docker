# dsh 一键部署镜像

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh`）的
Web 界面打包成一个**可直接部署、自带登录**的 Docker 服务。一条命令，就能在服务器或 NAS 上拥有一个
**只有你能进**的 AI 编程 Agent 网页界面。

> 非官方社区项目。dsh 仍处于预发布阶段，请阅读 [SECURITY.md](SECURITY.md)。

---

## 目录

- [一、这是什么](#一这是什么)
- [二、它解决什么问题](#二它解决什么问题)
- [三、与官方 dsh 的区别](#三与官方-dsh-的区别)
- [四、本项目做了什么（分层署名）](#四本项目做了什么分层署名)
- [五、功能一览](#五功能一览)
- [六、快速开始](#六快速开始)
- [七、架构](#七架构)
- [八、配置项详解](#八配置项详解)
- [九、数据持久化](#九数据持久化)
- [十、常用命令](#十常用命令)
- [十一、HTTPS](#十一https)
- [十二、升级](#十二升级)
- [十三、目录结构](#十三目录结构)
- [十四、常见问题](#十四常见问题)
- [十五、第三方组件与致谢](#十五第三方组件与致谢)
- [十六、许可证](#十六许可证)

---

## 一、这是什么

DeepSeek Harness（简称 dsh）是一个能在你机器上**执行命令、读写文件、调用模型**的 AI 编程 Agent。
本项目是它的**部署外壳**：把 dsh 的 Web 界面 + 一个登录门禁 + 一个对外代理，打包成单个 Docker 镜像，
让你能安全地在服务器上自托管它。

适用场景：个人或小团队、自有服务器/NAS、想用浏览器随时访问自己的 AI Agent。

---

## 二、它解决什么问题

dsh 官方版直接放服务器上会有四个麻烦：

| 官方 dsh 的问题 | 本项目怎么解决 |
|---|---|
| 1. **只能监听本机**：明确拒绝 `--host 0.0.0.0`，没法对外访问 | 容器内 dsh 保持回环，外面加一层代理对外 |
| 2. **启动 token 很烦**：每次打印带 token 的网址，要手动复制 | 登录插件在容器内部自动把它换成会话 Cookie，你永远看不到 |
| 3. **没有登录功能**：谁连上谁能用，而它能执行命令 | 内置登录页 + 密码 + 可选两步验证 + 限速 |
| 4. **局域网/域名访问会坏**：前端 `randomUUID` 缺失、设置页不可用 | 代理注入补丁修复，IP/域名访问功能完整 |

---

## 三、与官方 dsh 的区别

官方 `@deepseek-ai/dsh` 是**命令行工具**；本项目是它的**部署外壳，不改它的源码**，只用它官方的扩展机制
（profile bundle、`--patch`、`__DSH_TRANSPORT__` 注入口）。

| 能力 | 官方 dsh | 本项目 |
|---|---|---|
| 部署 | `npm i -g`、`npx`，无官方 Docker 方案 | Docker 镜像 + compose，`./install.sh` 一条命令 |
| 对外监听 | **只允许回环**，拒绝 `0.0.0.0` | 代理对外，dsh 仍只监听回环 |
| 认证 | 一次性 token 换签名 Cookie；**无登录页、无用户、无 TOTP** | 登录页 + 密码 + 可选 TOTP + 限速 + 用户管理（插件提供） |
| token 体验 | 手动复制启动 URL | 自动桥接，看不到 token |
| 局域网/域名 | 设置页不可用；非安全上下文缺 `randomUUID` | 注入补丁修复 |
| 加固默认值 | 有沙箱，但需自行配置 | 预设非 root / `cap_drop` / `workspace-write` |
| 升级 | `npm update -g` | `./dshctl update` 或容器内 `dsh-update` |
| 构建/发布 | 无 | 多架构构建 + GHCR + 真实容器冒烟测试 |

> 两者**互补**：dsh 提供 Agent 能力，本项目负责"把它安全地放到服务器上"。

---

## 四、本项目做了什么（分层署名）

- **官方 dsh 提供**：Agent 运行时、Web UI、一次性 token 认证、文件沙箱、插件机制。
- **`dsh-auth-gate` 插件提供**（第三方）：登录页、会话、TOTP、登录限速、用户管理 CLI、
  launch token → 会话 Cookie 的自动桥接。
- **本项目自己做的**：

  1. **对外代理层**：监听 `0.0.0.0`、转发 HTTP/WebSocket、把 `Host`/`Origin` **一致改写**为回环地址，
     因此**不需要配置 `--trusted-host`**；并纠正了上一版"改写 Host 会丢 Cookie"的错误论断（真实 dsh 实测推翻）。
  2. **前端兼容注入**：`crypto.randomUUID` 补丁 + `__DSH_TRANSPORT__.ownsHost`（插件明确不负责这块）。
  3. **镜像工程**：多阶段构建、预置带插件的 profile、空卷首启播种、首次启动建管理员、配置全部 `.env` 驱动。
  4. **dsh 启动 wrapper**：自动补 `--expose-internals`（不加则 `dsh web` 因 HMR 插件直接崩，实测坑）。
  5. **加固默认值**：非 root、`cap_drop: ALL`、`no-new-privileges`、`NARB_DISABLE_NATIVE_CACHE=1`、版本断言。
  6. **运维工具**：`install.sh`、`dshctl`、`dsh-update`、`healthcheck`、`smoke-test`。
  7. **CI**：多架构构建推 GHCR + 真实容器冒烟测试。
  8. **文档与实测**：`SECURITY.md` / `DESIGN.md`。

---

## 五、功能一览

| 功能 | 说明 |
|---|---|
| 🔐 登录门禁 | 用户名 + 密码，可选 TOTP 两步验证，登录限速 + 防爆破 |
| 🙈 不用贴 token | 启动 token 在容器内自动换成会话 Cookie |
| 🚀 一条命令部署 | `./install.sh` 只问一次密码 |
| 🌐 局域网/域名可用 | 修复 `randomUUID` 与"设置页不可用" |
| 💾 数据持久化 | 配置、凭据、会话、登录用户都在数据卷 |
| 🛠️ 管理命令 | `./dshctl` 管一切 |
| ⬆️ 自更新 | 宿主侧 / 容器内两条升级路径 |
| 🛡️ 安全加固 | 非 root、cap_drop、Landlock 沙箱 |
| 🤖 agent 工具链 | git、ripgrep、jq、curl、python3、pnpm |
| 🏗️ 自动构建 | amd64 + arm64 → GHCR，含冒烟测试 |
| 🔒 宿主机 HTTPS | Docker 内不做 TLS，交给你的反代 |

**不是**：不是多租户平台、不是官方产品、不内置 TLS 证书。

---

## 六、快速开始

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
./install.sh
```

`install.sh` 会：生成 `.env` → **问你一次登录密码** → 拉 GHCR 镜像（拉不到自动本地构建）→ 启动 →
等健康 → 打印地址。

然后浏览器打开 `http://<服务器IP>:3080/`，用 `admin` + 你的密码登录。

---

## 七、架构

```
浏览器
  │  http://<服务器IP>:3080  或  https://你的域名（宿主机反代终结 TLS）
  ▼
代理（容器内 0.0.0.0:3080，Node 实现）
  │  ① Host/Origin 一致改写为 127.0.0.1:3079
  │  ② 往 HTML 注入 crypto.randomUUID 补丁 + __DSH_TRANSPORT__.ownsHost
  ▼
dsh（127.0.0.1:3079，只监听回环）
  └─ web profile + dsh-auth-gate 插件（登录 / 会话 / TOTP / token 桥接）
```

代理**不做鉴权**、**不改 dsh 文件**；因为 Host 被一致改写成回环，所以不需要 `--trusted-host`。

---

## 八、配置项详解

所有运行配置都在 `.env`（由 `docker-compose.yml` 传给容器）。先记住一个规则：

- **运行期**配置：改 `.env` → `./dshctl restart` 生效。
- **构建期**配置：改 `.env` → `./install.sh`（重建）生效。

### 8.1 部署与镜像（构建期：改了要重建）

#### `DSH_IMAGE`
- **默认**：`ghcr.io/qxdho/deepseek-harness-docker:latest`
- **作用**：决定 `docker compose` 启动时用哪个镜像。
- **为什么有它**：默认用 CI 构建好的 GHCR 镜像（快）；想用本地构建的镜像时可以切换。
- **怎么改**：想强制用本地镜像 → 改成 `dsh-local:latest`，并先 `docker compose build`。

#### `DSH_VERSION`
- **默认**：`0.1.7-rc.2`
- **作用**：**本地构建镜像时**，往镜像里装哪个版本的 dsh。
- **为什么有它**：dsh 是预发布阶段的软件，版本变化快，需要能固定/升级。
- **怎么改**：想升级 dsh → 改成目标版本号，再 `./install.sh`。用预构建镜像时这个值不影响运行。
- **副作用**：dsh 大版本变化可能带来配置格式变化，升级前建议备份数据卷。

#### `AUTH_GATE_VERSION`
- **默认**：`0.15.0`
- **作用**：构建时内置的登录插件 `dsh-auth-gate` 版本。
- **为什么有它**：插件的兼容区间是 dsh `^0.1.0-rc.6 || ^0.1.5-rc.2 || ^0.1.7-alpha.1`；换到区间外的
  dsh 时要同步升级插件。
- **怎么改**：改版本号后 `./install.sh`。

#### `DEV_TOOLS`
- **默认**：`none`
- **作用**：控制运行镜像里是否额外安装编译工具链。
  - `none`：精简镜像（默认），日常使用足够。
  - `full`：额外装 `python3`、`make`、`g++`、`pkg-config`、`vim`、`less`，用于**在容器内**安装带原生依赖的插件。
- **为什么有它**：装某些插件需要现场编译原生模块（如 node-pty）；不需要就不必让镜像变大。
- **怎么改**：改成 `full` 后 `./install.sh`。

### 8.2 网络与入口（运行期：改完重启）

#### `PROXY_PORT`
- **默认**：`3080`
- **作用**：**宿主机**监听哪个端口，也就是你访问时用的端口。
- **为什么有它**：3080 被占用时需要换。
- **怎么改**：改成空闲端口，`./dshctl restart`。访问地址随之变化。

#### `DSH_BIND`
- **默认**：`127.0.0.1`
- **作用**：容器端口绑定到宿主机的哪个网卡。
  - `127.0.0.1`：**只有宿主机自己能访问**（安全，配合宿主机 HTTPS 反代）。
  - `0.0.0.0`：局域网内任何机器都能直连（方便测试，但没上 HTTPS 时是明文的）。
- **为什么有它**：很多部署在宿主机已有反代，容器不该直接暴露给整个网络。
- **怎么改**：想先用 IP 直连测试 → 改 `0.0.0.0`，`./dshctl restart`。

#### `DSH_WORKSPACE`
- **默认**：`./workspace`
- **作用**：宿主机的哪个目录作为 agent 的工作目录（挂到容器 `/workspace`）。Agent 读写文件默认在这里。
- **为什么有它**：不同人想让它操作不同项目目录。
- **怎么改**：改成绝对路径，如 `/data/projects/demo`，`./dshctl restart`。
- **注意**：需要容器用户（uid 1000）可写。

### 8.3 登录与安全（运行期：改完重启）

#### `DSH_AUTH_USER`
- **默认**：`admin`
- **作用**：管理员**用户名**。
- **重要**：**只在首次启动、还没有用户文件时生效**。之后改这个值不会重命名已有账号。
- **怎么改**：首次启动前设定；之后要加用户用插件 CLI（见第十四节）。

#### `DSH_AUTH_PASSWORD`
- **默认**：无（**必填**）
- **作用**：首次启动用它创建管理员账号的密码。
- **重要**：同样**只在首次启动生效**；之后改它不会改已有密码。
- **怎么改**：`install.sh` 会问你；之后改密码用 `./dshctl password admin`。

#### `DSH_TOTP`
- **默认**：`optional`
- **作用**：两步验证（TOTP）档位：
  - `off`：不启用两步验证。
  - `optional`：**绑定了 TOTP 的用户**登录时需要输验证码；没绑的不需要。
  - `required`：所有用户都必须绑定 TOTP 才能登录。
- **为什么有它**：公网部署时多一层保护。
- **怎么改**：改档位后 `./dshctl restart`；再用插件 CLI 给用户绑定 TOTP。

#### `DSH_COOKIE_SECURE`
- **默认**：`0`
- **作用**：登录会话 Cookie 是否带 `Secure` 属性（只在 HTTPS 下才允许传输）。
- **怎么选**：
  - 你**用 HTTP 访问** → 必须是 `0`（默认）。设成 `1` 会导致浏览器拒收 Cookie，表现为"密码对但一直弹回登录页"。
  - 你**用 HTTPS 访问** → 设 `1` 更安全（防止 Cookie 被 HTTP 端口带出去）；但设 `0` 也能正常登录。
- **为什么有它**：HTTP/HTTPS 两种部署方式对 Cookie 的要求相反，必须显式选择。
- **怎么改**：改完 `./dshctl restart`。

#### `DSH_PUBLIC_HOST`
- **默认**：空
- **作用**：登录页上显示的域名（用于防钓鱼，让用户确认"这是哪个实例"）。
- **为什么有它**：容器内代理会把 Host 改写成回环地址，所以不设的话登录页显示的是 `127.0.0.1:3079`，不好看也不利于确认。
- **怎么改**：填你的域名，如 `dsh.example.com`，`./dshctl restart`。**不影响功能**，纯显示。

### 8.4 容器内进阶项（默认已设好，一般不用动）

这些在 `docker-compose.yml` 的 `environment:` 里，需要时覆盖：

#### `DSH_PERMISSION_MODE`
- **默认**：`workspace-write`
- **作用**：Agent 的文件沙箱模式：
  - `read-only`：只读，写操作要审批。
  - `workspace-write`：只能在会话工作目录（和 `/tmp`）内写；越界需审批。**推荐**。
  - `danger-full-access`：无限制（审批也关闭）。只有当你把"容器本身"当作唯一安全边界时才用。
- **为什么有它**：dsh 能执行命令，收窄它的文件权限能降低误操作代价。

#### `DSH_TELEMETRY_DISABLED`
- **默认**：`1`，关闭遥测。

#### `DSH_PORT`
- **默认**：`3079`
- **作用**：dsh 在**容器内部**监听的回环端口，由代理转发。一般不需要改。

#### `NARB_DISABLE_NATIVE_CACHE`
- **默认**：`1`
- **作用**：禁止 dsh 把原生插件缓存到 `/tmp`（可能被挂成 `noexec` 而加载失败）。

### 8.5 配置速查表

| 变量 | 默认 | 生效方式 | 一句话作用 |
|---|---|---|---|
| `DSH_IMAGE` | GHCR latest | 重建 | 用哪个镜像 |
| `DSH_VERSION` | `0.1.7-rc.2` | 重建 | 镜像内置的 dsh 版本 |
| `AUTH_GATE_VERSION` | `0.15.0` | 重建 | 内置登录插件版本 |
| `DEV_TOOLS` | `none` | 重建 | 是否装编译工具链 |
| `PROXY_PORT` | `3080` | 重启 | 宿主机端口 |
| `DSH_BIND` | `127.0.0.1` | 重启 | 绑定网卡（对外可见性） |
| `DSH_WORKSPACE` | `./workspace` | 重启 | agent 工作目录 |
| `DSH_AUTH_USER` | `admin` | 仅首次 | 管理员用户名 |
| `DSH_AUTH_PASSWORD` | 必填 | 仅首次 | 管理员密码 |
| `DSH_TOTP` | `optional` | 重启 | 两步验证档位 |
| `DSH_COOKIE_SECURE` | `0` | 重启 | Cookie 是否要求 HTTPS |
| `DSH_PUBLIC_HOST` | 空 | 重启 | 登录页显示的域名 |
| `DSH_PERMISSION_MODE` | `workspace-write` | 重启 | 文件沙箱模式 |
| `DSH_TELEMETRY_DISABLED` | `1` | 重启 | 关遥测 |
| `DSH_PORT` | `3079` | 重启 | 容器内 dsh 端口 |
| `NARB_DISABLE_NATIVE_CACHE` | `1` | 重启 | 原生插件缓存开关 |

---

## 九、数据持久化

| 容器内路径 | 内容 | 存储 |
|---|---|---|
| `/home/node/.dsh` | dsh 配置、模型凭据、会话记录、登录用户、Cookie 签名密钥 | 命名卷 `dsh-home` |
| `/workspace` | agent 的工作目录 | 宿主目录 `./workspace` |

**重建/升级容器都不会丢，登录状态也保持。**

---

## 十、常用命令

```bash
./install.sh            # 一条命令部署
./dshctl up [--build]   # 启动 / 本地构建后启动
./dshctl down           # 停止（保留数据卷）
./dshctl restart        # 重启
./dshctl logs           # 跟随日志
./dshctl status         # 健康 / 端口 / 登录用户
./dshctl url            # 打印一次性 launch URL（排障）
./dshctl shell          # 进容器
./dshctl password       # 交互式改登录密码
./dshctl update [版本]   # 升级 dsh 并重建
./dshctl version        # 显示容器内 dsh 版本
```

---

## 十一、HTTPS

**不需要在 Docker 里做，也不用额外配置。** 在宿主机加一层 TLS 反代（Nginx、宝塔、Cloudflare 等），
指向 `127.0.0.1:3080` 即可。反代需要**转发 WebSocket**：

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

上了 HTTPS 后，**可选**设置 `DSH_COOKIE_SECURE=1`（更安全）和 `DSH_PUBLIC_HOST=你的域名`（登录页显示）。

> 记住反向规则：**用 HTTP 访问时 `DSH_COOKIE_SECURE` 必须是 `0`**（默认就是 `0`）。

---

## 十二、升级

```bash
# 宿主侧（推荐，可复现）
./dshctl update
./dshctl update 0.1.7-rc.2

# 容器内（快，写入持久化目录，重建容器也不丢）
docker exec -it dsh dsh-update
./dshctl restart
```

升级前建议备份 `dsh-home` 卷（dsh 大版本可能改数据格式）。

---

## 十三、目录结构

```
install.sh               一条命令部署
dshctl                   宿主侧管理命令
Dockerfile               多阶段构建：dsh + 预置插件 profile + 代理
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

## 十四、常见问题

**Q：`install.sh` 会问我什么？**
只问一次登录密码（`.env` 里已有密码就不问）。

**Q：页面打不开 / 502？**
`./dshctl logs` 看日志。首次启动要初始化，可能 1–2 分钟。确认 `DSH_BIND`（默认 `127.0.0.1` 只有宿主机能访问）。

**Q：密码没错但一直弹回登录页？**
多半是 `DSH_COOKIE_SECURE=1` 却在用 HTTP 访问。改成 `0`，或真的上 HTTPS。
（浏览器 F12 → Cookies 看不到 `dsh_auth` 即是此因；curl 测不出来。）

**Q：怎么改登录密码？** `./dshctl password admin`

**Q：怎么加用户 / 开两步验证？**
```bash
docker exec -it dsh node /home/node/.dsh/profiles/web/node_modules/dsh-auth-gate/lib/cli.js user add 用户名 --password-stdin
docker exec -it dsh node /home/node/.dsh/profiles/web/node_modules/dsh-auth-gate/lib/cli.js user totp enable admin
```

**Q：设置页显示不可用？**
正常不会。若出现，检查容器里 `proxy/index.js` 是否在运行。

---

## 十五、第三方组件与致谢

本项目**大量依赖他人成果**，特此说明：

| 组件 | 来源 | 许可 | 在本项目里的作用 |
|---|---|---|---|
| `@deepseek-ai/dsh` | [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) | 见上游 | 本体：Agent 运行时 + Web UI |
| **`dsh-auth-gate`** | [TecFancy/dsh-auth-gate](https://github.com/TecFancy/dsh-auth-gate)（npm `0.15.0`） | MIT | **登录页、会话、TOTP、限速、用户 CLI、token 桥接** |
| `http-proxy` | http-party | MIT | 对外转发代理 |
| `tini` | krallin | MIT | 容器 init |
| `pnpm` | pnpm | MIT | 装/管插件 |
| `node:24-bookworm-slim` | Node 官方镜像 | 见上游 | 基础镜像 |

**本项目没有修改以上任何组件的源码**（唯一一处是对 dsh 客户端做运行时页面注入，不改文件）。

设计参考的社区项目：[Xidong-AI](https://github.com/Xidong-AI/deepseek-harness-web-docker)、
[smanx](https://github.com/smanx/deepseek-harness-docker)、
[runzhliu](https://github.com/runzhliu/deepseek-harness-docker)、
[misaka-link](https://github.com/misaka-link/deepseek-harness-docker)、
[Sovea](https://github.com/Sovea/deepseek-harness-docker)、
[gehennawu](https://github.com/gehennawu/dsh-nas)、
[okxlin/release-factory](https://github.com/okxlin/release-factory)。

---

## 十六、许可证

MIT。DeepSeek Harness 与其插件按其各自许可单独授权。
