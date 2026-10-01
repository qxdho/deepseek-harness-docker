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
| `proxy/test-inject.js` | HTML injection point (including the `<header>` / `<headless-…>` false positive), `X-Forwarded-For` recomputation, header legality, WebSocket upgrade forwarding (raw socket → 101) | no |
| `scripts/test-doctor.sh` | `dshm service doctor`'s hop classification: 101 / 2xx / 3xx / 4xx / no response, plus real handshakes against a stub upstream | no |
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
dshm-<tag>.tar.gz
└── dshm-<tag>/
    ├── dshm
    └── scripts/{env-config,migrate-home,admin}.sh
```

安装时先在临时目录解包并**全部**校验（结构、语法、特征串），任何一步不过都不碰现有
文件 —— 宁可继续用旧版本，也不能换成跑不起来的脚本。

### 10.3 命名规则：包名 = `dshm-<tag>.tar.gz`

**tag 名是唯一标识，包名直接从它派生。** 这条规则同时覆盖两类 tag：

| tag | 包名 |
|---|---|
| `v2026.10.01-1`（dshm 发布 tag） | `dshm-v2026.10.01-1.tar.gz` |
| `0.2.0-rc.2-2026.10.01-3`（镜像 tag） | `dshm-0.2.0-rc.2-2026.10.01-3.tar.gz` |

早先的写法是按 `v` + `VERSION` 拼包名，对 dshm 自己的 tag 勉强能对上，但对**镜像 tag**
（以数字开头、不带 `v`）必然错位：

```
要发布的东西  镜像 tag 0.2.0-rc.2-2026.10.01-3
按 VERSION 拼 dshm-v2026.10.01-1.tar.gz     ← 名字对不上
--to 请求    .../0.2.0-rc.2-2026.10.01-3/dshm-0.2.0-rc.2-2026.10.01-3.tar.gz  → 404
```

改成从 tag 名派生后，两类 tag 都自洽。**推 main 时没有 tag**，包名回退到
`dshm-v<VERSION>.tar.gz`（`latest` release 用的就是它）。

对内建版本号仍有一条硬约束：**dshm 发布 tag（`v*`）必须等于 `v` + `VERSION`**，CI 强制
校验。理由：那条路径下包名、release 地址、脚本里写死的版本号**全都从这一个号派生**。
镜像 tag 与 `VERSION` 无关，CI 对它们跳过这条校验（否则必然失败）。

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
changes ─┬─> checks          推 main / PR：静态与离线检查（测试、面板 go test、可执行位、代理注入）
         ├─> release-admin   推 main 与两类 tag：面板二进制 + dshm 发布包
         │
         └─ 打「镜像 tag」时（形如 <dsh版本>-<日期>-<序号>）：
             build-amd64     (ubuntu-latest)      构建 → 本地冒烟 → 推 :amd64-<run id>
             build-arm64     (ubuntu-24.04-arm)   构建 → 推 :arm64-<run id>
                    └─> merge-manifests   合成多平台 manifest 并打正式 tag
                             └─> cleanup-staging   删掉中间的单架构 tag
```

另有一个手动入口 `cleanup-versions`（`workflow_dispatch`），用来清理 GHCR 上的历史
标签；它要求 `confirm == 'DELETE'` 才会执行，且删除前有安全闸门（见 §11.6）。

几个刻意的分工：

* **`checks` 与镜像构建互不依赖**，各管各的。
* **推 main 不构建镜像** —— 多平台构建是整条流水线里最重的一块（几分钟），而日常推
  main 多数时候并不需要新镜像。要镜像就打镜像 tag。
* **两类 tag 各司其职**：`v*` 是 dshm 自己的发布 tag（发 release、跑一致性校验）；
  镜像 tag 以数字开头（构建并推送镜像）。两者的触发条件在 workflow 里显式区分 ——
  注意 GitHub 事件里 tag 推送的 `head_branch` **就是 tag 名**，所以只写
  `refs/tags/*` 会把两类混在一起。
* **`checks` 必须显式包含 PR**：PR 的 `github.ref` 是 `refs/pull/<N>/merge`，只判
  `refs/heads/main` 会让 PR 永远没有检查（这个洞真存在过）。

### 11.2 镜像为什么要按架构拆开构建

早期是「一台 runner 上构建多平台」——`docker buildx build --platform linux/amd64,linux/arm64`。
问题是 **arm64 在 x86 runner 上走 QEMU 模拟**，实测整个多平台构建 369 秒，占流水线
总耗时的 97%。

现在拆成两个作业，各跑在**原生 runner** 上（public 仓库的 `ubuntu-24.04-arm` 免费），
并行执行，最后用一个作业合并 manifest：

1. `build-amd64` 构建 → **先 `--load` 到本地跑冒烟** → 通过后才推 `:amd64-<run id>`
2. `build-arm64` 构建并推 `:arm64-<run id>`
3. `merge-manifests` 用 `docker buildx imagetools create` 把两个单架构 manifest
   合成多平台 manifest，**只改引用、不重新构建**
4. `cleanup-staging`（`needs: merge-manifests` + `if: result == 'success'`）删掉中间 tag

**为什么冒烟放在推正式镜像之前**：冒烟没过就不该产出可用于部署的镜像。
amd64 那份先 `--load` 到本地（这一步不推任何东西），过了才推单架构 tag；
正式的多平台 tag 由 `merge-manifests` 统一生成。

**中间 tag 为什么带 `run id` 而不是 commit SHA**：`concurrency.group` 按 `github.ref`
分组，而**同一个提交可以推多个 tag**（那是不同的 ref）→ 两个 run 属于不同并发组、
会同时跑。按 SHA 命名时它们会推同一个 `amd64-<sha>`，先完成的那个 run 执行
`cleanup-staging` 就把另一个正要用的 manifest 删了。带 run id 后互不重叠。

