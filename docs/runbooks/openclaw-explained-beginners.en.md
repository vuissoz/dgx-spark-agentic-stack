# Runbook: OpenClaw Explained for Beginners

This document explains OpenClaw in simple terms.
It is designed for beginners who want to understand:
- what OpenClaw does in this stack,
- how it is configured,
- how to run it safely.

Current repo context: the normal operator path is `rootless-dev`, and OpenClaw is part of `core`, started by `./agent first-up` or `./agent up core`.

For the full operational procedure in `rootless-dev`, see:
- `docs/runbooks/openclaw-onboarding-rootless-dev.md`

## 1. What OpenClaw Is (in this stack)

Think of OpenClaw as a controlled messaging/automation API layer.
In this repository, OpenClaw is deployed as part of the `core` stack with four services:
- `openclaw`: main API service,
- `openclaw-gateway`: upstream Web UI/WS service (host loopback),
- `openclaw-sandbox`: restricted tool execution backend,
- `openclaw-relay`: provider webhook relay with durable queue + local injection.

Recommended beginner command:
- `./agent openclaw init [project]`
  - stack-managed OpenClaw bootstrap/repair,
  - repairs the default workspace back under `/workspace/...`,
  - without an argument, uses `AGENTIC_OPENCLAW_INIT_PROJECT` (default: `openclaw-default`),
  - can reuse Telegram/Discord/Slack secrets already collected by `./agent onboard`,
  - keeps the upstream wizard as expert fallback instead of the primary path.

Quick operator visibility:
- `./agent openclaw status`
- `./agent openclaw status --json`

Simple mental model:
1. a request reaches OpenClaw,
2. OpenClaw authenticates and validates it,
3. OpenClaw checks policy allowlists,
4. if a tool action is needed, it forwards to the sandbox,
5. audit logs are written.

## 2. Why There Are Four Containers

## `openclaw` (API)
- receives API requests,
- enforces auth token and webhook secret,
- checks DM allowlist and endpoint contract,
- records audit events.

## `openclaw-gateway` (upstream Web UI/WS)
- exposes the upstream OpenClaw Web UI on `127.0.0.1:${OPENCLAW_GATEWAY_HOST_PORT:-18789}`,
- exposes the upstream Gateway WebSocket on `ws://127.0.0.1:${OPENCLAW_GATEWAY_HOST_PORT:-18789}`,
- remains host loopback-only.

## `openclaw-sandbox` (execution)
- runs allowed tool actions in a tighter execution boundary,
- uses a dedicated allowlist,
- is not exposed on a host public interface.

## `openclaw-relay` (provider ingress/queue)
- accepts signed provider webhooks (`/v1/providers/<provider>/webhook`),
- stores events durably in queue files,
- forwards to local OpenClaw webhook endpoint with retries/dead-letter.

Reason for this split:
- reduce blast radius,
- keep API concerns separate from execution concerns,
- make policy easier to audit.

## 3. Security Basics You Should Know

Key protections used by default:
- host exposure is loopback only (`127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`),
- upstream Web UI/WS is loopback-only as well (`127.0.0.1:${OPENCLAW_GATEWAY_HOST_PORT:-18789}`),
- no `docker.sock` mount,
- `cap_drop: ALL`,
- `security_opt: no-new-privileges:true`,
- secrets from files under `${AGENTIC_ROOT}/secrets/runtime`.

Beginner meaning:
- `cap_drop: ALL`: remove Linux elevated capabilities from the container,
- `no-new-privileges`: processes inside cannot gain extra privileges later,
- loopback host bind: local machine access only (not directly public Internet).

## 4. Main Configuration Files

OpenClaw config files are generated/prepared under `${AGENTIC_ROOT}`:

- `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`
  - bearer token for API auth,
  - keep mode `600`.

- `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret`
  - HMAC secret for webhook signature verification,
  - keep mode `600`.

- `${AGENTIC_ROOT}/openclaw/config/dm_allowlist.txt`
  - allowed DM targets.

- `${AGENTIC_ROOT}/openclaw/config/tool_allowlist.txt`
  - allowed sandbox tool actions.

- `${AGENTIC_ROOT}/openclaw/config/integration-profile.current.json`
  - active runtime contract/profile (required env keys and endpoint aliases).

- `${AGENTIC_ROOT}/openclaw/config/relay_targets.json`
  - provider relay target mapping used by `openclaw-relay`.

## 5. Important Environment Variables

