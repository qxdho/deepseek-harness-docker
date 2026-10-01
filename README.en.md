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
./dshm version list                        # images already built, plus dsh versions on npm
./dshm version update                      # pull the newest built image (fast, preferred)
./dshm version update --to <image tag>     # install a specific build, e.g. 0.2.0-rc.2-2026.10.01-1
./dshm version update --build              # build locally (slow); npm latest by default
./dshm version update --build --dsh 0.1.7-rc.2   # build locally with a chosen dsh version
```

**Prefer an already-built image**: CI builds one on every push to `main`, so `version update`
just pulls it. Only reach for `--build` when you need to validate uncommitted repository changes,
or no image exists for the version you want.

### How image tags are numbered

```
0.2.0-rc.2-2026.10.01-1
└────┬───┘ └────┬────┘ └┬┘
 dsh version   build date  sequence
```

| Part | Purpose |
|---|---|
| `0.2.0-rc.2` | which dsh is inside the image |
| `2026.10.01` | the day you built it |
| `-1` `-2` | **multiple builds on the same day never overwrite each other** — old images stay pullable |

> [!IMPORTANT]
> **The sequence number is not decoration.** With a plain `<dsh version>` tag, a second build on
> the same day would **overwrite** the first: the old image loses its tag, may be garbage-collected,
> and you can never roll back to it. That is why this project does not use plain version tags.
> `latest` points at the newest build, but **reproducing a specific build requires the full tag**.

> [!NOTE]
> **dsh is npm-installed into the image at build time**, so changing the dsh version means rebuilding
> — there is no hot swap. That is the common approach for packaging projects like this one (1Panel's
> app store and comparable community projects do the same): the container **works offline**, and a bad
> version combination fails at **build time** rather than after the container starts.

### No need to keep checking for versions

dsh is in preview and ships frequently (four releases in four days, measured), so falling behind
quietly is the normal state. Two pieces of automation deal with it:

- **The repository keeps itself current**: CI checks upstream weekly and **opens a PR** when there is
  something newer. A PR rather than a direct commit, because a minor-version bump can carry breaking
  changes that need a human decision.
- **You can see it any time**: `./dshm service status` reports the current version, whether a newer
  one exists, and the upgrade command. Set `DSHM_SKIP_UPDATE_CHECK=1` for offline environments.

### Two update channels, different sources of truth

This trips people up, so keep them apart:

| What | Source of truth | Command |
|---|---|---|
| **dsh itself** (what runs in the container) | **npm registry** | `./dshm version update` |
| **the `dshm` tool** (script + admin panel) | **tags you push** | `./dshm dshm update` |

The two are **completely independent** — neither affects the other:

- **dsh is published to npm**, not GitHub. `version list` queries npm directly, so **even if this
  repository has not caught up, the dsh versions you see are current**. Upstream ships every few
  days (four releases in four days, measured); whether to follow is your call.
- **`dshm` updates from tags only, never `main`.** That is deliberate: following `main` would mean
  installing a commit you have not decided to release. Inside a git working tree use `git pull`;
  deployments without a checkout use `./dshm dshm update`, which only pulls published tags.

> [!TIP]
> One line to remember: **`dshm version` manages the container, `dshm dshm` manages the tooling.**

## Management CLI

`dshm` is grouped by purpose; run `dshm help` for the full list. `./dshm dshm install` registers it as
a system command so you can call `dshm` from any directory.

```bash
# service
./dshm service up          # start, or apply .env changes
./dshm service restart     # restart
./dshm service down        # stop (data kept)
./dshm service status      # health / port / login user (and whether dsh has an update)
./dshm service logs        # logs
./dshm service shell       # shell into the container

# dsh versions
./dshm version             # all four versions (config / image / running / npm latest)
./dshm version list        # every installable version on npm
./dshm version update      # upgrade

# login and accounts
./dshm auth password       # change the login password
./dshm auth user add bob   # add a user
./dshm auth totp enable    # enable two-factor auth

# disk / migration
./dshm disk                # disk usage and cleanup commands
./dshm migrate             # migrate an old named volume

