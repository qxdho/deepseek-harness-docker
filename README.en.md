# dsh one-click deploy image (DeepSeek Harness + login gate)

Packages the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`@deepseek-ai/dsh`)
web UI into a Docker image with a built-in login page, optional TOTP, and no token copying.

> Unofficial community project. dsh is pre-release — see [SECURITY.md](SECURITY.md).

## Quick start

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
./install.sh          # asks once for a password
```

Open `http://<host>:3080/`, sign in with `admin` + your password.

Set the model in **Settings → Model**, or add `DEEPSEEK_API_KEY=sk-...` to `.env` and run `./dshm service up`.

> Binds `127.0.0.1` by default. For direct IP access set `DSH_BIND=0.0.0.0` and re-run `./install.sh`.

## Relationship to official dsh

This project is a **deployment shell** around dsh. It does not modify dsh's source; it uses dsh's
official extension points (profile bundles, the `__DSH_TRANSPORT__` seam).

| | Official dsh | This project |
|---|---|---|
| Deployment | npm CLI | Docker image, one command |
| Auth | one-time token | login page + password + optional TOTP + rate limiting |
| Network | loopback only (`--host 0.0.0.0` rejected) | proxy exposes it, dsh stays on loopback |
| LAN/domain | Settings unavailable off-localhost | fixed (`randomUUID` + `ownsHost` injection) |
| Hardening | you configure it | non-root, `cap_drop: ALL`, `workspace-write` |

```
browser -> proxy 0.0.0.0:3080 -> dsh 127.0.0.1:3079 (web profile + dsh-auth-gate)
```

The proxy does **not** authenticate and does **not** touch dsh's files. Host/Origin are rewritten
consistently to loopback, so no `--trusted-host` configuration is needed.

## Configuration

All in `.env`. Apply changes with `./dshm service up` (`restart` does not recreate the container).

| Variable | Default | Notes |
|---|---|---|
| `DSH_AUTH_PASSWORD` | — (**required**) | Used on first boot; ≥14 chars with upper/lower/digit/symbol. Change later with `./dshm auth password` |
| `PROXY_PORT` | `3080` | Host port |
| `DSH_BIND` | `127.0.0.1` | `0.0.0.0` = reachable on the LAN |
| `DSH_HOME_HOST` | `/dsh` | **Host** data dir (bind source). Under `/` by default, so the first run needs `sudo`; `$HOME/dsh` works too |
| `DSH_HOME` | `/dsh` | **In-container** data dir (bind target); it is the root itself, no extra `.dsh` |
| `DSH_WORKSPACE` | `/dsh/workspace` | **Host** workspace dir (follows `DSH_HOME_HOST` by default) |
| `DSH_WORKSPACE_CONTAINER` | `/workspace` | **In-container** workspace path |
| `DSH_UID` / `DSH_GID` | `1000` / `1000` | Container identity. Set to `id -u` / `id -g` when your host UID differs |
| `DSH_TOTP` | `optional` | `off` / `optional` / `required` |
| `DSH_COOKIE_SECURE` | `0` | **Must be 0 over HTTP**; set `1` for HTTPS |
| `DSH_PUBLIC_HOST` | empty | Domain shown on the login page |

Build-time variables (rebuild required): `DSH_VERSION`, `AUTH_GATE_VERSION`, `DEV_TOOLS`, `DSH_IMAGE`.

> `DSH_AUTH_USER` / `DSH_AUTH_PASSWORD` only apply on first boot (no user file yet).
>
> `AUTH_GATE_VERSION` only applies when the volume has no profile yet. To force a re-seed:
> ```bash
> docker exec qxdho-dsh rm -rf /dsh/profiles/web && ./dshm restart
> ```

## Commands

```bash
# service
./dshm service up          # start, or apply .env changes
./dshm service restart     # restart
./dshm service down        # stop (data kept)
./dshm service status      # health / port / login user
./dshm service logs        # logs
./dshm service shell       # shell into the container
./dshm service update      # upgrade dsh

# auth
./dshm auth password       # change login password
./dshm auth user add bob   # add a user
./dshm auth totp enable    # enable two-factor

# panel / self
./dshm admin install       # install the Docker admin panel (host or container)
./dshm self install        # register dshm as a system command
```

> Flat legacy forms (`./dshm service up`, `./dshm auth password`, …) still work.

## HTTPS

Terminate TLS on the host with whatever you already run (Nginx, BaoTa, Cloudflare Tunnel) and
reverse-proxy to `127.0.0.1:3080`. The host proxy must forward WebSocket. Then set
`DSH_COOKIE_SECURE=1` and `DSH_PUBLIC_HOST=your.domain`.

## Persistence

| Location | Contents |
|---|---|
| Host `DSH_HOME_HOST` (default `/dsh`) | config, credentials, sessions, login users — bind-mounted at the container `DSH_HOME` |
| Host `DSH_WORKSPACE` (default `DSH_HOME_HOST/workspace`) | agent working files — bind-mounted at `DSH_WORKSPACE_CONTAINER` |

Recreating the container does not log you out. Back up the host data directory. **Do not delete that
directory** (`rm -rf /dsh` really deletes the data).

Upgrading from the old named volume: `./dshm service migrate-home`.

## Workspace permissions

The workspace is a host directory bind-mounted at `/workspace` (default `/dsh/workspace`), and **a bind mount shadows the image's ownership**.
The directory must therefore be writable by the container UID (1000 by default), or the agent fails:

```
EACCES: permission denied, mkdir '/workspace/xxx'
```

`./install.sh` and `./dshm service up` check this against the container UID and fix it (as root or with
passwordless `sudo`) before starting. With a bare `docker compose up -d` the container re-checks:
if unwritable it does **not** exit (a non-zero exit under `restart: unless-stopped` becomes an
endless restart loop) — it degrades to `$DSH_HOME/workspace`, keeps the UI reachable, and logs a
banner. `DSH_WORKSPACE_STRICT=1` restores fail-fast.

Fix by hand:

```bash
sudo chown -R 1000:1000 /dsh && ./dshm service up

# Or use a directory you own (no sudo)
mkdir -p ~/dsh-workspace
echo 'DSH_WORKSPACE=~/dsh-workspace' >> .env
./dshm service up
```

**Host UID is not 1000?** (macOS Docker Desktop, NAS) set in `.env`:

```bash
DSH_UID=1001          # id -u
DSH_GID=1001          # id -g
```

The container then runs as you, so bind-mount ownership matches. preflight checks and repairs the data dir and workspace ownership for the same UID. Re-run
`./dshm service up` after changing these.

## Troubleshooting

**Page does not open** → `./dshm logs`. First start takes ~10 s.

**Container keeps restarting** → host workspace ownership; the log contains `/workspace 不可写`.
See Workspace permissions.

**Password rejected, bounced back to login** → `DSH_COOKIE_SECURE=1` over plain HTTP; set `0`.

**Upgrading from an older version** → the container was renamed from `dsh` to `qxdho-dsh`:

```bash
docker rm -f dsh && ./dshm service up
```

## Third-party components

- [`dsh-auth-gate`](https://github.com/TecFancy/dsh-auth-gate) (MIT, v0.15.0) — login page, sessions, TOTP, rate limiting, token bridge
- `http-proxy` (MIT), `tini`, `pnpm`, `node:24-bookworm-slim`

No source of these components is modified.

## License

MIT. DeepSeek Harness and `dsh-auth-gate` are licensed separately.
