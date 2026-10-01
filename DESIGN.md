# Design notes

## 1. Problem

DeepSeek Harness (`dsh web`) is a single-user local tool:

- it **refuses to bind `0.0.0.0`** (upstream safety gate) — so exposing it needs a process on the
  container network that forwards to loopback;
- it authenticates browsers with a **one-time launch token** printed at startup, exchanged once for a
  signed session cookie (30 days by default, signing secret persisted in `$DSH_HOME/.credentials.yaml`);
- its `/api` routes sit behind a **Host/Origin fence**: `Host` must be loopback or a `--trusted-host`
  authority, and `Origin` (when present) must equal `Host`;
- its frontend calls `crypto.randomUUID`, which does not exist in a **non-secure browser context**
  (plain HTTP on a LAN IP);
- its Settings page requires the **page origin to be loopback** (the client-side `isLoopback` check).

## 2. Why `dsh-auth-gate`

Four ways to replace the launch token with a login page were considered: (A) manual token, (B) proxy-side
token→cookie exchange, (C) strip dsh's auth and authenticate in a gateway, (D) an in-process plugin.

C breaks on dsh upgrades (1Panel's undocumented `ONEPANEL_DSH_AUTH_PROXY`, misaka-link's source patch).
D is the cleanest and is what this project uses: `dsh-auth-gate` is a maintained plugin with
password/shared-token login, optional TOTP, sessions, rate limiting, a user-management CLI, and — crucially
— it **bridges the launch token itself** (the login redirect hops through a relative `/?token=…` that sets
the dsh cookie). The user never sees the token, and no dsh file is modified.

## 3. Rewriting `Host` does not break the session cookie

The session cookie has **no `Domain` attribute**, so the browser scopes it to the site it requested,
independent of the upstream `Host` header. The cookie *name* is derived from the `Host` dsh receives;
consistent rewriting keeps name and storage aligned. Measured on real dsh (`0.1.5-rc.2`, no bypass env):

```
client URL:  http://lan.test:3099/   (--resolve to 127.0.0.1)
upstream Host: 127.0.0.1:3080
GET /?token=... -> 303 + Set-Cookie (no Domain)  -> stored for lan.test
GET /            -> 200
```

`ERR_TOO_MANY_REDIRECTS` comes from re-injecting the token on every `/` request (`/ → /?token= → 303 → /`),
not from rewriting Host. The plugin does the exchange exactly once. Rewriting Host to loopback also removes
the need for per-domain `--trusted-host` configuration.

## 4. Layers in the image

1. **dsh** on `127.0.0.1:3079`, web profile with `dsh-auth-gate` pre-installed into a baked profile.
2. **proxy** (`proxy/index.js`, `http-proxy`) on `0.0.0.0:3080`:
   - forwards HTTP and WebSocket to loopback;
   - rewrites `Host` and `Origin` to `127.0.0.1:3079` consistently (fence-safe);
   - requests `accept-encoding: identity` so HTML can be safely rewritten;
   - injects into `<head>`: a `crypto.randomUUID` polyfill and
     `globalThis.__DSH_TRANSPORT__ = { …, ownsHost: true }` (a documented dsh seam — nothing in dsh
     assigns this global, it is read by the client to derive `isLoopback`).
3. **No reverse proxy inside the image** — the Node forwarder is the only listener, on plain HTTP.
   TLS is deliberately left to the host (Nginx / BaoTa / Cloudflare / any existing proxy), which
   forwards to the container's `127.0.0.1:3080`. Operators set `DSH_COOKIE_SECURE=1` and
   `DSH_PUBLIC_HOST=<domain>` in that case.

## 5. Build and runtime details

- Multi-stage build: the builder compiles `node-pty` (needs python3/make/g++), installs
  `dsh-auth-gate` into a seed profile, links the plugin CLI's peer deps
  (`@deepseek-ai/dsh-storage-domain`, `@deepseek-ai/cordis`) so the CLI works at runtime, and runs a
  build-time CLI smoke test. The runtime stage copies `/usr/local` and the seed profile.