Common variables used by the service:
- `OPENCLAW_AUTH_TOKEN_FILE=/run/secrets/openclaw.token`
- `OPENCLAW_WEBHOOK_SECRET_FILE=/run/secrets/openclaw.webhook_secret`
- `OPENCLAW_DM_ALLOWLIST_FILE=/config/dm_allowlist.txt`
- `OPENCLAW_TOOL_ALLOWLIST_FILE=/config/tool_allowlist.txt`
- `OPENCLAW_PROFILE_FILE=/config/integration-profile.current.json`
- `OPENCLAW_SANDBOX_URL=http://openclaw-sandbox:8112`
- `OPENCLAW_SANDBOX_AUTH_TOKEN_FILE=/run/secrets/openclaw.token`

You usually do not edit these container paths directly.
You edit host-side files under `${AGENTIC_ROOT}`.

## 6. Basic Endpoints (beginner view)

Typical local host endpoint:
- `http://127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`

Useful routes:
- `GET /healthz` -> service health
- `GET /v1/profile` -> active integration profile
- `POST /v1/dm` -> send DM (auth required, allowlist enforced)
- `POST /v1/webhooks/dm` -> inbound webhook DM path (signature/auth policy applies)

If auth or allowlist is wrong, requests are expected to fail (`401` or `403`).
This is normal and desirable.

## 7. Typical Beginner Workflow

1. Prepare environment and secrets:
```bash
./agent onboard --profile rootless-dev --output .runtime/env.generated.sh
source .runtime/env.generated.sh
```

2. Start the core stack (or the full baseline):
```bash
./agent up core
# or:
# ./agent first-up
```

3. Check status:
```bash
./agent ls
./agent doctor
./agent logs openclaw
```

4. Edit policies when needed:
```bash
${EDITOR:-vi} "${AGENTIC_ROOT}/openclaw/config/dm_allowlist.txt"
${EDITOR:-vi} "${AGENTIC_ROOT}/openclaw/config/tool_allowlist.txt"
```

5. Restart OpenClaw core services after policy changes:
```bash
./agent stop openclaw
./agent up core
```

## 8. Common Mistakes (and Fixes)

- Mistake: leaving the wizard workspace at `/state/cli/openclaw-home/.openclaw/workspace`.
  - Check: onboarding ends with `/overlay/openclaw.operator-overlay.json: agents.defaults.workspace must stay under /workspace/`.
  - Fix: rerun onboarding with `--workspace /workspace/<project>` or choose a `/workspace/...` path in the wizard. In this stack, `/state/...` is for runtime state, not the persisted default user workspace.

- Mistake: assuming OpenClaw "gateway port" and OpenClaw API port are the same thing.
  - Check: onboarding reports a gateway health failure on `ws://127.0.0.1:8111`.
  - Fix: remember the split:
    - `18111 -> 8111` is the stack OpenClaw API/dashboard ingress,
    - `18789` is the managed upstream OpenClaw Web UI/WS gateway.
    - For onboarding in this stack, prefer the documented `--skip-health` path to avoid the misleading upstream probe.

- Mistake: running `openclaw gateway run` manually from `./agent openclaw`.
  - Check: logs mention `anthropic/claude-opus-4-6` and missing Anthropic API keys.
  - Fix: do not start a second manual gateway. Use `./agent up core` to run the stack-managed `openclaw-gateway` service.

- Mistake: OpenClaw not starting.
  - Check: `./agent doctor` output and whether `./agent up core` succeeded.
  - Fix: ensure `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`, `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret`, and `${AGENTIC_ROOT}/openclaw/config/integration-profile.current.json` exist and are valid.

- Mistake: API call returns `401`.
  - Check: token file content and auth header.
  - Fix: use bearer token from `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`.

- Mistake: API call returns `403` on DM.
  - Check: DM target allowlist.
  - Fix: add target to `dm_allowlist.txt` and restart OpenClaw core services.

- Mistake: profile validation failure.
  - Check: `integration-profile.current.json` exists and is valid.
  - Fix: restore from `examples/optional/openclaw.integration-profile.v1.json`.

## 9. Relationship With Upstream `openclaw` CLI

This stack is inspired by upstream OpenClaw onboarding and gateway workflows,
but it uses the repository's `./agent` orchestration model.

Quick mapping:
- upstream `openclaw onboard` -> stack `./agent openclaw init [project]`
- upstream `openclaw gateway run` -> stack `./agent up core`

## 10. Useful References

- OpenClaw site: https://openclaw.ai/
- OpenClaw docs (getting started): https://docs.openclaw.ai/start/getting-started
- Stack onboarding runbook: `docs/runbooks/openclaw-onboarding-rootless-dev.md`
- Stack security model: `docs/security/openclaw-sandbox-egress.md`
