# dsh Docker deployment

> The code and documentation in this project are largely AI-generated. The author has performed
> basic verification on a local machine, but the project has not been systematically tested.
> Review the code and configuration before using it in production.
>
> This is an unofficial project and is not affiliated with DeepSeek. dsh itself is pre-release.

## What this project is

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh) is an agent tool: you
interact with a model in a web UI, and the model can run commands and read or write files inside a
designated workspace.

Upstream dsh is installed with npm, started from the command line, listens on loopback only, and
authenticates with a one-time token. Deploying it on a server for browser access therefore requires
solving persistence, authentication, and reverse proxying separately. This project packages dsh as a
Docker image and covers those gaps.

```
browser ──▶ proxy (0.0.0.0:3080) ──▶ dsh (127.0.0.1:3079)
                                       ├── workspace
                                       └── data directory (config / credentials / sessions / plugins)
```

The repository provides:

- **Install script** `install.sh`: inspects `.env`, prompts only for missing values, then pulls the
  image, checks directories, and starts the service.
- **Login plugin**: [dsh-auth-gate](https://github.com/TecFancy/dsh-auth-gate) supplies the login
  page, password authentication, optional TOTP, and login rate limiting, replacing the upstream
  one-time token.
- **proxy**: dsh supports loopback listeners only (upstream rejects `--host 0.0.0.0`), so external
  access is handled by the proxy. It also fixes the settings page being unusable when dsh is reached
  via a LAN address or domain name.
- **`dshm` command**: deployment management, grouped into `service`, `auth`, `admin`, and `self`.
- **Admin panel**: a program that runs on the host, providing status, start/stop/restart, logs, disk
  usage, cache cleanup, and a console for running dshm commands.
- **Configurable paths**: data directory, workspace, port, bind address, and container UID are all
  configurable; the defaults work as-is.
- **Non-root execution**: the container runs as an unprivileged user with `cap_drop: ALL` and
  `no-new-privileges`, and file writes are confined to the workspace.

dsh's source is not modified; only its official extension mechanisms are used.

## Requirements

- Docker with compose v2.
- A directory for data. The default is `/dsh` on the host, which lives under the filesystem root and
  therefore requires `sudo` on first creation. If sudo is not available, use another directory; see
  "Data directory".

## Quick start

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
./install.sh
```

The installer checks `.env` item by item: values that are already valid are kept; items that are
unset but have a default (username, port, bind address, data directory, workspace, in-container
paths) **use that default without prompting**. Only required items without a default (the login
password) are asked for. Invalid legacy values are replaced by the default with a notice — for
example `DSH_HOME=/home/node/.dsh` becomes `/dsh`, and an empty workspace mount point becomes
`/workspace`. The password must be at least 14 characters and contain uppercase, lowercase, digits,
and symbols.

Then open `http://<host>:3080/` and sign in as `admin` with that password.

The service binds `127.0.0.1` by default, meaning it is reachable from the host only; a host-side
reverse proxy is normally required. To test with direct IP access first, set `DSH_BIND=0.0.0.0` in
`.env` and run `./install.sh` again.

The model API key can be set after signing in under **Settings → Model**, or in `.env` as
`DEEPSEEK_API_KEY=sk-...` followed by `./dshm service up`.

## Commands

`dshm` is organised into groups; run `dshm help` for the full list.

```bash
# service
./dshm service up          # start, or apply .env changes
./dshm service restart     # restart
./dshm service down        # stop (data is kept)
./dshm service status      # health / port / login user
./dshm service logs        # logs
./dshm service shell       # shell into the container
./dshm service update      # upgrade: pulls the new image from GHCR
./dshm service update --build   # rebuild the image locally (after changing repo code)
./dshm service disk        # disk usage

# auth
./dshm auth password       # change login password
./dshm auth user add bob   # add a user
./dshm auth totp enable    # enable two-factor authentication

# admin panel / self
./dshm admin install       # install the admin panel
./dshm self install        # register dshm as a system command
```

The original flat forms (`./dshm up`, `./dshm pw`, `./dshm user add ...`) still work, but are no
longer documented.

### Upgrade behaviour

`./dshm service update` **pulls the image by default and does not rebuild locally**. Images are
built by CI and pushed to GHCR, so a local rebuild is slow and yields no new version. Use
`./dshm service update --build` only when the pull fails or you need to verify unpublished changes
in the repository. Both paths wait for the container to become healthy afterwards and exit non-zero
with the logs if it does not.

A version can be passed directly, for example `./dshm service update 0.1.7-rc.2` (the value is
written to `DSH_IMAGE` before pulling).

## Admin panel

The admin panel is not a container; it is a program running on the host. It is installed by default
into the `/dsh-manager` directory:

```
/dsh-manager/dsh-admin        binary
/dsh-manager/config.json      configuration (password hash, session secret, listen address, ...)
/dsh-manager/dsh-admin.pid    pid file (only without systemd)
/dsh-manager/dsh-admin.log    log (only without systemd)
```

It provides container status and health, start/stop/restart, logs, Docker disk usage, cleanup of
dangling images and build cache, and a web console for running dshm commands (an allowlist, not a
free-form shell).

```bash
./dshm admin install     # install; default directory /dsh-manager
./dshm admin url         # print the address, default http://127.0.0.1:3090/
./dshm admin password    # change the panel password
./dshm admin status      # show whether it is running
./dshm admin uninstall   # stop and remove
```

With root or passwordless sudo the panel runs under systemd and starts on boot; otherwise it runs in
the background via a pid file and does not start automatically. It listens on `127.0.0.1` only;
for remote access use an SSH tunnel: `ssh -L 3090:127.0.0.1:3090 user@host`.

To change the install directory, set `DSH_ADMIN_DIR=$HOME/dsh-manager` in `.env`; a directory under
your home directory needs no sudo.

Note that the panel holds `docker.sock`, which is equivalent to host root. It therefore listens on
`127.0.0.1` only and must not be exposed to the public internet.

## Configuration

Changes in `.env` take effect after `./dshm service up`. `restart` does not recreate the container,
so environment variables are not re-read.

| Variable | Default | Notes |
|---|---|---|
| `DSH_AUTH_PASSWORD` | none (required) | Used to create the account on first start; ≥14 characters with upper/lower/digit/symbol. Change later with `./dshm auth password` |
| `PROXY_PORT` | `3080` | Host port |
| `DSH_BIND` | `127.0.0.1` | Set to `0.0.0.0` for direct LAN access |
| `DSH_HOME_HOST` | `/dsh` | Host data directory. Under the filesystem root, so first creation needs sudo; another directory such as `/home/user/dsh` also works. Must be an absolute path |
| `DSH_HOME` | `/dsh` | In-container data directory; must match the mount target of `DSH_HOME_HOST`. This value is the root itself; no `.dsh` is appended |
| `DSH_WORKSPACE` | `/dsh/workspace` | Host workspace directory; follows the data directory by default. Must be an absolute path |
| `DSH_WORKSPACE_CONTAINER` | `/workspace` | In-container workspace path |
| `DSH_UID` / `DSH_GID` | `1000` / `1000` | Container identity. Set to `id -u` / `id -g` when the host UID differs |
| `DSH_TOTP` | `optional` | `off`, `optional`, or `required` |
| `DSH_COOKIE_SECURE` | `0` | Set to `1` for HTTPS; must remain `0` over plain HTTP |
| `DSH_PUBLIC_HOST` | empty | Domain shown on the login page |
| `DSH_TRUST_XFF` | `0` | When `1`, the proxy trusts `X-Forwarded-For` for client-address detection behind a reverse proxy. Enable only when a proxy really rewrites that header |
| `DSH_DISK_MIN_MB` | `256` | Minimum free disk space (MB) required at start-up |
| `DSH_ADMIN_DIR` | `/dsh-manager` | Admin panel install directory. Read by `dshm`, so `$HOME` may be used |

Build-time variables (a rebuild is required): `DSH_VERSION`, `AUTH_GATE_VERSION`, `DEV_TOOLS`.
`DSH_IMAGE` selects which image is pulled or built, and `./dshm service update` writes it as needed.

Two points to keep in mind:

- The username and password only apply on the **first start**, when no user file exists yet.
- `AUTH_GATE_VERSION` only applies when the profile is absent. To force a re-seed:
  `docker exec qxdho-dsh rm -rf /dsh/profiles/web && ./dshm service up`.

## Data directory

Both the data directory and the workspace are bind mounts, and both paths are configurable:

```bash
DSH_HOME_HOST=/dsh                    # host data directory
DSH_HOME=/dsh                         # in-container mount point
DSH_WORKSPACE=/dsh/workspace          # host workspace
DSH_WORKSPACE_CONTAINER=/workspace    # in-container workspace path
```

`DSH_HOME` is the root itself; no `.dsh` is appended (setting it to `/data` places the data directly
under `/data`). The host directory must be writable by the container UID (1000 by default). The
preflight check verifies this and repairs it when permissions allow, otherwise it prints the
required command.

Contents of the data directory:

| Path | Contents |
|---|---|
| `settings.yaml` | UI settings: default model, UI preferences |
| `.credentials.yaml` | Model API keys and other credentials, plus the session cookie signing secret (changing it forces everyone to sign in again) |
| `profiles/` | Profiles (`web`, ...): configuration files and `node_modules`; plugins are installed here |
| `sessions/` | Session records |
| `storages/` | Plugin and tool state |
| `attachments/` | Uploaded attachments |
| `llm-deepseek/` | Local cache for the DeepSeek provider |
| `home/` | HOME placeholder used by tools |

Backing up this directory backs up the login users, sessions, plugins, and credentials. Do not
delete it.

### Upgrading from an older version

Older versions stored data in the named volume `dsh-home`; the current version uses bind mounts. That
migration is built in, so upgrading only takes:

```bash
git pull --ff-only      # fetch the current scripts
docker rm -f dsh        # the old container name; check docker ps -a first
./install.sh            # migrates automatically when needed, then starts
```

The automatic migration runs only when a legacy volume exists **and** `DSH_HOME_HOST` is an empty
directory: the source volume is mounted read-only, the old volume is **not** deleted afterwards, so
the change stays reversible. If a container still holds the volume, only containers whose name or
image belongs to this project are stopped; if another container holds it, migration is skipped with
a notice.

In any other case, run it explicitly:

```bash
./dshm service migrate-home
```

The command refuses to run when the destination is not empty, so existing data is never overwritten.

## Directory ownership and permissions

If the host directory is owned by root (for example when `docker compose up` is run directly and the
directory is created by dockerd), a process running as UID 1000 inside the container cannot write to
it. The symptom is a container that keeps restarting, or the agent reporting:

```
EACCES: permission denied, mkdir '/workspace/xxx'
```

`./install.sh` and `./dshm service up` check this before starting and repair it when root or
passwordless sudo is available; otherwise they print the command to run manually.

When the workspace is not writable, the container does not exit. It falls back to
`$DSH_HOME/.workspace` and logs a notice, avoiding an endless restart loop under
`restart: unless-stopped`. Set `DSH_WORKSPACE_STRICT=1` to make it exit instead.

Manual repair:

```bash
sudo chown -R 1000:1000 /dsh && ./dshm service up

# Or use a directory you own (no sudo)
mkdir -p /home/user/dsh-data
# then edit .env (absolute paths only: Compose does not expand ~ or $HOME):
#   DSH_HOME_HOST=/home/user/dsh-data
#   DSH_WORKSPACE=/home/user/dsh-data/workspace
./dshm service up
```

If the host UID is not 1000 (macOS Docker Desktop, NAS systems), make the container use the same
identity by setting in `.env`:

```bash
DSH_UID=1001          # id -u
DSH_GID=1001          # id -g
```

## Troubleshooting

**The page does not open**: run `./dshm service logs`. The first start takes about ten seconds.

**The container keeps restarting**: usually incorrect ownership of the data directory or workspace;
the log states which one.

**The proxy keeps printing `socket hang up` and the log contains
`disabling profile plugin row "storage-domain"`**: the profile was seeded by an older image and is
missing a peer symlink. Current versions repair this at startup; on an older image, re-seed once:

```bash
docker exec qxdho-dsh rm -rf /dsh/profiles/web && ./dshm service up
```

**The service crashes after installing a plugin, or the log contains `No space left on device`**:
the disk is full. Inspect usage and clean up:

```bash
./dshm service disk
docker exec qxdho-dsh rm -rf /dsh/.npm /tmp/npm-cache
docker image prune -a && docker builder prune
```

**The password is correct but the login page keeps coming back**: `DSH_COOKIE_SECURE=1` is set while
the service is served over plain HTTP; set it to `0`.

**Upgrading from an older version**: the container was renamed from `dsh` to `qxdho-dsh`; remove the
old container first with `docker rm -f dsh`. Older data lives in the named volume `dsh-home`, and
`./install.sh` (or `./dshm service up`) migrates it automatically once the legacy volume is found and
the host directory is still empty. If that was skipped, run `./dshm service migrate-home`; see
"Upgrading from an older version".

**The data is gone after upgrading**: the host directory already contained something, so the
automatic migration was skipped. Run `./dshm service migrate-home` to see why (a non-empty
destination is refused explicitly).

## Third-party components

- [dsh-auth-gate](https://github.com/TecFancy/dsh-auth-gate) (MIT, v0.15.0): login page, sessions,
  TOTP, rate limiting, token-to-cookie bridge
- `http-proxy` (MIT), `tini`, `pnpm`, `node:24-bookworm-slim`

## License

MIT. DeepSeek Harness and dsh-auth-gate are licensed separately.

See [SECURITY.md](SECURITY.md) for security notes.
