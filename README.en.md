# dsh one-click deploy image (DeepSeek Harness + login gate)

Packages the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`@deepseek-ai/dsh`)
web UI into a deployable Docker image with a built-in login page and optional TOTP.

- **No more copying the launch token** — the login plugin exchanges dsh's one-time token for a
  session cookie inside the container.
- **Real login page** — username/password, optional TOTP, rate limiting.
- **Ready out of the box** — GitHub Actions builds a multi-arch image and pushes it to GHCR.
- **Least privilege** — non-root, `cap_drop: ALL`, `no-new-privileges`, `workspace-write` (Landlock).

## Features

| Feature | Description |
|---|---|
| Login gate | Username/password login page, optional TOTP two-factor, rate limiting |
| No token copying | The plugin exchanges dsh's one-time launch token for a session cookie inside the container |
| One-command deploy | `./install.sh` asks once for a password, then does everything |
| LAN/domain friendly | Fixes `crypto.randomUUID` (non-secure context) and the "Settings unavailable" client check |
| Persistent | Config, credentials, sessions and login users live in the `dsh-home` volume |
| Management CLI | `./dshm` up/down/logs/status/password/update |
| Update | `./dshm update` (rebuilds the pinned image) |
| Hardened | Non-root, `cap_drop: ALL`, `no-new-privileges`, `workspace-write` (Landlock) |
| Agent toolchain | git, ripgrep, jq, curl, rsync, python3, pnpm preinstalled |
| CI | Multi-arch (amd64/arm64) build to GHCR + real container smoke test |
| Host-level HTTPS | TLS is terminated by your host proxy (Nginx/BaoTa/Cloudflare) |

## Quick start

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
./install.sh          # asks once for a password
```

Open `http://<host>:3080/`, sign in with `admin` + your password.

## Relationship to official dsh

Official `@deepseek-ai/dsh` is a CLI. This project is a **deployment shell around it** and does not modify its
source; it only uses dsh's official extension points (profile bundles, `--patch`, the `__DSH_TRANSPORT__` seam).

| Capability | Official dsh | This project |
|---|---|---|
| Deployment | npm/npx; no official Docker support | Docker image + compose, `./install.sh` |
| Network | loopback only; `--host 0.0.0.0` rejected | proxy exposes it, dsh stays on loopback |
| Auth | one-time token → signed cookie; no login page/users/TOTP | login page + password + optional TOTP + rate limiting + user management (via plugin) |
| Token UX | you copy the startup URL | bridged automatically; the token is never shown |
| LAN/domain | Settings unavailable off-localhost; no `randomUUID` in non-secure contexts | injected patch fixes both |
| Hardening | sandbox available but you configure it | non-root, `cap_drop`, `workspace-write` defaults |

## What this project adds (on top of dsh and the plugin)

- **Official dsh** provides the agent runtime, Web UI, token auth, sandbox and plugin system.
- **`dsh-auth-gate`** (third party) provides the login page, sessions, TOTP, rate limiting, user CLI and the
  launch-token bridge.
- **This project provides everything else**: the forward proxy (Host/Origin rewrite to loopback, so no
  `--trusted-host` config), the front-end injection (`randomUUID` + `ownsHost`, which the plugin deliberately
  does not do), the image engineering (multi-stage build, pre-installed plugin profile, first-boot seeding and
  admin creation, `.env`-driven config), the `--expose-internals` wrapper, hardening defaults, the ops CLI
  (`install.sh`, `dshm`, healthcheck, smoke test), the CI pipeline, and the docs.

## Architecture

```
browser -> proxy 0.0.0.0:3080 -> dsh 127.0.0.1:3079 (web profile + dsh-auth-gate)
                |-- rewrites Host/Origin consistently to the loopback authority
                '-- injects crypto.randomUUID polyfill + __DSH_TRANSPORT__.ownsHost
```

