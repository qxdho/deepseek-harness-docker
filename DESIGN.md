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

`${DSH_WORKSPACE:-/dsh/workspace}:${DSH_WORKSPACE_CONTAINER:-/workspace}` is a bind mount, and **a bind mount shadows whatever the
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

1. **Host side** — `scripts/preflight.sh` runs from `install.sh` and `dshm up` *before* `compose up`.
   Creating the directory while the user still owns it is the whole fix. If it already exists with the
   wrong owner, it chowns via `sudo` when available and otherwise prints the exact command.
2. **Container side** — `entrypoint.sh` probes writability of `/workspace` early (before dsh starts). If it
   is not writable it prints the same actionable message and then **degrades to `$DSH_HOME/workspace`**
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
  `DSH_WORKSPACE`), because `sudo ./install.sh` does not export `.env` into the shell.
- **Moving the container user.** Running the entrypoint as root to `chown`, then dropping via `setpriv`
  (available in the image), would silently defeat `DSH_PERMISSION_MODE=workspace-write`: Landlock does not
  confine root. Same reason as §5.1.

The data directory is a **host bind mount** (`DSH_HOME_HOST`, default `/dsh`, mounted at `DSH_HOME`,
default `/dsh`), so its ownership comes from the host like the workspace. `check_dsh_home_dir()` applies the
same container-UID rule and repairs it with `chown` (root or passwordless `sudo`) — no named volume and no
disposable root container involved.

Container path and host path are both configurable (`DSH_HOME`, `DSH_HOME_HOST`), and so is the workspace
(`DSH_WORKSPACE_CONTAINER`, `DSH_WORKSPACE`, default `DSH_HOME_HOST/workspace`). All are read from `.env`,
so compose, the preflight and `dshm` cannot drift apart.

## 6. Verification

| Layer | What it covers | Needs Docker |
|---|---|---|
| `scripts/test-preflight.sh` | workspace ownership checks (paths, quoting, non-writable, deployer-vs-container UID, `DSH_UID` resolution), `dsh-home` volume name resolution, both entrypoint workspace paths | no |
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
