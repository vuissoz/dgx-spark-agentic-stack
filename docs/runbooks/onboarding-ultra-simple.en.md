# Ultra-Simple Onboarding (EN) - DGX Agentic Stack

Target audience: complete non-technical users.
Goal: understand what the platform does and operate basic actions safely.

## 1) One-sentence summary

This platform runs local AI, web interfaces, and monitoring tools with a security-first setup (local-only exposure + controlled outbound traffic).

This quickstart assumes the current day-to-day mode: `rootless-dev`.

## 2) The 6 building blocks

1. `core` = technical heart (AI + DNS + proxy + internal control services such as OpenClaw and `gate-mcp`).
2. `agents` = assistants working in isolated workspaces.
3. `ui` = web screens you open.
4. `obs` = dashboards (health, logs, metrics).
5. `rag` = document memory (semantic search).
6. `optional` = extra modules enabled only when needed.

## 3) Main web endpoints

- OpenWebUI: `http://127.0.0.1:8080`
- OpenHands: `http://127.0.0.1:3000`
- ComfyUI: `http://127.0.0.1:8188`
- Grafana: `http://127.0.0.1:13000`

Important: these are local addresses. From another machine, use SSH/Tailscale tunneling.

## 4) Minimum command set

```bash
export AGENTIC_PROFILE=rootless-dev
./agent profile
./agent first-up
./agent ps
./agent doctor
```

If you prefer the explicit step-by-step path:

```bash
./agent up core
./agent up agents,ui,obs,rag
```

To stop cleanly:

```bash
./agent stack stop all
```

## 5) How to know things are healthy

Simple rule:
- `./agent ps` should show services as `Up`.
- `./agent doctor` should end without blocking errors.

If one service fails:

```bash
./agent logs <service>
```

Example:

```bash
./agent logs openwebui
```

## 6) Easy security rules

- Never expose services on `0.0.0.0`.
- Never mount `docker.sock` in application containers.
- Keep secrets out of git.
- Keep remote access through Tailscale/SSH.

## 7) Update and rollback

Update:

```bash
./agent update
```

Rollback:

```bash
./agent rollback all <release_id>
```

## 8) Next docs

- Detailed beginner guide: `docs/runbooks/services-expliques-debutants.md`
- English equivalent beginner guide: `docs/runbooks/services-explained-beginners.en.md`
- Full setup: `docs/runbooks/first-time-setup.md`
- Standard Chinese quickstart: `docs/runbooks/onboarding-ultra-simple.cn.md`
- Hindi quickstart: `docs/runbooks/onboarding-ultra-simple.hi.md`
