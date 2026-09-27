# dsh one-click deploy image (DeepSeek Harness + login gate)

Packages the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`@deepseek-ai/dsh`)
web UI into a deployable Docker image with a built-in login page and optional TOTP.

- **No more copying the launch token** — the login plugin exchanges dsh's one-time token for a
  session cookie inside the container.
- **Real login page** — username/password, optional TOTP, rate limiting.
- **Ready out of the box** — GitHub Actions builds a multi-arch image and pushes it to GHCR.
- **Least privilege** — non-root, `cap_drop: ALL`, `no-new-privileges`, `workspace-write` (Landlock).

## Quick start

```bash
git clone https://github.com/qxdho/deepseek-harness-docker.git
cd deepseek-harness-docker
cp .env.example .env          # set a strong DSH_AUTH_PASSWORD
docker compose pull && docker compose up -d
```

Open `http://<host>:3080/`, sign in with `admin` + your password.

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

## Self-update

```bash
./dshctl update [version]          # host-side, reproducible
docker exec -it dsh dsh-update     # in-place, persisted under $DSH_HOME/npm-global
```

See [README.md](README.md) (Chinese) for the full documentation. MIT licensed.
