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
