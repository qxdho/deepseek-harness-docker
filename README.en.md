<p align="center">
  <b>deepseek-harness-docker</b><br/>
  <sub>Package DeepSeek Harness into a one-command Docker service with a built-in login gate</sub>
</p>

<p align="center">
  <a href="./LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-b8863b?style=flat-square&labelColor=101f38"></a>
  <a href="https://github.com/qxdho/deepseek-harness-docker/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/qxdho/deepseek-harness-docker?style=flat-square&labelColor=101f38&color=b8863b"></a>
  <a href="https://github.com/qxdho/deepseek-harness-docker/issues"><img alt="Issues" src="https://img.shields.io/github/issues/qxdho/deepseek-harness-docker?style=flat-square&labelColor=101f38&color=b8863b"></a>
  <a href="./SECURITY.md"><img alt="Security" src="https://img.shields.io/badge/security-policy-b8863b?style=flat-square&labelColor=101f38"></a>
</p>

<p align="center">
  <a href="./README.md">简体中文</a> · <b>English</b>
</p>

<p align="center">
  <a href="#what-this-project-is">Overview</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#management-cli">CLI</a> ·
  <a href="#admin-panel">Admin Panel</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="#data-directory-and-permissions">Data &amp; Permissions</a> ·
  <a href="#https-and-reverse-proxy">HTTPS</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="#third-party-components">Third-party Components</a> ·
  <a href="#license">License</a>
</p>

> [!IMPORTANT]
> The code and documentation in this project are largely **AI-generated**. The author has performed
> basic verification on a local machine, but the project has **not been systematically tested**.
> Review the code and configuration before using it in production.

> [!NOTE]
> This is an **unofficial project** and is not affiliated with DeepSeek. dsh itself is pre-release.
> See [SECURITY.md](./SECURITY.md) for the security boundary and known risks, and
> [DESIGN.md](./DESIGN.md) for design trade-offs.

## What this project is

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh) is an agent tool: you talk
to a model in the browser, and the model can run commands, read and write files, and complete tasks
inside a designated workspace.

The official distribution is installed via npm and started from the command line. It listens on
loopback only and authenticates with a one-time token. Deploying it long-term on a server for
browser access therefore also means solving persistence, authentication and reverse proxying
yourself. This project packages dsh as a Docker image and fills those gaps.

```
browser ──▶ proxy (0.0.0.0:3080) ──▶ dsh (127.0.0.1:3079)
                                        ├── workspace
                                        └── data directory (config / credentials / sessions / plugins)
```

| Limitation of official dsh | What this project does |
|---|---|
| Loopback only, cannot be exposed | Adds a forwarding proxy; dsh itself still listens on loopback |
| You must copy the token-bearing URL at every start | The login plugin exchanges the one-time token for a session cookie inside the container; the token never appears |
| No login; anyone who can reach it can use it | The login plugin adds a login page, password auth, optional TOTP and login rate limiting |

The repository consists of:

- **Installer** `install.sh` — checks `.env`, only prompts for missing values, reuses existing config,
  then pulls the image, prepares directories and starts the service.
