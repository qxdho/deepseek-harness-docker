# 用 1Panel 编排部署 dsh

## 为什么用镜像而不是 `build`

1Panel 编排的文件由面板自己管理，放在 `/opt/1panel/docker/compose/<项目名>/`。
compose 里写 `build: .` 时，构建上下文就是那个目录——**Dockerfile、proxy/、
entrypoint.sh 都得先放进那里**，否则报 `COPY failed` 或 `Dockerfile not found`。

把源码手工塞进面板目录很别扭，所以这里改成：**镜像由 GitHub Actions 构建推送到
GHCR，1Panel 编排只负责拉取运行**。1Panel 官方应用商店的 dsh 也是这个模式
（`image: 1panel/deepseek-harness:0.1.5-rc.2`），不是 build。

---

## 步骤 1：确认镜像已构建

推送到 `main` 后，GitHub Actions 会自动构建并推送。检查：

- 仓库页 → **Actions** → `build-image` 是否是绿色
- 成功后镜像地址：`ghcr.io/qxdho/deepseek-harness-docker:0.1.7-rc.2`

**首次必须做一步：把包设为公开。** GHCR 的包默认私有，1Panel 拉取会 401：

> GitHub → 仓库页右下 **Packages** → 点进这个包 → **Package settings**
> → Danger Zone → **Change visibility** → Public

不想公开也行，在 1Panel 编排里配置 GHCR 登录凭据即可，但麻烦，建议直接设公开。

验证镜像可拉取（在服务器上）：

```sh
docker pull ghcr.io/qxdho/deepseek-harness-docker:0.1.7-rc.2
```

如果这一步失败，后面都不用做——先解决它。

---

## 步骤 2：创建编排

1. 1Panel → **容器** → **编排** → **创建编排**
2. 名称填 `dsh-own`
3. 把 `deploy/1panel/docker-compose.yml` 的内容**整段粘贴**进 YAML 编辑框
4. **改这两处**（不改会出问题）：

| 字段 | 改成 |
|---|---|
| `PROXY_PASSWORD` | 你自己的强密码（≥12 位） |
| `DSH_TRUSTED_HOSTS` | 你实际访问用的域名或 IP |

`DSH_TRUSTED_HOSTS` 是最容易漏的：因为代理保留原始 Host，dsh 的 `/api`
信任栅栏只接受回环地址和这里声明的值。**填错的症状是页面能打开、但接口全 403。**

5. 点确认，1Panel 会拉镜像并启动

---

## 步骤 3：先用 IP 直连验证

**先别急着配 HTTPS**，先用最简单的方式确认镜像本身没问题——
这样出问题时能排除掉反代这一层。

临时把端口改成对外：

```yaml
ports:
  - "3080:3080"          # 从 127.0.0.1:3080:3080 改掉
environment:
  DSH_TRUSTED_HOSTS: "服务器IP:3080"
```

保存并重启编排，然后浏览器访问 `http://服务器IP:3080/`。

**预期**：弹出 Basic Auth 输入框 → 输入用户名密码 → 进入 dsh 界面。

如果这里就不通，先看日志：

```sh
docker logs -f dsh-own
```

正常应该看到：

```
[dsh] 启动：dsh web --port 3079 --no-open --trusted-host 服务器IP:3080
[dsh] dsh 就绪 (pid ...)
[proxy] 监听 0.0.0.0:3080 -> http://127.0.0.1:3079（Basic Auth 已启用）
[proxy] 保留原始 Host，保证会话 cookie 的 authority 一致
[token] 已从日志捕获 launch token（长度 43）
```

---

## 步骤 4：加 HTTPS（用 1Panel 的证书）

IP 直连验证通过后，改回只绑回环，再建网站反代。

**① 编排端口改回只绑本机**：

```yaml
ports:
  - "127.0.0.1:3080:3080"
environment:
  DSH_TRUSTED_HOSTS: "dsh.qxdho.top"
```

**② 1Panel → 网站 → 创建网站 → 反向代理**

- 主域名：`dsh.qxdho.top`
- 代理地址：`http://127.0.0.1:3080`
- 开启 HTTPS，选 1Panel 申请的证书

**③ 关键：反代配置里 Host 的处理**

1Panel 生成的 nginx 配置自带 `proxy_set_header Host $host;`，会把浏览器域名
原样传下去。这是**正确**的——代理保留它，dsh 用同一个 authority 签 cookie，
浏览器才会接受。**不要改成 `127.0.0.1:3080`**。

**④ 密码别设两层**

如果已在 1Panel 网站里配了「访问限制/密码」，就把编排里的
`PROXY_USERNAME`/`PROXY_PASSWORD` 留空，否则会**弹两次验证框**。

---

## 工作区用宿主机目录（可选）

默认用命名卷 `dsh-workspace`，好处是**开箱即可写**。如果你想直接在宿主机上看
agent 生成的文件，改成绑定挂载：

```yaml
volumes:
  - dsh-home:/home/node/.dsh
  - /opt/dsh-workspace:/workspace
```

**必须先建目录并改属主**，否则 agent 无法写入：

```sh
mkdir -p /opt/dsh-workspace
chown 1000:1000 /opt/dsh-workspace      # 容器内以 node(uid 1000) 运行
```

原因：绑定挂载时宿主机目录的属主会覆盖镜像里的设置。若让 Docker 自动新建，
会得到 `root:root 0755`，而容器以 uid 1000 运行，写不进去——表现为 agent 报
`EACCES: permission denied`，或无法创建任何文件。

命名卷没有这个问题：首次挂载时会从镜像继承 `/workspace` 的 `node:node` 属主。

---

## 升级版本

1. 改 `Dockerfile` 里的 `ARG DSH_VERSION=新版`
2. 提交推送 → Actions 自动构建出 `:新版` 标签
3. 改编排里的 `image:` 标签 → 保存重启

数据在 `dsh-home` 命名卷里，**重启/重建容器都不会丢**。但 dsh 官方声明
处于开发者预览、会出破坏性变更，升级前建议备份：

```sh
docker run --rm -v dsh-own_dsh-home:/d -v "$PWD:/b" alpine \
  tar czf /b/dsh-home-backup.tgz -C /d .
```

> 卷名前缀 `dsh-own_` 是 1Panel 编排的项目名。用 `docker volume ls` 确认真实名字。

---

## 故障排查

| 症状 | 原因 | 处理 |
|---|---|---|
| `docker pull` 401 | GHCR 包还是私有 | 按步骤 1 设为 Public |
| 页面能开，接口全 403 | `DSH_TRUSTED_HOSTS` 没填对 | 填成浏览器地址栏里的域名/IP |
| 一直跳转/无限重定向 | Host 被中间层改写了 | 检查反代是否改了 `Host` 头 |
| 弹两次密码框 | 1Panel 网站和容器都启了认证 | 关掉其中一个 |
| 容器起来又退出 | dsh 启动失败 | `docker logs dsh-own`，看 `[dsh]` 那几行 |

---

## 与 1Panel 官方 dsh 应用并存

1Panel 应用商店里那个 dsh 用的是 `10443 → 8443`，本项目默认 `3080`，
两者**端口不冲突，可以并存对比**。它们的区别：

| | 1Panel 官方 | 本项目 |
|---|---|---|
| dsh 版本 | 0.1.5-rc.2 | **0.1.7-rc.2** |
| 反代 | 容器内 Caddy + argon2id | 代理 + 1Panel 网站 |
| 根文件系统 | `read_only: true` | 可写 |
| 认证实现 | Caddy Basic Auth | 手写 Basic Auth |
