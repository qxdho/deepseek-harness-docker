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
- **Anything the agent can reach on the network.** dsh's built-in `web_fetch` used to refuse
  loopback/private/link-local/reserved targets; since dsh `0.2.1-rc.2` it no longer does — it sends the
  request through the configured proxy and the system resolver. Inside this container that means the
  fetch can reach the host's LAN through the NAT gateway (router/NAS/other services), and a prompt-injected
  page can steer it at internal URLs. Note what it is *not*: `127.0.0.1:3079` is dsh itself, still behind
  `dsh-auth-gate`, so it is not a way around the login; and cloud metadata (`169.254.169.254`) is not
  routed into a default bridge network. This is a deployment-level exposure, not something the image can
  fix on its own.

## Recommended deployment

1. Keep it on a trusted LAN, **or** put TLS in front and set `DSH_COOKIE_SECURE=1`.
2. Restrict the host firewall to the port(s) you actually use.
3. Do not attach untrusted containers to the same network; do not mount the Docker socket.
4. Rotate `DSH_AUTH_PASSWORD` if it was ever shared, and keep `.env` out of git.
5. If the container must not reach your LAN, restrict its **egress** yourself — a user-defined bridge plus
   host firewall rules that drop traffic to `10/8`, `172.16/12`, `192.168/16` and `169.254/16` while
   allowing the destinations you need. Upstream lists the alternatives as a `tools/pre-execute` policy
   that denies those URLs, or removing the fetch tool from the profile composition.

## Reporting

Report vulnerabilities through GitHub's private security advisory flow on this repository rather than
a public issue. For issues in dsh itself or in `dsh-auth-gate`, follow their respective security policies.