# admin panel / dshm itself
./dshm admin install       # install the admin panel
./dshm dshm install        # register dshm as a system command
```

| Group | Subcommand | Description |
|---|---|---|
| `service` | `up` / `down` / `restart` | Start, stop, restart (`up` and `restart` both re-read `.env`) |
| `service` | `status` / `logs` / `shell` / `url` | Status, logs, shell, one-time launch URL (troubleshooting) |
| `version` | `show` (default) / `list` / `update` | Show four versions, list built images and npm versions, upgrade |
| `auth` | `password` / `user` / `totp` | Password, user management, two-factor auth |
| `admin` | `install` / `uninstall` / `url` / `password` / `status` / `logs` | Host-side admin panel |
| `dshm` | `version` / `list` / `install` / `uninstall` / `update` | Manage dshm itself (mirrors `npm install npm`); **tags only** |
| (top level) | `disk` / `migrate` / `help` | Disk usage, data migration, help |

> [!NOTE]
> **There is one spelling.** The older flat forms (`./dshm up`, `./dshm pw`, …) and the group
> shorthands (`svc` / `login` / `cli` / `panel`) have **all been removed** — keeping two spellings
> makes the help longer and leaves newcomers unsure which to learn. Using one prints the new form:
>
> ```
> $ ./dshm up
> 错误：命令 'up' 已改为分组写法：dshm service up
> ```

### Version management: the complete picture

**Get the mental model right first.** There are **two version domains** in this project, and
they update in completely different ways. Mixing them up is why "I upgraded it but nothing
changed" happens.

| Domain | What it covers | Source of truth | Commands |
|---|---|---|---|
| **dsh** | the DeepSeek Harness running in the container | **npm registry** | `dshm version …` |
| **dshm** (incl. the admin panel) | the deployment tooling itself | **tags you push** | `dshm dshm …` |

The two are **independent**: upstream releasing a new dsh does not mean dshm changes, and
changing dshm does not mean dsh upgrades.

> [!NOTE]
> **The admin panel is a feature of dshm and shares its version.** The panel binary's version is
> injected by CI from the repository-root `VERSION` file — the same source as the dshm script.
> That is guaranteed by machinery, not by remembering to do it.

#### Check

```bash
./dshm version              # all four versions at once (see below)
./dshm version list         # images already built + dsh versions available on npm
./dshm service status       # health (and whether dsh has an update)

./dshm dshm version         # dshm's own version + panel installed? + update available? (tags only)
./dshm dshm list            # every published dshm version
```

`dshm version` prints **four** versions that can differ from each other:

```
配置里钉的版本：  0.2.0-rc.2       <- what the next build will produce
镜像：            ghcr.io/…:latest  <- which image you pull
容器内实际运行：  0.2.0-rc.2       <- what is actually running
npm 最新：        0.2.0-rc.2       <- what you could get
```

It **warns when "configured" and "actually running" disagree** — the state you land in after
editing `.env` without running `up`. `./dshm service up` applies it.

Set `DSHM_SKIP_UPDATE_CHECK=1` to skip the network lookup (offline deployments).

#### Upgrade dsh (the container)

```bash
./dshm version update              # pull the newest built image (fast, preferred)
./dshm version update --to <tag>   # install a specific build (rollback)
./dshm version update --build      # build locally (slow); uses npm latest by default
./dshm version update --build --dsh 0.1.7-rc.2   # build locally with a chosen dsh version
```

| Your goal | Use | Cost |
|---|---|---|
| Follow the newest (CI has built it) | `version update` | fast (pull) |
| Pin / roll back to a specific build | `version update --to <tag>` | fast (pull) |
| Use npm latest, or a chosen version | `version update --build [--dsh v]` | slow (local build) |

**Why changing the dsh version requires a rebuild**: dsh is npm-installed into the image **at
build time**. That is the common approach for packaging projects like this one (1Panel's app
store and comparable community projects do the same) — the container **works offline**, and a
bad version combination fails **at build time** rather than after the container starts.

**Rolling back loses no data**: sessions, plugins and credentials live in the bind-mounted data
directory.

#### Upgrade dshm (tooling + panel)

```bash
./dshm dshm update                 # install the newest published version
./dshm dshm update --to <version>  # install / roll back to a specific one, e.g. --to 2026.10.01
```

**Tags only — never `main`**, so you can never pull a commit you have not decided to release.
Inside a git working tree use `git pull`; `dshm dshm update` targets deployments that never kept
a checkout (it stops by default in a git tree, `--allow-stale` forces it).

#### Maintainer: how to release

```bash
# 1. bump the VERSION file (the single source of truth) and commit
git commit -am "chore(release): v2026.10.01" && git push