**为什么冒烟用本地 `--load` 而不是「推一个待检 tag 再拉回来」**：`docker buildx
imagetools` **只有 `create` 和 `inspect`，没有 `rm`** —— 待检 tag 推上去就删不掉，
会永久堆积。这条路试过，放弃了。
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

* 打 tag → 发到该 tag 的 release（版本化，可回退）。**两类 tag 都发**：
  dshm 发布 tag（`v*`）与镜像 tag（`<dsh版本>-<日期>-<序号>`）。后者也要发，是因为
  `dshm dshm update --to <镜像tag>` 需要那个 tag 下有 dshm 包 —— 否则只有镜像，自更新 404。
* 推 main → 更新固定的 `latest` release，供没打 tag 的部署机安装

包名一律从 **tag 名**派生（`dshm-<tag>.tar.gz`，见 10.3）；推 main 时没有 tag，回退到
`dshm-v<VERSION>.tar.gz`。**两条路径算出的包名必须一致** —— 曾经在 main 上误用
`${GITHUB_REF_NAME}`（那时它等于 `main`），生成 `dshm-main.tar.gz`，而 `latest` 更新那步
按 `v<VERSION>` 找包，于是失败。

上传用 `dshm-*.tar.gz`（**限定到 `.tar.gz` 结尾**）而不是 `dshm-*`：后者会匹配到工作区里
生成发布包时留下的**目录** `dshm-<tag>/`，`gh` 会试图把目录当附件上传并失败（报错是
`read dshm-<tag>: is a directory`，完全不会让人联想到通配符）。上传前还会清掉
`latest` 里的历史包，否则每发一版就多留一份旧包。

### 11.6 清理 GHCR 标签：两道闸门（都是踩坑后加的）

`cleanup-versions` 用来清理历史标签（`sha-*` 之类）。它有过一次**破坏性事故**：
为了删掉堆积的 92 个 `sha-*`，一次操作把整个包的镜像版本删光了 ——
`tags/list` 返回 null、所有 manifest 都是 unknown。

原因是两条叠加：

* **Registry 的 tag 与 version 是多对一的**：同一个 manifest 可以同时挂
  `latest` + `0.2.0-rc.2-2026.10.01-5` + `sha-a7810ba`；
* Delete version API **会连同该 version 的所有 tag 一起删**。

原来的筛选只看「tag 列表里**含** `sha-*`」，于是把那些同时带版本 tag 的 version
整条删走了。**更根本的问题是我没确认"删一个会带走什么"就执行了不可逆的批量操作。**

现在有两道闸门，缺一不可：

1. **安全闸门（脚本层）**：删除前**逐一看过该 version 的全部 tag**，只要有一个不属于
   「允许删」的集合（精确名单里的名字，或匹配给定前缀），就整条 `SKIP` 并打印
   「还挂着哪个 tag」。按这个逻辑重放那次事故，**93 个全会被跳过、一个都不会删**。
2. **确认闸门（流程层）**：`workflow_dispatch` 的 `confirm` 输入必须手打 `DELETE`，
   否则作业连跑都不跑。不可逆的批量删除不该是"点一下就跑"。

另外 `type=sha` 已经从构建配置里去掉了 —— 那个 tag 每次构建新增一个、从不回收
（实测堆到 92 个，占全部 tag 的 92%），而它的用途已被主 tag 覆盖。

## 12. 明确"不做"的几件事（免得反复被当成缺陷）

这一节的用途是**记录取舍**：下面这些在复审里会被点出来（"会话不可吊销"、"字段没被面板
用到"），但它们是权衡后的选择，不是遗漏。写在文档里，是为了让下一次看到的人先读这里，
而不是重新提一遍。

### 12.1 面板的会话不能"吊销"

会话 Cookie 就是 `HMAC(secret, 过期时间)` —— **无服务端状态**。所以：

* 没有"踢掉某个会话"的能力；
* 改口令**不会**让已发出的会话立刻失效（会话只认 secret 与过期时间）。

想要真正的吊销，必须引入服务端会话表（内存或文件），而面板是**只监听回环**的本机
管理工具（`admin/selfupdate.go` 与 `scripts/admin.sh` 都按这个前提写）。为它引入状态
存储，会带来"重启后面板登不进/状态文件损坏导致拒登"这类新故障面，收益很低。

真正需要立即失效全部会话时的做法是**换掉 `session_secret`**（`dshm admin install`
会重新生成配置），代价是所有会话一起失效 —— 对单管理员面板是合适的粒度。
（另外面板有登出按钮，那是"清除本机 Cookie"，与吊销不是一回事。）

### 12.2 `ContainerStatus.StartedAt` 面板不显示，但保留

它是 `/api/status` 的**对外字段**，脚本与别的消费者可以用它算运行时长。面板页面上没用
到它，不代表它是死代码 —— 删掉会破坏 API 兼容性，而它只占几个字节。

判断"死代码"的标准应当是**没有任何读取方**（例如之前删掉的 `dshm_raw_url`：全仓零引用、
且硬编码了错误的上游地址），而不是"当前这个页面没用它"。

### 12.3 日志解帧是**保守**的：认不出复用流就当原始文本

Docker 的非 TTY 日志是「8 字节头 + 负载」的复用流，TTY 容器则是原始流，两者在字节层面
可能撞脸（正文以 `01 00 00 00` 开头）。判定策略是"**至少要解析出两个合法帧**才算复用流"，
否则原样输出。

代价：一段"第一帧合法、第二帧被 8MB 截断"的复用流会被当成原始文本（会看到一点帧头噪音）。
收益：TTY 原文永远不会被按错误长度切碎。**日志是排查问题的最后依据，宁可难看也不能错。**
