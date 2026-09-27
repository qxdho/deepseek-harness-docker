# dsh 一键部署镜像（DeepSeek Harness + 登录门禁）

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh`）的 Web UI
打包成一个可直接部署的 Docker 镜像，并内置登录页与两步验证。

- **不用再手动贴 token**：dsh 的启动 token 由登录插件在容器内部自动换成会话 Cookie。
- **有正经登录页**：用户名 + 密码，可选 TOTP 两步验证，带限速与防爆破。
- **开箱即用**：GitHub Actions 自动构建多架构镜像并推送到 GHCR，服务器上 `docker compose pull && up -d` 即可。
- **非 root、最小权限**：`cap_drop: ALL` + `no-new-privileges`，文件沙箱默认 `workspace-write`（Landlock）。

> 非官方项目。dsh 仍处于预发布阶段，请阅读 [SECURITY.md](SECURITY.md)。

---

## 快速开始

**一条命令：**

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
chmod +x install.sh
./install.sh          # 只问你一次密码，其余全自动
```

**或者手动三步：**

```bash
cp .env.example .env
# 编辑 .env：把 DSH_AUTH_PASSWORD 改成一个强密码
docker compose up -d --build
```

打开 `http://<服务器IP>:3080/`，会先看到登录页。默认用户名 `admin`，密码是你在 `.env` 里设的。
登录后即可正常使用 dsh。

```bash
./dshctl logs       # 跟随日志
./dshctl status     # 健康状态 / 端口 / 登录用户
./dshctl down       # 停止（保留数据卷）
```

---

## 架构

```
浏览器 ──▶ 代理 0.0.0.0:3080 ──▶ dsh 127.0.0.1:3079（web profile + dsh-auth-gate）
             │
             ├─ 把 Host/Origin 一致改写成 127.0.0.1:3079
             └─ 往 HTML 注入 crypto.randomUUID 补丁 + __DSH_TRANSPORT__.ownsHost
```

- dsh 官方**拒绝** `--host 0.0.0.0`（防止可执行代码的 Web 接口被误暴露），所以 dsh 只监听回环，
  对外监听由容器内的代理承担。
- **登录、会话、TOTP、以及 launch token → 会话 Cookie 的桥接，全部由 dsh-auth-gate 插件在 dsh 进程内完成**。
- 代理只做转发和注入，**不做鉴权**，也**不改 dsh 任何文件**。

---

## 关于 token 与 Cookie（重要，请读）

dsh 启动时会生成一个**一次性 token**，打印成 `http://127.0.0.1:3079/?token=…`。用这个 URL 访问一次，
dsh 会签发一个**会话 Cookie**（默认 30 天），之后的访问都靠这个 Cookie。

**本项目里你永远不会看到这个 token**：登录成功后，dsh-auth-gate 会自动做一次相对跳转
`/?token=…` 完成交换，然后回到干净的 `/`。

### 常见误解：改写 Host 会不会让浏览器丢掉 Cookie？

**不会。** 这是本项目上一版说明里的错误论断，已在真实 dsh 上实测推翻：

- dsh 的会话 Cookie **不带 `Domain` 属性**，因此浏览器按**它访问的网址**（例如 `dsh.example.com`）
  存放 Cookie，而不是按 dsh 收到的 `Host` 头。
- Cookie 的**名字**由 dsh 按收到的 `Host` 计算。只要代理**每次都用同一个 Host 转发**，
  名字就始终对得上，Cookie 一直有效。
- 实测：浏览器在 `lan.test:3099` 访问、代理把 Host 改写成 `127.0.0.1:3080`，
  带 Cookie 再访问得到 **HTTP 200**。

真正会导致 `ERR_TOO_MANY_REDIRECTS` 的是**代理在每个请求上都重新注入 token**（于是
`/` → `/?token=` → 303 → `/` → … 死循环）。本项目通过"只在插件内部做一次桥接"避免了这个坑。

改写 Host 为回环还有个好处：**不需要为每个访问域名配置 `--trusted-host`**。

---

## 登录与两步验证（TOTP）