dsh refuses `--host 0.0.0.0`, so dsh stays on loopback and the proxy exposes it.
The proxy does **not** authenticate and does **not** modify dsh's files; login, sessions, TOTP and the
token→cookie bridge are handled in-process by [`dsh-auth-gate`](https://github.com/TecFancy/dsh-auth-gate).

## Why rewriting Host is safe

dsh's session cookie has **no `Domain` attribute**, so the browser scopes it to the site it is
visiting. The cookie *name* is derived from the `Host` dsh receives; as long as the proxy forwards a
consistent Host, the name always matches and the cookie stays valid. Measured on real dsh: browsing
`lan.test:3099` while the proxy rewrites Host to `127.0.0.1:3080` yields **HTTP 200** with the cookie.
`ERR_TOO_MANY_REDIRECTS` is caused by re-injecting the token on every request, not by rewriting Host.

## HTTPS (done on the host, not in Docker)

HTTP only by default (trusted LAN, and the port binds to `127.0.0.1`). For the internet, terminate TLS with
whatever you already run **on the host** (Nginx, BaoTa, Cloudflare Tunnel) and reverse-proxy it to the
container's `127.0.0.1:3080`. The host proxy must forward WebSocket, and you should set
`DSH_COOKIE_SECURE=1` and `DSH_PUBLIC_HOST=your.domain`. No `--trusted-host` configuration is needed:
the in-container proxy rewrites Host/Origin to loopback consistently.

## Persistence

`dsh-home` volume → `/home/node/.dsh` (config, credentials, sessions, login users) and
`./workspace` → `/workspace`. Recreating the container does not log you out.

## Workspace permissions

`./workspace` is a **bind mount** at `/workspace`, and a bind mount shadows the ownership
set inside the image. The agent runs as `node` (UID 1000), so the host directory must be
writable by UID 1000. If Docker created the directory for you (a missing bind-mount source
is created by the daemon **as root**), the agent fails with:

```
EACCES: permission denied, mkdir '/workspace/xxx'
```

`./install.sh` and `./dshm up` check this **against the container UID (1000 by default)**
before starting the container and fix it when run as root or with passwordless `sudo`. A plain
"can the current user write?" test is not enough: on a root deploy `root:root 0755` is writable
by root but not by UID 1000.

When those wrappers are bypassed (bare `docker compose up -d`, a panel restarting the container),
the entrypoint re-checks at startup. If `/workspace` is unwritable it does **not** exit — a
non-zero exit under `restart: unless-stopped` becomes an endless restart loop — it degrades to a
writable in-container directory (`$DSH_HOME/workspace`), keeps the UI reachable, and logs a loud
banner. Set `DSH_WORKSPACE_STRICT=1` to restore fail-fast. To fix it by hand:

```bash
# Option 1 — take ownership (directory already exists)
sudo chown -R 1000:1000 ./workspace

# Option 2 — point DSH_WORKSPACE at a directory you own (no sudo needed)
mkdir -p ~/dsh-workspace
echo 'DSH_WORKSPACE=~/dsh-workspace' >> .env
docker compose down && docker compose up -d
```

> Changing `DSH_WORKSPACE` requires `down` + `up`, not `restart` — environment variables are
> only read when the container is created.

**Host user is not UID 1000?** (common on macOS Docker Desktop and NAS boxes) run the
container as your own user instead:

```bash
docker run --user "$(id -u):$(id -g)" \
  -e HOME=/home/node -e DSH_HOME=/home/node/.dsh \
  -v "$HOME/dsh-home:/home/node/.dsh" \
  -v "$HOME/dsh-workspace:/workspace" \
  -p 127.0.0.1:3080:3080 \
  --env-file .env \
  ghcr.io/qxdho/deepseek-harness-docker:latest
```

With `docker compose`, add `user: "${MY_UID}:${MY_GID}"` to the `dsh` service and set
`MY_UID=$(id -u)` / `MY_GID=$(id -g)` in `.env`. A named volume is also a no-chown option —
Docker seeds it with the image's ownership — at the cost of not seeing files on the host.

## Update

```bash
./dshm update [version]          # rebuilds the pinned image
```

## Third-party components

| Component | Source | License | Role here |
|---|---|---|---|
| `@deepseek-ai/dsh` | DeepSeek Harness | upstream | the agent runtime + Web UI |
| `dsh-auth-gate` | [TecFancy/dsh-auth-gate](https://github.com/TecFancy/dsh-auth-gate) | MIT | login page, sessions, TOTP, rate limiting, token bridge |
| `http-proxy` | http-party | MIT | forward proxy |
| `tini` | krallin | MIT | container init |
| `pnpm` | pnpm | MIT | plugin management |

No source of these components is modified.

See [README.md](README.md) (Chinese) for the full documentation. MIT licensed.