# 2. tag and push — CI builds the panel binary and publishes the release
git tag v2026.10.01 && git push origin v2026.10.01
```

**Images need no manual tag**: every push to `main` makes CI build and push
`<dsh version>-<date>-<sequence>` (e.g. `0.2.0-rc.2-2026.10.01-1`) to GHCR. The sequence number
guarantees that multiple builds on the same day **never overwrite each other**.

**The repository also keeps itself current**: CI checks upstream weekly and **opens a PR** when a
newer dsh exists (see `.github/workflows/update-versions.yml`) — no hand-editing of
`DSH_VERSION` in `Dockerfile` / `docker-compose.yml` / `.env.example`.

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
`./dshm version update`. Other settings are documented in `.env.example`.

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

### Broke the permissions? One command self-heals

After ownership or modes get scrambled (a manual `chmod`, a panel action, some other tool), you do
**not** need to remember what they should be. The preflight in `./dshm service up` will:

- `chown` to the container UID when it differs (with root or passwordless sudo), otherwise print the
  exact command to copy
- tighten a too-permissive directory by dropping `g+w,o+w`
- create a missing directory with `umask 0022` (so it is never 777)

In other words: **break the permissions however you like, then run `./dshm service up` once.**

> The entrypoint also pins `umask 0022`. The default may be `0000`/`0002`, in which case new files
> are created 666/777 — **with the executable bit set**. A `git clone` in the data directory then
> leaves every file executable, and `git status` reports a pile of "modified" entries with an empty
> `git diff`. Pinning 0022 yields 644/755, matching git's expectation.

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
`./dshm migrate` manually — it refuses to run when the target directory is not empty, to
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
<summary><b>The log contains <code>credentials-local: /dsh/.credentials.yaml is readable beyond its owner (mode 777)</code> or <code>EACCES: permission denied, open '/dsh/.credentials.yaml'</code>, and the container keeps restarting.</b></summary>

<br/>

dsh requires the credentials file to be **owner-only**: a permissive mode (`777`, `640`) is refused,
and after tightening to `600` a file still owned by `root` is unreadable for uid 1000 inside the
container (`EACCES`). Both come down to that file's mode/owner — usually inherited from the old named
volume, or from a `chmod -R 777` / `chown` run on the host — **never `chmod -R 777` the data
directory**.

The pre-flight in `./dshm service up` fixes owner and mode before starting, and the entrypoint of the
current image re-checks on every start, printing the exact host-side command when it cannot read the
file. Manual repair (`DSH_UID`/`DSH_GID` come from `.env`, default 1000):

```bash
sudo chown -R 1000:1000 /dsh                                          # owner = container uid
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
./dshm disk        # show usage and print cleanup commands
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
- **Before changing code**: run the offline tests (auto-discovers `scripts/test-*.sh`)

  ```bash
  ./scripts/test-all.sh
  ```

### Maintainers: cutting a release

Releasing is a maintainer action and is **not part of `dshm`** — regular users have no push
access and should not need to think about tags or releases. Use `scripts/release.sh`:

```bash
./scripts/release.sh --dry-run    # see what it would do first
./scripts/release.sh              # today's date; auto -1/-2 if already released today
./scripts/release.sh 2026.10.02   # explicit version
```

It then: pre-flight (branch / clean tree / in sync / tag free) → write `VERSION` → commit →
tag with the same name → push → wait for CI to publish the release.

> [!IMPORTANT]
> **The tag name must equal `v` + the contents of `VERSION`** (CI enforces this). The package
> name, the release download URL and the version baked into the script all derive from that one
> number — if they drift you publish a release whose self-update 404s. See DESIGN.md section 10.

**Images need no manual tag**: a push to `main` builds one and pushes it as
`<dsh version>-<date>-<sequence>` (e.g. `0.2.0-rc.2-2026.10.01-1`); the sequence keeps multiple
builds on the same day from overwriting each other, so rollbacks stay possible.
  ```

## License

This project is licensed under the [MIT License](./LICENSE). You are free to use, modify and
distribute the code with proper attribution.

DeepSeek Harness and `dsh-auth-gate` are licensed separately. This is an unofficial project and is not
affiliated with or endorsed by the upstream project or its authors.