登录由 [`dsh-auth-gate`](https://github.com/TecFancy/dsh-auth-gate) 提供，配置由 `.env` 驱动：

| 变量 | 取值 | 说明 |
|---|---|---|
| `DSH_AUTH_USER` | 默认 `admin` | 首次启动创建的管理员用户名 |
| `DSH_AUTH_PASSWORD` | 必填 | 首次启动用它建号；之后改密码用 `./dshctl password` |
| `DSH_TOTP` | `off` / `optional` / `required` | 默认 `optional`：绑定了 TOTP 的用户登录时要输验证码 |

给管理员开启 TOTP：

```bash
docker exec -it dsh node /home/node/.dsh/profiles/web/node_modules/dsh-auth-gate/lib/cli.js \
  user totp enable admin
# 按提示把 otpauth:// 链接导入验证器应用（Google Authenticator / 1Password 等）
```

> 用户列表在 `$DSH_HOME/auth/users.yaml`，随数据卷持久化。

---

## HTTPS（在宿主机上加，Docker 里不做）

默认只提供 HTTP，适合可信内网。**密码登录在明文 HTTP 下不安全**，公网部署请在**宿主机**上加 TLS
（Nginx、宝塔、Cloudflare Tunnel 等，用你现成的即可），反代到本容器的 `127.0.0.1:3080`。

宿主机反代需要：

1. 转发 **WebSocket**（dsh 的实时通道要用），Nginx 例：
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
2. 在 `.env` 里设置：
   ```
   DSH_COOKIE_SECURE=1                 # 会话 Cookie 带 Secure
   DSH_PUBLIC_HOST=dsh.example.com     # 登录页显示正确域名
   ```

因为容器内的代理会把 Host/Origin 一致改写成回环地址，**你不需要给 dsh 配 `--trusted-host`**，
宿主机反代转发什么 Host 都不会导致 403。

> 容器默认只绑 `127.0.0.1`（见 `.env` 的 `DSH_BIND`），也就是只有宿主机能访问它——正好配合宿主机反代。
> 加反代之前想先从局域网直连测试，把 `DSH_BIND` 临时改成 `0.0.0.0` 即可。

---

## 数据持久化

| 容器内路径 | 内容 | 卷 |
|---|---|---|
| `/home/node/.dsh` | 配置、凭据、会话、工作区索引、登录用户 | 命名卷 `dsh-home` |
| `/workspace` | agent 的工作目录（bind mount） | `./workspace` |

登录用户、dsh 的 Cookie 签名密钥都在 `dsh-home` 卷里，**重建容器不会丢**，所以不需要重新登录。

---

## 自更新

```bash
# 宿主侧（推荐，可复现）：改 .env 里的 DSH_VERSION → 重建 → 等待健康
./dshctl update
./dshctl update 0.1.7-rc.2

# 容器内就地升级（写入持久化 npm prefix，重建容器也不丢）
docker exec -it dsh dsh-update
docker exec -it dsh dsh-update 0.1.7-rc.2
./dshctl restart
```

升级 dsh 后，登录插件会照常工作（它跟随 dsh 版本维护，并在启动时校验语义）。若升级后访问异常，
先看 `./dshctl logs`。

---

## 配置项

全部在 `.env` 里。改完运行 `./dshctl restart` 生效；标 **构建期** 的改完要重新构建
（`./install.sh` 或 `./dshctl up --build`）。完整模板见 [.env.example](.env.example)。

### 部署与镜像（构建期：改了要重建）

| 变量 | 默认 | 作用 | 什么时候改 |
|---|---|---|---|
| `DSH_IMAGE` | `ghcr.io/qxdho/deepseek-harness-docker:latest` | 用哪个镜像启动 | 想用本地构建的镜像时改成 `dsh-local:latest` |
| `DSH_VERSION` | `0.1.7-rc.2` | 镜像内置的 dsh 版本 | 想升级/固定 dsh 版本 |
| `AUTH_GATE_VERSION` | `0.15.0` | 内置的登录插件版本 | 插件出新版时 |
| `DEV_TOOLS` | `none` | `full` 时额外装 `python3/make/g++`，供**容器内**安装带原生依赖的插件 | 需要在容器里装复杂插件时 |

### 网络与入口（运行期：改了重启即可）

| 变量 | 默认 | 作用 | 什么时候改 |
|---|---|---|---|
| `PROXY_PORT` | `3080` | 宿主机监听端口 | 端口被占用时 |
| `DSH_BIND` | `127.0.0.1` | 绑定地址。`127.0.0.1` = 只有宿主机能访问（配合宿主机反代）；`0.0.0.0` = 局域网可直连 | 想先用 IP 直接测试时改成 `0.0.0.0` |
| `DSH_WORKSPACE` | `./workspace` | agent 的工作目录（挂到容器 `/workspace`） | 想让 agent 读写你指定的项目目录 |

### 登录与安全（运行期：改了重启即可）

| 变量 | 默认 | 作用 | 什么时候改 |
|---|---|---|---|
| `DSH_AUTH_USER` | `admin` | 管理员用户名（**只在首次建号时**生效） | 想换用户名（首次启动前改） |
| `DSH_AUTH_PASSWORD` | 无（**必填**） | 首次启动用它创建管理员 | `install.sh` 会问；之后改密码用 `./dshctl password` |
| `DSH_TOTP` | `optional` | 两步验证：`off` / `optional` / `required` | 想强制所有用户开 TOTP 时设 `required` |
| `DSH_COOKIE_SECURE` | `0` | 设 `1` 时登录会话 Cookie 带 `Secure` | **走 HTTPS 时设 1** |
| `DSH_PUBLIC_HOST` | 空 | 登录页显示的域名，防钓鱼提示 | 用域名访问时设成你的域名 |

### 容器内的进阶项（默认已设好，一般不用动）

这些在镜像里已有默认值，需要时可在 `docker-compose.yml` 的 `environment:` 里覆盖：

| 变量 | 默认 | 作用 |
|---|---|---|
| `DSH_PERMISSION_MODE` | `workspace-write` | 文件沙箱：`read-only` / `workspace-write` / `danger-full-access` |
| `DSH_TELEMETRY_DISABLED` | `1` | 关闭遥测 |
| `DSH_PORT` | `3079` | dsh 在容器内监听的回环端口 |
| `NARB_DISABLE_NATIVE_CACHE` | `1` | 避免原生插件缓存落到 `noexec` 的 `/tmp` |

### 改配置的两种方式

```bash
# 运行期配置（端口、绑定、TOTP、密码等）
vim .env
./dshctl restart

# 构建期配置（dsh 版本、插件版本、DEV_TOOLS）
vim .env
./install.sh            # 或 ./dshctl up --build
```

---

## 目录结构

```
Dockerfile               多阶段构建：装 dsh + 预置 dsh-auth-gate 的 profile
docker-compose.yml       拉 GHCR 镜像（或本地构建）并启动
entrypoint.sh            播种 profile、建管理员、起 dsh 与代理
proxy/index.js           薄转发 + Host/Origin 改写 + HTML 注入（不做鉴权）
scripts/                 健康检查、自更新、冒烟测试、dsh wrapper
dshctl                   宿主机管理命令
.github/workflows/       GHCR 多架构构建 + 真实冒烟测试
```

---

## 排障

- **页面打不开 / 502**：`./dshctl logs` 看是不是 dsh 还没起来（首次启动可能要 1–2 分钟）。
- **一直停在登录页**：确认 `.env` 里的密码和用户名；改密码用 `./dshctl password admin`。
- **设置页提示 "settings are unavailable in this browser"**：正常情况不会出现——代理已注入
  `__DSH_TRANSPORT__.ownsHost`。若出现，说明代理注入没生效，检查 `proxy/index.js` 是否在运行。
- **升级后登录插件报错**：插件的兼容区间是 dsh `^0.1.0-rc.6 || ^0.1.5-rc.2 || ^0.1.7-alpha.1`，
  换到区间外的版本需要同步升级插件（`AUTH_GATE_VERSION`）。

## 许可证

MIT。DeepSeek Harness 与其插件按其各自许可单独授权。