- **Login plugin** — [dsh-auth-gate](https://github.com/TecFancy/dsh-auth-gate) provides the login page,
  password authentication, optional TOTP and rate limiting, replacing the official one-time token.
- **proxy** — dsh refuses `--host 0.0.0.0`, so external access is handled by this forwarding proxy. It
  also fixes the settings page being unusable over LAN/domain access.
- **`dshm` CLI** — deployment management, grouped into `service`, `auth`, `admin` and `self`.
- **Admin panel** — a host-side program for status, start/stop, logs, disk usage and cache cleanup,
  plus a console for running `dshm` commands.
- **Non-root runtime** — the container runs as an unprivileged user with `cap_drop: ALL` and
  `no-new-privileges`; writes are confined to the workspace (Landlock `workspace-write`).

This project **does not modify dsh's source**; it only uses official extension points.

## Quick Start

Requirements: Docker with compose v2, plus a directory to hold data. The default is the host path
`/dsh`, which lives at the filesystem root and needs sudo the first time. If sudo is not an option,
point it elsewhere — see [Data Directory and Permissions](#data-directory-and-permissions).

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
./install.sh          # asks for the login password once
```

The installer inspects `.env` item by item: valid existing values are kept; unset values that have a
default (username, port, bind address, data directory, workspace, in-container paths) **take the
default silently**; only required values without a default (the login password) are prompted for.
Passwords must be at least 14 characters and mix upper case, lower case, digits and symbols.

After reading the configuration it prints the **effective configuration** (port, data directory,
workspace, runtime identity, login and image), marking each item as `default` or `changed`.

Then open `http://<server-ip>:3080/` and sign in as `admin` with the password you set.

> [!TIP]
> The service binds `127.0.0.1` by default, so only the host can reach it — you will usually want a
> reverse proxy on the host. To test with a direct IP first, set `DSH_BIND=0.0.0.0` in `.env` and run
> `./install.sh` again.

You can set the model key after signing in under **Settings → Model**, or put `DEEPSEEK_API_KEY=sk-...`
in `.env` and run `./dshm service up`.

### Manual deployment

Without the installer, the equivalent steps are:

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
cp .env.example .env     # edit as needed; at minimum set DSH_AUTH_PASSWORD
docker compose pull      # pull the image built on GHCR
docker compose up -d     # start the service
```

### Upgrading

```bash
./dshm service update              # pull the new image from GHCR (no local rebuild)
./dshm service update --build      # force a local rebuild (when you changed repo code)
./dshm service update 0.1.7-rc.2   # pin a specific version
```

Images are built by CI and pushed to GHCR; a local rebuild is slow and yields nothing newer. Use
`--build` only when the pull fails or you need to validate uncommitted repository changes. Both paths
wait for the container to become healthy and exit non-zero with logs if it does not.

## Management CLI

`dshm` is grouped by purpose; run `dshm help` for the full list. `./dshm self install` registers it as
a system command so you can call `dshm` from any directory.

```bash
# service
./dshm service up          # start, or apply .env changes
./dshm service restart     # restart
./dshm service down        # stop (data kept)
./dshm service status      # health / port / login user
./dshm service logs        # logs
./dshm service shell       # shell into the container
./dshm service update      # upgrade
./dshm service disk        # disk usage and cleanup commands

# login and accounts
./dshm auth password       # change the login password
./dshm auth user add bob   # add a user
./dshm auth totp enable    # enable two-factor auth

# admin panel / self
./dshm admin install       # install the admin panel
./dshm self install        # register dshm as a system command
```

| Group | Subcommand | Description |
|---|---|---|
| `service` | `up` / `down` / `restart` | Start, stop, restart (`up` and `restart` both re-read `.env`) |
| `service` | `status` / `logs` / `disk` | Status, logs, disk usage and cleanup commands |
| `service` | `update` / `version` / `shell` | Upgrade, show the dsh version inside the container, open a shell |
| `service` | `url` / `migrate-home` | One-time launch URL (troubleshooting), migrate an old named volume |
| `auth` | `password` / `user` / `totp` | Password, user management, two-factor auth |
| `admin` | `install` / `uninstall` / `url` / `password` / `status` / `logs` | Host-side admin panel |
| `self` | `install` / `uninstall` | Register `dshm` as a system command |

The older flat forms (`./dshm up`, `./dshm pw`, `./dshm user add ...`) still work but are no longer
documented.

## Admin Panel

The admin panel is not a container; it is a program that runs on the host, installed by default at
`/dsh-manager`:

```
/dsh-manager/dsh-admin        program
/dsh-manager/config.json      config (password hash, session key, listen address, …)
/dsh-manager/dsh-admin.pid    pid file (written when systemd is unavailable)
/dsh-manager/dsh-admin.log    log (written when systemd is unavailable)
```

It shows container status and health check results, starts/stops/restarts, shows logs, reports Docker
disk usage, prunes dangling images and build cache, and offers a web console for `dshm` commands
(whitelisted commands only — not a free shell).

With root or passwordless sudo it runs under systemd and starts on boot; otherwise it runs in the
background with a pid file and does not auto-start. To change the install directory, set
`DSH_ADMIN_DIR=$HOME/dsh-manager` in `.env` — placing it under your home directory removes the need
for sudo.

> [!WARNING]
> The panel holds `docker.sock`, which is **equivalent to host root**. It therefore listens on
> `127.0.0.1` only and must not be exposed to the public internet. For remote access use an SSH
> tunnel: `ssh -L 3090:127.0.0.1:3090 user@server`.

## Configuration

Edit `.env` and run `./dshm service up` to apply. `restart` does not recreate the container, so
environment variables are not re-read.

Naming convention: project settings are prefixed `DSH_`; host-side paths end in `_HOST` and
in-container paths end in `_CONTAINER`. Legacy keys (`PROXY_PORT`, `DSH_WORKSPACE`, `DSH_HOME`,
`DSH_TOTP`, `AUTH_GATE_VERSION`, `DEV_TOOLS`) are renamed automatically on startup with their values
preserved.

**Host side**

| Variable | Default | Description |
|---|---|---|
| `DSH_HTTP_PORT` | `3080` | Published host port (the in-container proxy is fixed at 3080, unrelated to this) |
| `DSH_BIND` | `127.0.0.1` | Host bind address; `0.0.0.0` makes it reachable on the LAN |
| `DSH_HOME_HOST` | `/dsh` | Host data directory. Lives at the root and needs sudo the first time; must be absolute |
| `DSH_WORKSPACE_HOST` | `/dsh/workspace` | Host workspace directory. Independent of the data directory; must be absolute |
| `DSH_UID` / `DSH_GID` | `1000` / `1000` | Container runtime identity. Set to `id -u` / `id -g` when the host UID differs |
| `DSH_DISK_MIN_MB` | `256` | Minimum free disk space (MB) required at startup |
| `DSH_WORKSPACE_STRICT` | `0` | Set to `1` to exit when the workspace is unwritable (instead of degrading) |
| `DSH_ADMIN_DIR` | `/dsh-manager` | Admin panel install directory. Read by `dshm`; `$HOME` is allowed |

**Container side**

| Variable | Default | Description |
|---|---|---|
| `DSH_HOME_CONTAINER` | `/dsh` | In-container data directory, i.e. the bind mount target. This value is the root itself; no `.dsh` is appended |
| `DSH_WORKSPACE_CONTAINER` | `/workspace` | In-container workspace path |

**Login and reverse proxy**

| Variable | Default | Description |
|---|---|---|
| `DSH_AUTH_USER` | `admin` | Login username |
| `DSH_AUTH_PASSWORD` | none (**required**) | Used to create the account on first start; ≥14 chars with upper/lower/digit/symbol. Change later with `./dshm auth password` |
| `DSH_AUTH_TOTP` | `optional` | `off`, `optional`, `required` |
| `DSH_COOKIE_SECURE` | `0` | Set to `1` when serving over HTTPS; must be `0` for plain HTTP |
| `DSH_PUBLIC_HOST` | empty | Domain shown on the login page |
| `DSH_TRUST_XFF` | `0` | Set to `1` to make the proxy trust `X-Forwarded-For`. Only enable when a reverse proxy really rewrites it |
| `DSH_CLIENT_IP_HEADER` | `x-forwarded-for` | Which request header dsh itself reads the client IP from |

**Build time** (rebuild required after changing): `DSH_VERSION`, `DSH_AUTH_GATE_VERSION`,
`DSH_DEV_TOOLS`. `DSH_IMAGE` selects which image to pull or build and is written on demand by
`./dshm service update`. Other settings are documented in `.env.example`.

> [!NOTE]
> dsh's own variables (`DSH_HOME`, `DSH_HOST`, `DSH_PORT`, `DSH_PERMISSION_MODE`,
> `DSH_TELEMETRY_DISABLED`) are injected by the image and compose — do not put them in `.env`.

> [!WARNING]
> - The username and password only apply on **first start** (when no user file exists yet). Change the
>   password later with `./dshm auth password`.
> - `DSH_AUTH_GATE_VERSION` only applies when no profile exists. To force a re-seed:
>   ```bash
>   docker exec qxdho-dsh rm -rf /dsh/profiles/web
>   ./dshm service up
>   ```
> - After changing `DSH_UID` / `DSH_GID` or any path, run `./dshm service up`; `restart` does not
>   recreate the container.

## Data Directory and Permissions

Both the data directory and the workspace are bind mounts, configurable on both sides:

```bash
DSH_HOME_HOST=/dsh                     # host data directory
DSH_HOME_CONTAINER=/dsh                # in-container mount point
DSH_WORKSPACE_HOST=/dsh/workspace      # host workspace
DSH_WORKSPACE_CONTAINER=/workspace     # in-container workspace path
```

`DSH_HOME_CONTAINER` is the root itself; no `.dsh` is appended (setting it to `/data` places the data
directly under `/data`).

Contents of the data directory:

| Path | Contents |
|---|---|
| `settings.yaml` | UI settings: default model, UI preferences |
| `.credentials.yaml` | Model API keys and the session cookie signing secret (changing it requires re-login) |
| `profiles/` | Profiles (`web`, …): configuration and `node_modules` — **plugins live here** |
| `sessions/` | Session records |
| `storages/` | State data for plugins and tools |
| `attachments/` | Uploaded attachments |
| `llm-deepseek/` | Local cache for the DeepSeek provider |
| `home/` | A HOME placeholder directory for tools |

Backing up this directory backs up login users, sessions, plugins and credentials. Do not delete it.

### Directory ownership

If a host directory is owned by root (for example when you bypass `dshm` and run `docker compose up`
directly, letting dockerd create it), processes inside the container running as uid 1000 cannot write
to it. The symptom is a container that keeps restarting, or an agent error:

```
EACCES: permission denied, mkdir '/workspace/xxx'
```

`./install.sh` and `./dshm service up` check before starting and fix it when root or passwordless sudo
is available, otherwise they print the command to run. When the workspace is unwritable the container
does **not** exit; it degrades to `.workspace` under the data root to avoid an endless restart loop
under `restart: unless-stopped`. Set `DSH_WORKSPACE_STRICT=1` to exit instead.

**Host user is not uid 1000** (macOS Docker Desktop, NAS boxes): add to `.env`

```bash
DSH_UID=1001          # output of id -u
DSH_GID=1001          # output of id -g
```

The container then runs as that identity, so bind-mount ownership matches naturally; `./dshm service up`
also repairs the data directory ownership with a one-shot root container (idempotent).

### Upgrading from an older version

Older versions stored data in the named volume `dsh-home`; it is now a bind mount. The migration is
built in:

```bash
git pull --ff-only      # fetch the new scripts
docker rm -f dsh        # the old container name, depending on the version; check docker ps -a first
./install.sh            # migrates automatically when an old volume exists and the host dir is empty
```

Automatic migration runs only when an old named volume exists **and** `DSH_HOME_HOST` is empty: the
source volume is mounted read-only and **is not deleted** afterwards, so you can always roll back. If
containers still hold the old volume, only those whose name or image belongs to this project are
stopped; if another container holds it, migration is skipped with a notice. Otherwise run
`./dshm service migrate-home` manually — it refuses to run when the target directory is not empty, to
avoid overwriting data.

## HTTPS and reverse proxy

The container serves plain HTTP. Terminate HTTPS at the **host reverse proxy** (Nginx, BaoTa,
Cloudflare, …) and **enable WebSocket forwarding**. Then set `DSH_COOKIE_SECURE=1` and
`DSH_PUBLIC_HOST` to your domain in `.env`.

```nginx
server {
    listen 443 ssl;
    server_name dsh.example.com;

    ssl_certificate     /etc/letsencrypt/live/dsh.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dsh.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;   # WebSocket
        proxy_set_header Connection "upgrade";
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

> [!TIP]
> Login rate limiting buckets by client IP and only trusts `X-Forwarded-For` from loopback. If a
> reverse proxy really rewrites that header, set `DSH_TRUST_XFF=1` and adjust `DSH_CLIENT_IP_HEADER`
> as needed.

## FAQ

<details>
<summary><b>The page does not open.</b></summary>

<br/>

Check the logs: `./dshm service logs`. The first start takes a dozen seconds or so;
`./dshm service up` prints progress while waiting.

</details>

<details>
<summary><b>The log contains <code>credentials-local: /dsh/.credentials.yaml is readable beyond its owner (mode 777)</code> and the container keeps restarting.</b></summary>

<br/>

The credentials file is too permissive (readable by users other than its owner) and dsh refuses to
start. Such files usually come from the old named volume, or from a `chmod -R 777` run on the host —
**never `chmod -R 777` the data directory**.

The pre-flight in `./dshm service up` tightens it to `600` before starting, and the entrypoint of the
current image re-checks it on every start. Manual repair:

```bash
sudo chmod 600 /dsh/.credentials.yaml /dsh/settings.yaml /dsh/auth/users.yaml
./dshm service up
```

</details>

<details>
<summary><b>The container keeps restarting and the page never opens.</b></summary>

<br/>

Usually wrong ownership on a host directory — the log contains an "unwritable" diagnostic. See
[Directory ownership](#directory-ownership). Quickest fix:

```bash
sudo chown -R 1000:1000 /dsh /dsh/workspace   # use your actual DSH_HOME_HOST / DSH_WORKSPACE_HOST
./dshm service up
```

</details>

<details>
<summary><b>The agent reports <code>EACCES: permission denied</code>.</b></summary>

<br/>

Workspace ownership is wrong. See [Directory ownership](#directory-ownership).

</details>

<details>
<summary><b>The password is correct but I keep being sent back to the login page.</b></summary>

<br/>

Usually `DSH_COOKIE_SECURE=1` while accessing over plain HTTP. Set it back to `0` and run
`./dshm service up`.

</details>

<details>
<summary><b>I forgot the login password.</b></summary>

<br/>

```bash
./dshm auth password
```

</details>

<details>
<summary><b>How do I use a data directory that does not need root?</b></summary>

<br/>

Change both the host and container paths in `.env`, for example under your home directory:

```bash
DSH_HOME_HOST=$HOME/dsh
DSH_WORKSPACE_HOST=$HOME/dsh-workspace
```

The same applies to the panel: `DSH_ADMIN_DIR=$HOME/dsh-manager`. Run `./dshm service up` afterwards.

</details>

<details>
<summary><b>Disk is full / how do I clean up?</b></summary>

<br/>

```bash
./dshm service disk        # show usage and print cleanup commands
```

The container also requires at least `DSH_DISK_MIN_MB` (default 256MB) free on the data directory and
workspace at startup, and prints cleanup guidance when it is not met.

</details>

## Third-party components

This project is a packaging and deployment layer. Its main dependencies:

| Component | Purpose | License | Source |
|---|---|---|---|
| DeepSeek Harness (`@deepseek-ai/dsh`) | The upstream service being packaged | see upstream | https://github.com/deepseek-ai/deepseek-harness |
| `dsh-auth-gate` | Login page, sessions, TOTP, rate limiting, token→cookie bridge | MIT | https://github.com/TecFancy/dsh-auth-gate |
| `http-proxy` | Forwarding proxy | MIT | https://github.com/http-party/node-http-proxy |
| `tini` | Container init | MIT | https://github.com/krallin/tini |
| `pnpm` | Plugin management | MIT | https://github.com/pnpm/pnpm |
| `node:24-bookworm-slim` | Base image | MIT | https://hub.docker.com/_/node |

Copyright and licenses for upstream components belong to their respective authors. This repository
does not vendor or modify upstream source; it references official npm packages and images.

## Contributing

Please report problems via [Issues](https://github.com/qxdho/deepseek-harness-docker/issues) or open a
Pull Request.

- **Process**: Fork → create a branch → commit → open a PR
- **Commit messages**: follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:` / `fix:` / `docs:` / `chore:`)
- **Before changing code**: run the offline tests to make sure there are no regressions

  ```bash
  ./scripts/test-preflight.sh && ./scripts/test-env-config.sh && \
  ./scripts/test-migrate-home.sh && (cd proxy && node test-inject.js)
  ```

## License

This project is licensed under the [MIT License](./LICENSE). You are free to use, modify and
distribute the code with proper attribution.

DeepSeek Harness and `dsh-auth-gate` are licensed separately. This is an unofficial project and is not
affiliated with or endorsed by the upstream project or its authors.
