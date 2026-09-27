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

The user asked for a login page instead of pasting the launch token. Surveying the ecosystem, there
were four camps: (A) manual token, (B) proxy-side token→cookie exchange, (C) patch dsh's auth out and
authenticate in a gateway, (D) an in-process plugin.

Camp C (used by 1Panel via the undocumented `ONEPANEL_DSH_AUTH_PROXY` env, and by misaka-link via a
source patch) breaks on dsh upgrades. Camp D is the cleanest: `dsh-auth-gate` is a maintained plugin
with password/shared-token login, optional TOTP, sessions, rate limiting, a user-management CLI, and —
crucially — it **bridges the launch token itself** (the login redirect hops through a relative
`/?token=…` that sets the dsh cookie). The user never sees the token, and no dsh file is modified.

## 3. Correcting the previous design's premise

The previous README/comments in this repository claimed that rewriting `Host` makes the browser drop
the dsh cookie, producing `ERR_TOO_MANY_REDIRECTS`, and therefore the proxy must preserve the original
Host and rely on `--trusted-host`.

That diagnosis is wrong. dsh's session cookie has **no `Domain` attribute**, so the browser scopes it
to the site it requested, independent of the upstream `Host` header. The cookie *name* is derived from
the `Host` dsh receives; consistent rewriting therefore keeps name and storage aligned.

Measured on real dsh (`0.1.5-rc.2`, no bypass env):

```
client URL:  http://lan.test:3099/   (--resolve to 127.0.0.1)
upstream Host: 127.0.0.1:3080
GET /?token=... -> 303 + Set-Cookie (no Domain)  -> stored for lan.test
GET /            -> 200
```

`ERR_TOO_MANY_REDIRECTS` actually comes from re-injecting the token on every `/` request, causing a
`/ → /?token= → 303 → /` loop. This design avoids it by doing the exchange exactly once inside the
plugin.

Rewriting Host to loopback also removes the need to configure `--trusted-host` per access domain.

## 4. Layers in the image

1. **dsh** on `127.0.0.1:3079`, web profile with `dsh-auth-gate` pre-installed into a baked profile.
2. **proxy** (`proxy/index.js`, `http-proxy`) on `0.0.0.0:3080`:
   - forwards HTTP and WebSocket to loopback;
   - rewrites `Host` and `Origin` to `127.0.0.1:3079` consistently (fence-safe);
   - requests `accept-encoding: identity` so HTML can be safely rewritten;
   - injects into `<head>`: a `crypto.randomUUID` polyfill and
     `globalThis.__DSH_TRANSPORT__ = { …, ownsHost: true }` (a documented dsh seam — nothing in dsh
     assigns this global, it is read by the client to derive `isLoopback`).
3. **No Caddy by default** (plain HTTP). An optional `docker-compose.tls.yml` puts Caddy in front for TLS.

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

## 6. Verification status

Verified locally (no Docker on this machine, so image build is delegated to CI):

- Installed `dsh-auth-gate@0.15.0` into a throwaway `DSH_HOME` with `dsh plugin --profile web add`.
- Created an admin user through the plugin CLI (after linking the peer deps).
- Booted dsh with the plugin and measured the full flow:
  - `GET /` without a session → `302 /auth/login?next=%2F` (browser) / `401` (no `Accept: text/html`);
  - `POST /auth/login` → `302` + `Set-Cookie: dsh_auth=…` + `Location: /?token=…` (the bridge);
  - following redirects → `200` and the page contains `__DSH_BOOT__`;
  - a second `GET /` with the cookie → `200`.
- Verified the Host-rewrite cookie argument (see §3).

CI (`.github/workflows/build.yml`) builds amd64+arm64 and pushes to GHCR, and runs
`scripts/smoke-test.sh` against a locally loaded image (container health, unauthenticated redirect,
login round-trip, session persistence, injected polyfill, unauthenticated `/api` rejection).
