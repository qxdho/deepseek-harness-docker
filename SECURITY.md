# Security

DeepSeek Harness can execute model-generated commands and hold provider API keys. A dsh web session
is effectively a remote control plane for the container it runs in. Treat this image accordingly.

## Hardening applied

- dsh listens on container loopback only; the bundled proxy is the sole network listener.
- Login is enforced in-process by `dsh-auth-gate` with rate limiting (and optional TOTP).
- Non-root runtime user (`node`, uid 1000), `cap_drop: ALL`, `no-new-privileges:true`.
- File sandbox defaults to `workspace-write`, enforced by Landlock on Linux (no capabilities needed).
- No Docker socket, host root, or extra host paths are mounted by default.
- Login users and the dsh cookie signing secret live in the host data directory (`DSH_HOME_HOST`, default `/dsh`), not in the image.

## What this does NOT protect you from

- **Plain HTTP.** Passwords and session cookies travel in cleartext. Use this only on a trusted LAN,
  or terminate TLS in front and set `DSH_COOKIE_SECURE=1`.
- **Hostile code inside the container.** The sandbox limits the agent's own mistakes, not a determined
  attacker. Upstream `SAFETY.md` says sandboxing/prompts reduce risk but do not guarantee isolation.
- **Provider keys.** They live in `$DSH_HOME/.credentials.yaml`; anyone who can read that volume or run
  commands as the container user can read them. Use narrowly scoped, revocable keys.
- **`DSH_DEV_TOOLS=full` / `danger-full-access`.** Both widen the blast radius; enable only when intended.

## Recommended deployment

1. Keep it on a trusted LAN, **or** put TLS in front and set `DSH_COOKIE_SECURE=1`.
2. Restrict the host firewall to the port(s) you actually use.
3. Do not attach untrusted containers to the same network; do not mount the Docker socket.
4. Rotate `DSH_AUTH_PASSWORD` if it was ever shared, and keep `.env` out of git.

## Reporting

Report vulnerabilities through GitHub's private security advisory flow on this repository rather than
a public issue. For issues in dsh itself or in `dsh-auth-gate`, follow their respective security policies.
