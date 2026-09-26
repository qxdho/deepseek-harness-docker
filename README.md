# dsh 自建镜像（学习 smanx 架构，修正其 cookie 缺陷）

从零搭一个 dsh 的 Docker 镜像，跑 **`0.1.7-rc.2`**。架构借鉴
[smanx/deepseek-harness-docker](https://github.com/smanx/deepseek-harness-docker)
（内部回环 + 外部代理 + 多阶段构建），但修掉了它导致
`ERR_TOO_MANY_REDIRECTS` 的那个 bug。

## 快速开始

```sh
cp .env.example .env       # 填 PROXY_PASSWORD，必要时填 DSH_TRUSTED_HOSTS
docker compose up -d --build
docker compose logs -f dsh
```

访问 `http://127.0.0.1:3080/`（或你的局域网地址）。

## 三个必须理解的设计点

### 1. 为什么需要代理

`dsh web --host 0.0.0.0` 被官方**故意拒绝**：

> `--host 0.0.0.0 is intentionally not supported yet for safety: it would expose remote code execution to the network`

所以 dsh 只能监听回环，对外监听必须由代理承担。这一点 smanx 和本实现一致。

### 2. 为什么必须注入 polyfill

dsh 前端用 `crypto.randomUUID()`，该 API **只在安全上下文**（`https` 或
`localhost`）可用。通过局域网 IP 访问时是非安全上下文，`randomUUID` 不存在，
实时通道会一直 pending。代理往 HTML 的 `<head>` 注入一个基于
`crypto.getRandomValues` 的实现。

### 3. 为什么绝不能改写 Host（本实现与 smanx 的核心差异）

这是整个项目的关键。dsh 的浏览器会话 cookie 与请求 **authority(Host)** 强绑定：

```js
// dsh-client-connection 源码
function cookieName(authority) {
  return COOKIE_PREFIX + encodeBase64Url(sha256(authority));   // cookie 名 = hash(authority)
}
function sessionCookie(name, value, ...) {
  return `${name}=${value}; Max-Age=...; Path=/; HttpOnly; SameSite=Strict`;  // 无 Domain
}
```

**cookie 名是 Host 的哈希，签名负载里也含 authority。**

smanx 的代理用了 `changeOrigin: true`，会把 Host 改写成 `127.0.0.1:3079`。
后果链条：

```
浏览器访问 192.168.1.10:3080
  → 代理把 Host 改成 127.0.0.1:3079
  → dsh 按 127.0.0.1:3079 签发 cookie（名字 = sha256("127.0.0.1:3079")）
  → 303 + Set-Cookie 回到浏览器
  → 浏览器发现 cookie 名与当前站点不符，直接丢弃
  → 跟随 Location: / 重新请求，仍无凭据 → 又 401
  → 代理又换 token → 无限循环 → ERR_TOO_MANY_REDIRECTS
```

**本实现用 `changeOrigin: false` 全程保留原始 Host**，包括内部换 token 那次
请求（用 `node:http` 显式设 `host` 头）。这样 dsh 会用浏览器的真实 authority
签 cookie，浏览器才会接受。

### 实测验证

用一个模拟 dsh cookie 行为的假上游做过端到端验证：

| 检查项 | 结果 |
|---|---|
| 非回环 Host 访问 → 上游收到的 Host | `192.168.1.10:3180`（未被改写）✅ |
| 代理换 token 后下发的 cookie 名 | `== sha256("192.168.1.10:3180")` ✅ |
| 带该 cookie 再访问 | `200 OK` ✅ |
| 错误 authority 的 cookie | `401`（正确拒绝）✅ |
| HTML polyfill 注入 | 已注入 ✅ |
| 对照：`changeOrigin:true` 的 cookie 名 | `== sha256("127.0.0.1:3181")` ❌ 复现 bug |

## 配置

| 变量 | 默认 | 说明 |
|---|---|---|
| `DSH_VERSION` | `0.1.7-rc.2` | 构建参数 |
| `DSH_PORT` | `3079` | dsh 容器内监听（回环） |
| `PROXY_PORT` | `3080` | 代理对外端口；`-p` 要对应 |
| `PROXY_USERNAME` / `PROXY_PASSWORD` | 空 | **两个都设才启用** Basic Auth |
| `DSH_TRUSTED_HOSTS` | 空 | 浏览器用的 authority，空格分隔 |
| `DEV_TOOLS` | `none` | `full` = 额外装 python3/make/g++ 等 |
| `DSH_WORKSPACE` | `./workspace` | 工作区挂载 |

### ⚠️ `DSH_TRUSTED_HOSTS` 必须填对

因为代理保留原始 Host，浏览器带来的 authority 会原样到达 dsh。而 dsh 的
`/api` 信任栅栏**只接受回环地址和显式声明的 `trustedHosts`**。

**症状**：页面能打开，但所有 API 调用 403、实时通道连不上。

**修法**：把浏览器实际使用的地址填进去（多个空格分隔）：

```sh
DSH_TRUSTED_HOSTS="192.168.1.10:3080 dsh.example.com"
```

用 `127.0.0.1` 或 `localhost` 访问时可留空（回环天然被信任）。

## ⚠️ 没有 HTTPS

本实现只提供 HTTP + Basic Auth。**Basic Auth 是 Base64 编码，不是加密**——
裸 HTTP 下密码等于明文传输。

公网访问必须在前面套一层 HTTPS 反代（1Panel 的 OpenResty/nginx 站点即可）。
那种情况下建议让 **nginx 负责认证**、这里不设密码，否则会弹两次验证框。

## 架构

```
浏览器 :3080
   ↓  (Host 原样保留)
proxy/index.js  ──  Basic Auth（可选）
   ├─ HTML → 注入 polyfill
   ├─ 根路径无 cookie → 自动用 launch token 换会话 → 303 透传
   └─ 其余 → 原样转发（含 SSE / WebSocket）
   ↓
dsh web --port 3079 --trusted-host <你填的>
   (仅 127.0.0.1)
```

`entrypoint.sh` 先起 dsh，轮询就绪后再 `exec` 代理成为主进程。

### 比 smanx 改进的两处细节

1. **`tail -F` 而非 `-f`**：`-f` 在日志文件尚未创建时会立刻报错退出，导致
   dsh 自身日志再也看不到（smanx 的日志里就留着这个错）。`-F` 会等待并重试。
2. **`selfHandleResponse: true`**：`http-proxy` 默认自己写响应头，若在
   `proxyRes` 里再写会抛 `ERR_HTTP_HEADERS_SENT`。必须显式接管。

## 数据持久化

| 位置 | 内容 |
|---|---|
| `dsh-home` 卷 → `/home/node/.dsh` | 会话、设置、凭证 |
| `./workspace` → `/workspace` | 代码 |

重建容器不丢数据（卷在宿主机上）。**升级前**仍建议备份：

```sh
docker run --rm -v dsh-own_dsh-home:/d -v "$PWD:/b" alpine \
  tar czf /b/dsh-home-backup.tgz -C /d .
```

## 测试工具

`fake-dsh.js` 模拟 dsh 的 cookie 签发行为，用于验证代理，不参与镜像构建：

```sh
FAKE_PORT=3181 node fake-dsh.js > /tmp/fake-dsh.log 2>&1 &
DSH_PORT=3181 PROXY_PORT=3280 DSH_WEB_LOG=/tmp/fake-dsh.log node proxy/index.js &
curl -i -H "Host: 192.168.1.10:3280" http://127.0.0.1:3280/   # 应 303 + Set-Cookie
```
