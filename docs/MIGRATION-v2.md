# 从 v1（/dsh）迁移到 v2（/opt/dsh）

目标：保留现有数据（用户、会话、插件、工作区），把部署目录换成 `/opt/dsh`，并切换到 v2 镜像（无代理、`dsh-web-startup-auth`）。

**核心原则：先复制，不删 `/dsh`；新实例先用 3081 验证，确认后再切 3080。旧镜像和旧数据保留到验证完成。**

## 0. 先备份

在旧部署的宿主机上：

```bash
sudo tar -C / -czf /root/dsh-legacy-$(date +%Y%m%d).tgz \
  --exclude='dsh/workspace' dsh
sudo tar -czf /root/dsh-workspace-$(date +%Y%m%d).tgz -C /dsh/workspace .
docker images | grep -i deepseek-harness-docker > /root/dsh-images.txt
```

记录旧镜像 tag：

```bash
docker inspect qxdho-dsh --format '{{.Config.Image}}'
```

## 1. 建新目录并复制数据

推荐先停旧容器，确保复制一致：

```bash
# 在旧仓库目录执行
./dshm service down
```

然后复制（`rsync` 不存在就用 `cp -a`）：

```bash
sudo mkdir -p /opt/dsh/data /opt/dsh/workspace

# /dsh 里的 profiles、sessions、credentials、attachments 等
sudo rsync -aHAX --exclude workspace /dsh/ /opt/dsh/data/

# 工作区
sudo rsync -aHAX /dsh/workspace/ /opt/dsh/workspace/

# 属主必须与容器运行 uid 一致；默认 1000，若 .env 里 DSH_UID 不同就换成实际值
sudo chown -R 1000:1000 /opt/dsh/data /opt/dsh/workspace
```

检查空间：复制后 `/dsh` 和 `/opt/dsh/data` 会同时存在，确认磁盘够用。

## 2. 安装 v2 实例（先不要占用 3080）

先在 v2 仓库目录本地构建镜像（v2 尚未推到 GHCR 的 `latest`）：

```bash
docker build -t dsh-v2:local .

# 只安装 dshm，不立刻创建实例
sudo ./install.sh --install-only
```

然后用本地镜像安装：

```bash
read -rsp '新的登录密码（≥14 位）: ' PW; echo
printf '%s\n' "$PW" | sudo dshm docker install \
  --dir /opt/dsh \
  --data-dir /opt/dsh/data \
  --port 3081 \
  --bind 127.0.0.1 \
  --image dsh-v2:local \
  --container qxdho-dsh-v2 \
  --no-pull \
  --password-stdin
unset PW
```

- `<v2 镜像 tag>` 用已构建的 v2 镜像；本地构建可用 `dsh-v2:local`，但 `--no-pull` 只有在本地已有该镜像时才成立；
- 如果镜像在 GHCR，去掉 `--no-pull`；
- `dshm` 不会覆盖已有 `/opt/dsh/.env`；如果之前建过，先备份再删。

启动后检查：

```bash
dshm --dir /opt/dsh docker status
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3081/login   # 200
```

## 3. 验证 v2

- 浏览器/无痕窗口打开 `http://127.0.0.1:3081/`，应出现登录页；
- 用 `DSH_AUTH_PASSWORD` 对应的账号密码登录；
- 检查会话列表、工作区文件、插件是否还在；
- 确认日志没有 `TypeError` / `did not activate`。

v2 启动时会检测旧 `dsh-auth-gate` profile，并把它改名备份为：

```text
/opt/dsh/data/profiles/web.v1-backup-<时间>
```

然后重播 v2 profile。**旧 gate 的用户/会话不会迁移**，新管理员来自 `DSH_AUTH_PASSWORD`。

## 4. 切换 3080

旧实例还占着 3080。确认 v2 验证通过后：

```bash
# 停旧实例（旧仓库目录）
./dshm service down

# 新实例改端口
cd /opt/dsh
sed -i 's/^DSH_HTTP_PORT=3081$/DSH_HTTP_PORT=3080/' .env
dshm --dir /opt/dsh docker up
```

更新宿主反代 upstream 到 `127.0.0.1:3080`，并加：

```nginx
proxy_cookie_flags ~ secure;
```

`.env` 里设置：

```ini
DSH_BIND=127.0.0.1
DSH_PUBLIC_HOST=dsh.example.com
DSH_COOKIE_SECURE=1
```

## 5. 回滚

v2 出问题时：

```bash
# 停 v2
dshm --dir /opt/dsh docker down

# 重新启动旧实例（旧仓库目录）
./dshm service up
```

数据一直在 `/dsh`，没有被删除或改写；旧镜像也还在。确认稳定后再决定是否清理 `/dsh`。

## 注意

- **不要**在旧容器还写数据时复制后立刻删 `/dsh`；
- 旧 gate 的多用户、TOTP 在 v2 中不保留；需要这些功能请暂留 v1；
- 复制后如果旧实例又运行过，需要重新同步一次数据；
- 首次 v2 启动会备份并重播 profile；profile 里额外安装的插件可能需要重新安装；
- HTTPS 反代的 Cookie Secure 必须靠 `proxy_cookie_flags`，v2 插件不会读 `X-Forwarded-Proto`。