- `dsh` is invoked through a wrapper that always adds `--expose-internals`; `dsh web` mounts the HMR
  plugin, which requires it, and npm's generated bin symlink does not pass it.
- `NARB_DISABLE_NATIVE_CACHE=1` avoids dsh 0.1.7-rc.2 materialising native addons into a possibly
  `noexec` tmpfs.
- The first boot seeds `$DSH_HOME/profiles/web` from the baked profile if missing (covers bind mounts
  and empty volumes), writes the plugin config from environment variables, and creates the admin user
  only when no `auth/users.yaml` exists.

### 5.1 The `/workspace` bind-mount ownership trap

`${DSH_WORKSPACE_HOST:-/dsh/workspace}:${DSH_WORKSPACE_CONTAINER:-/workspace}` is a bind mount, and **a bind mount shadows whatever the
image set up underneath it**. The `chown -R node:node … /workspace` in the Dockerfile is therefore a
no-op at runtime. Worse, when the host-side source directory does not exist, the Docker daemon creates
it **as root** (Compose ignores `bind.create_host_path: false` —
[docker/compose#13602](https://github.com/docker/compose/issues/13602)). The agent then runs as
`node` (UID 1000) against a `root:root 0755` directory, and the failure surfaces far from its cause:

```
EACCES: permission denied, mkdir '/workspace/xxx'
```

There is no way to fix this from inside the container, and there should not be: `cap_drop: ALL`
removes `CAP_CHOWN` and `CAP_DAC_OVERRIDE`, the image is `USER node`, and `DSH_PERMISSION_MODE=workspace-write`
(Landlock) does not confine a root process — so a root entrypoint that chowns and then drops privileges
would silently disable the sandbox this project advertises. The tempting "just add back
`DAC_OVERRIDE`/`CHOWN`" fix (as some peer projects do) has the same effect.

The chosen approach, matching the rootless-container consensus
([hindsight #2010](https://github.com/vectorize-io/hindsight/pull/2010)):

1. **Host side** — `scripts/preflight.sh` runs from `install.sh` and `dshm service up` *before* `compose up`.
   Creating the directory while the user still owns it is the whole fix. If it already exists with the
   wrong owner, it chowns via `sudo` when available and otherwise prints the exact command.
2. **Container side** — `entrypoint.sh` probes writability of `/workspace` early (before dsh starts). If it
   is not writable it prints the same actionable message and then **degrades to `$DSH_HOME/.workspace`**
   instead of exiting: under `restart: unless-stopped` a non-zero exit becomes an infinite restart loop,
   which the user experiences as "the page never opens" — worse than running with a fallback. The
   degraded run logs a loud banner and keeps the UI usable. `DSH_WORKSPACE_STRICT=1` restores fail-fast.
3. **Tests** — `scripts/test-preflight.sh` (offline, no Docker) and `scripts/smoke-workspace.sh`
   (real container; uses `--tmpfs` so the fixture is root-owned even when the tests themselves run as
   root, which `chmod` cannot reproduce).

### 5.2 One container UID, one source of truth

Writability must be judged against **the UID the container will actually run as**, and that value must have
exactly one source. Judging with the deployer's own write test is wrong whenever the deployer is not the
container user — typically root (`sudo ./install.sh`, root VPS, 1Panel): `./workspace` is then
`root:root 0755`, writable by root but not by uid 1000. Two shapes of this mistake were rejected:

- **A preflight-only override.** A `DSH_UID` that the preflight reads but `docker-compose.yml` ignores makes
  the check reason about a UID the container never uses — a false pass or fail. `DSH_UID`/`DSH_GID` are
  therefore wired into `user: "${DSH_UID:-1000}:${DSH_GID:-1000}"` and read from `.env` first (like
  `DSH_WORKSPACE_HOST`), because `sudo ./install.sh` does not export `.env` into the shell.
- **Moving the container user.** Running the entrypoint as root to `chown`, then dropping via `setpriv`
  (available in the image), would silently defeat `DSH_PERMISSION_MODE=workspace-write`: Landlock does not
  confine root. Same reason as §5.1.

The data directory is a **host bind mount** (`DSH_HOME_HOST`, default `/dsh`, mounted at `DSH_HOME_CONTAINER`,
default `/dsh`), so its ownership comes from the host like the workspace. `check_dsh_home_dir()` applies the
same container-UID rule and repairs it with `chown` (root or passwordless `sudo`) — no named volume and no
disposable root container involved.

Container path and host path are both configurable (`DSH_HOME_CONTAINER`, `DSH_HOME_HOST`), and so is the workspace
(`DSH_WORKSPACE_CONTAINER`, `DSH_WORKSPACE_HOST`, default `DSH_HOME_HOST/workspace`). All are read from `.env`,
so compose, the preflight and `dshm` cannot drift apart.

### 5.3 Private files must stay owner-only

`dsh-credentials-local` refuses to load a credentials document whose mode has any group or other bit set
(`mode & 0o077 != 0`), and a failure there is fatal: the required `credentials` service never activates, the
web profile aborts, and `restart: unless-stopped` turns it into a restart loop. Files that arrived from the old
named volume, or from a host-side `chmod -R 777`, hit exactly that:

```
credentials-local: /dsh/.credentials.yaml is readable beyond its owner (mode 777)
```

Two layers therefore tighten `.credentials.yaml`, `settings.yaml` and `auth/users.yaml` to `600` (idempotent,
content untouched):

- **host pre-flight** (`fix_private_file_modes()` in `scripts/preflight.sh`), which runs before the container
  starts and fixes the file where the deployer can already `chmod` it;
- **the entrypoint**, which re-checks on every start so a file that becomes world-readable later is repaired
  without a manual step.

Only these known files are touched — a blanket `chmod -R` would rewrite the agent's own workspace permissions,
which are the deployer's business.

## 6. Verification

| Layer | What it covers | Needs Docker |
|---|---|---|
| `scripts/test-preflight.sh` | workspace ownership checks (paths, quoting, non-writable, deployer-vs-container UID, `DSH_UID` resolution), `dsh-home` volume name resolution, private-file mode repair (host and entrypoint), both entrypoint workspace paths | no |
| `proxy/test-inject.js` | HTML injection point (including the `<header>` / `<headless-…>` false positive), `X-Forwarded-For` recomputation, header legality | no |
| `scripts/smoke-test.sh` | real container: health, unauthenticated redirect, login round-trip, session persistence, injection, unauthenticated `/api` rejection | yes |
| `scripts/smoke-workspace.sh` | real container: unwritable workspace degrades (and exits under `DSH_WORKSPACE_STRICT=1`), writable workspace accepts writes | yes |

CI (`.github/workflows/build.yml`) runs the offline suites before the image build, then builds amd64+arm64
to GHCR and runs both smoke suites against a locally loaded image. The workspace fixtures use
`--tmpfs /workspace:mode=0755` rather than `chmod` on a host directory: the CI runner is root, and root
ignores permission bits, so a `chmod`-based fixture would pass even with the bug present.

## 7. Platform support

Linux hosts, amd64 and arm64. `scripts/preflight.sh` uses GNU `stat -c`; BSD/macOS `stat` is not supported
(Docker Desktop's bind mounts do not reproduce the ownership problem anyway). Windows hosts are untested.

## 8. The pnpm store record in the baked profile

Installing a plugin at runtime fails with `ERR_PNPM_UNEXPECTED_STORE` unless the store path pnpm *computes*
equals the one recorded in `node_modules/.modules.yaml`. The baked profile violated this: the build ran as
root (`HOME=/root`) while the runtime is `HOME=$DSH_HOME`, so the record said
`/root/.local/share/pnpm/store/v11` and the runtime computed `$DSH_HOME/.local/share/pnpm/store/v11`.

Facts established by measurement (pnpm 11.7.0), each of which rules out an obvious-looking fix:

- The store location comes from **`$PNPM_HOME/store`, else `$XDG_DATA_HOME/pnpm/store`, else
  `$HOME/.local/share/pnpm/store`**. The current directory and project `.npmrc` are irrelevant.
- **`store-dir` in `.npmrc` is ignored entirely** — project-level, `$HOME`-level and relative forms all had no
  effect. Do not "fix" this by writing an `.npmrc`.
- Environment overrides need the **`pnpm_config_`** prefix: pnpm 11 dropped `npm_config_*`
  (`npm_config_registry` → `pnpm_config_registry` in the 11.0.0 release notes), so `npm_config_store_dir` is
  silently discarded. `pnpm_config_store_dir` / `PNPM_CONFIG_STORE_DIR` do work.
- Setting `pnpm_config_store_dir` alone does **not** clear the mismatch — the stale `storeDir` in
  `.modules.yaml` still wins. The recorded and computed paths must match.
- A relative `pnpm_config_store_dir` resolves against the profile, but pnpm records the **resolved absolute
  path**, so copying the profile anywhere (exactly what seeding into the volume does) breaks it again.

Since the profile is copied from the image into the data volume, its absolute path necessarily changes, so no
"same path in both places" trick survives. The fix is to ship the profile **without** the record: the build
deletes `node_modules/.modules.yaml`, and `entrypoint.sh` deletes it from the volume as well (which also heals
deployments created by earlier images). pnpm then recomputes the store on the first plugin install and writes
it back inside the `.env`-defined `DSH_HOME`. The installed plugin itself is untouched, so this does not
reintroduce a network requirement for the first install.

## 9. `dshm` 与 `dsh-admin` 的分工

一句话：**`dshm` 是唯一的操作入口，`dsh-admin` 只是它的网页外壳。**

### 为什么需要这条边界

两者都能「改变系统状态」，如果不划清，同一件事就会有两份实现 —— 而两份实现迟早
漂移，且**漂移的往往是错的那份**。这个项目已经真实发生过一次：

面板原来直接调 Docker API 做 start/stop/restart。而 `dshm` 的 restart 用的是
`docker compose up -d` 并跑启动前预检（重读 `.env`、修目录属主与权限、等健康）。
`docker restart` 只是把进程重启一遍：

* 改了 `.env`（例如 `DSH_UID`、`DSH_WORKSPACE_HOST`、端口）之后，在面板点「重启」
  **看着成功、实际毫无变化**；
* 目录属主/权限不对时也不会被预检拦下或自动修复。

`dshm` 的源码里甚至专门写了一条注释否掉这种写法。**面板那个按钮正好就是被否掉的做法。**

### 规则

1. **会改变系统状态的操作，只能由 `dshm` 实现**，面板一律通过调用 `dshm` 来完成
   （见 `admin/main.go` 的 `actionDshm` / `runDshm`）。因此面板与命令台共用同一把
   串行锁，避免两个 `compose` 并发打架。
2. **面板可以自己做的**：只读查询（状态、日志、磁盘占用），以及 `dshm` 没有对应
   命令的维护动作（如清理 dangling 镜像）。
3. **凭据刻意分开**：面板有自己的口令与会话密钥（`config.json`），dsh 有它自己的
   用户体系（`.env` + `auth` 子命令）。两者受众不同 —— 面板能动 Docker socket，
   权限约等于宿主机 root，**不应与普通 dsh 用户共用一套凭据**。

### 状态归属

| 状态 | 归属 | 谁读它 |
|---|---|---|
| `.env`（端口、路径、uid、dsh 版本、dsh 登录口令） | 项目目录 | `dshm` 写，面板不碰 |
| 面板口令哈希、会话密钥 | `admin/config.json` | 仅面板 |
| 数据目录内容（会话、插件、凭据） | bind mount | 容器内进程 |

这条边界也让面板本身成为**可选的**：面板没装、没开、甚至坏了，服务照样能用
`dshm` 管理。

## 10. 版本模型：三个域，一个真源

这个项目里同时存在**三个互不影响的版本**。混起来就会觉得「明明升级了却没变」，或者
「我发的版本号怎么和包名对不上」。先把它们分开：

| 版本域 | 管什么 | 真源 | 谁决定 | 命令 |
|---|---|---|---|---|
| **dsh** | 容器里跑的 DeepSeek Harness | **npm registry** | 上游 | `dshm version …` |
| **dshm + 面板** | 部署管理工具本身 | **`VERSION` 文件** | 维护者 | `dshm dshm …` |
| **镜像** | 容器封装的构建产物 | 构建时的 dsh 版本 + 日期 | CI 自动 | `dshm version update --to <tag>` |

上游发新 dsh ≠ dshm 要跟着动；改 dshm ≠ dsh 要升级；重新构建镜像 ≠ dshm 换版本。

### 10.1 为什么 dshm 与面板必须同版本

面板是 dshm 的附属功能：它本质上是「调 `dshm <命令>` 的网页外壳」（见第 9 节）。
`admin/main.go` / `admin/dshversion.go` 里有 11 处对 `dshm` 命令的调用 —— 也就是说
**面板依赖 dshm 的命令行接口**。

如果两者各自演进，就会出现：「面板调用 `dshm version list`，而机器上的 dshm 是旧版、
没有这个子命令」→ 面板按钮点了报错。所以它们的版本号**由机制保证一致**：
`VERSION` 是唯一真源，dshm 在仓库里直接读它、发布版由 CI 写入，面板二进制由 CI 用
`-ldflags` 从同一个文件注入。

### 10.2 dshm 只认 tag（不跟随 main）

`dshm dshm update` **只从发布 tag 拉取，绝不跟随 main**。跟随 main 意味着会把「还没决定
发布的某个中间提交」装到生产上；tag 是维护者明确说「这个版本可以发」的唯一信号。

因此历史上那套「从 `raw.githubusercontent.com/.../main/dshm` 拉单个脚本覆盖自身」的
写法已被移除 —— 它有两个毛病：**跟随 main**，以及**单个脚本文件根本跑不起来**
（dshm 会 `source` 同目录的 `scripts/env-config.sh` 等文件，而自更新的目标机器没有
这些文件）。现在发布的是**整个运行目录的 tar 包**：

```
dshm-v<版本>.tar.gz
└── dshm-v<版本>/
    ├── dshm
    └── scripts/{env-config,migrate-home,admin}.sh
```

安装时先在临时目录解包并**全部**校验（结构、语法、特征串），任何一步不过都不碰现有
文件 —— 宁可继续用旧版本，也不能换成跑不起来的脚本。

### 10.3 tag 名必须等于 `v` + `VERSION`

**这是硬约束，CI 强制校验。** 理由：包名、release 下载地址、脚本里写死的版本号**全都
从这一个号派生**。一旦 tag 与 `VERSION` 脱节，就会发出一个包名对不上的 release：

```
tag         v2026.10.01-1
VERSION     2026.10.01              ← 脱节
产物包名    dshm-v2026.10.01.tar.gz
脚本请求    .../v2026.10.01-1/dshm-v2026.10.01-1.tar.gz   → 404
```

这种不一致**从产物上极难看出来**，所以 CI 在编译任何东西之前就校验并失败。

发布流程因此简化为（`scripts/release.sh` 自动完成）：

```bash
./scripts/release.sh              # 自动取当天日期；当天已发过则自动加 -1/-2
./scripts/release.sh 2026.10.02   # 指定版本
./scripts/release.sh --dry-run    # 只看要做什么
```

同一天多次发布用序号区分（`2026.10.01`、`2026.10.01-1`、`2026.10.01-2`），
**已发布的号不再重用** —— 即使内容是坏的，也另起一个号，因为「这个版本存在过」本身
是有意义的信息。

### 10.4 镜像 tag 为什么带序号

镜像 tag 形如 `<dsh版本>-<日期>-<序号>`（`0.2.0-rc.2-2026.10.01-1`）：

| 部分 | 作用 |
|---|---|
| `0.2.0-rc.2` | 一眼看出镜像里是哪个 dsh |
| `2026.10.01` | 构建日期 |
| `-1` / `-2` | **同一天多次构建互不覆盖**，旧镜像仍可回退 |

序号不是装饰：如果 tag 只是 `<dsh版本>`，同一天第二次构建会**同名覆盖**第一次 ——
旧镜像失去引用后可能被回收，回退就没了。所以**不使用纯版本号 tag**。`latest` 指向最新
构建，但要精确复现某次构建必须用完整 tag。

## 11. CI 架构

### 11.1 作业图

```
changes ──> checks         (静态/离线：测试、面板 go test、可执行位、代理注入)
        └─> build          (构建镜像 → 推送前跑冒烟 → 通过才打正式 tag)
        └─> release-admin   (打 tag 时发 dshm 包与面板二进制)
```

`checks` 与 `build` **不互为依赖**，并行跑：`build` 自己负责在推送前验证镜像，
`checks` 只管纯静态检查。

### 11.2 镜像只构建一次

早期版本是 `checks` 用 `load: true` 构建一遍镜像跑冒烟、`build` 再构建一遍推送 ——
**同一个镜像构建两次**，白花一倍时间。

现在改成「一次构建 + 只改引用」：

1. 构建多平台镜像，推到**待检 tag**（`staging-<run id>`）
2. 从仓库**拉回 amd64** 那份，跑冒烟
3. 通过后用 `docker buildx imagetools create` 从同一个 digest 派生正式 tag（不重新构建）
4. `if: always()` 清理待检 tag

关键收益不只是省时间：**跑冒烟的就是将要发布的那个 digest**，不存在「测的是一份、
推的是另一份」的风险。待检 tag 带 run id，并发 run 之间互不干扰。

### 11.3 只改文档就跳过硬活

`changes` 作业用 `git diff --name-only` 判断改动范围，纯文档/License 改动跳过
`checks`、`build`、`release-admin`（实测纯文档推送约 5 秒完成）。

**但 `.github/workflows/*` 视为代码改动**：workflow 文件里放的是发布逻辑本身，
改了它却不跑一遍，这改动就永远不被验证 —— 这个坑真踩过一次（改了 latest release 的
上传逻辑，结果 `build`/`release-admin` 全被跳过，问题直到下一次代码改动才暴露）。

### 11.4 离线测试自动发现

`scripts/test-all.sh` 自动发现并运行 `scripts/test-*.sh`。原来 CI 里为每个测试脚本写
一个步骤、内容逐字重复（6 个步骤都是 `chmod +x a.sh && ./b.sh`），新增测试还得记得
加步骤；现在新增脚本会被自动跑到，CI 侧只有一个步骤。

（注意 `test-all.sh` 自己也匹配 `test-*.sh`，必须把自己排除，否则无限递归。）

### 11.5 面板发布

面板二进制与 dshm 包在**同一个 `release-admin` 作业**里产出：

* 打 tag → 发到该 tag 的 release（版本化，可回退）
* 推 main → 更新固定的 `latest` release，供没打 tag 的部署机安装

上传用**精确文件名**而不是 `dshm-*` 通配符：后者会匹配到工作区里生成发布包时留下的
**目录** `dshm-v<版本>/`，`gh` 会试图把目录当附件上传并失败（报错是
`read dshm-v<版本>: is a directory`，完全不会让人联想到通配符）。上传前还会清掉
`latest` 里的历史包，否则每发一版就多留一份旧包。
