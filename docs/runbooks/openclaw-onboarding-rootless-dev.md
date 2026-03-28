# Runbook: OpenClaw Onboarding for `rootless-dev`

This runbook explains how to configure and validate OpenClaw in this repository when running in `rootless-dev` mode.

Scope:
- this stack's core OpenClaw services (`openclaw` + `openclaw-gateway` + `openclaw-sandbox` + `openclaw-relay`),
- loopback-only host exposure (`127.0.0.1`),
- onboarding through `./agent` (not direct upstream daemon install on host).

Upstream references used as baseline:
- `https://openclaw.ai/`
- `https://docs.openclaw.ai/start/getting-started`
- `https://docs.openclaw.ai/start/wizard-reference`
- `https://docs.openclaw.ai/cli-reference/openclaw-onboard`
- `https://docs.openclaw.ai/cli-reference/openclaw-gateway-run`

## Upstream -> Stack Mapping

| Upstream OpenClaw docs | This stack (`dgx-spark-agentic-stack`) |
|---|---|
| `openclaw onboard` | `./agent onboard --profile rootless-dev` |
| `openclaw onboard` (operator in runtime container) | `./agent openclaw` then `openclaw onboard ...` |
| `openclaw configure` | `./agent openclaw` then `openclaw configure --section ...` |
| `openclaw agents add <name>` | `./agent openclaw` then `openclaw agents add <name> --workspace ... --non-interactive` |
| `openclaw gateway run --dashboard` | `./agent up core` |
| `openclaw gateway status` | `./agent ls` (service state) + `./agent doctor` (compliance) |
| `openclaw gateway logs` | `./agent logs openclaw` |
| `openclaw gateway stop` | `./agent stop openclaw` (or `./agent down core`) |
| `openclaw node run` | not used in baseline stack path; this stack deploys a local core OpenClaw API/sandbox pair |

## Preconditions

1. Docker Engine and Docker Compose v2 are installed.
2. You are in this repository root.
3. You target `rootless-dev` profile (default root is `${HOME}/.local/share/agentic`).

Quick checks:

```bash
docker version
docker compose version
./agent profile
```

If `./agent profile` does not show `profile=rootless-dev`, run onboarding in the next step.

## Step 1: Run Onboarding

Interactive (recommended):

```bash
./agent onboard \
  --profile rootless-dev \
  --output .runtime/env.generated.sh
```

Load generated environment and verify:

```bash
source .runtime/env.generated.sh
./agent profile
```

Expected values:
- `profile=rootless-dev`
- `root=${HOME}/.local/share/agentic` (unless overridden)

Non-interactive example:

```bash
./agent onboard \
  --profile rootless-dev \
  --non-interactive \
  --output .runtime/env.generated.sh
source .runtime/env.generated.sh
```

## Step 2: Review Generated OpenClaw Artifacts

Onboarding/runtime init prepares these files:
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret`
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.telegram.secret`
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.whatsapp.secret`
- `${AGENTIC_ROOT}/openclaw/config/dm_allowlist.txt`
- `${AGENTIC_ROOT}/openclaw/config/tool_allowlist.txt`
- `${AGENTIC_ROOT}/openclaw/config/relay_targets.json`
- `${AGENTIC_ROOT}/openclaw/config/integration-profile.v1.json`
- `${AGENTIC_ROOT}/openclaw/config/integration-profile.current.json`

Verify permissions (secrets must stay restrictive):

```bash
stat -c '%a %n' \
  "${AGENTIC_ROOT}/secrets/runtime/openclaw.token" \
  "${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret" \
  "${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.telegram.secret" \
  "${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.whatsapp.secret"
```

Expected mode: `600` (or `640` in controlled setups).

## Step 3: Configure Policy Files

OpenClaw is allowlist-driven in this stack.

Edit DM targets:

```bash
${EDITOR:-vi} "${AGENTIC_ROOT}/openclaw/config/dm_allowlist.txt"
```

Edit allowed sandbox tools:

```bash
${EDITOR:-vi} "${AGENTIC_ROOT}/openclaw/config/tool_allowlist.txt"
```

Edit relay provider targets:

```bash
${EDITOR:-vi} "${AGENTIC_ROOT}/openclaw/config/relay_targets.json"
```

Also verify the active integration profile:

```bash
cat "${AGENTIC_ROOT}/openclaw/config/integration-profile.current.json"
```

It must remain valid JSON matching the runtime contract, otherwise OpenClaw startup is refused.

## Step 3b: Review and Process Interactive Approvals

If a DM target or tool is blocked by policy, OpenClaw now creates a durable queue entry under:
- `${AGENTIC_ROOT}/openclaw/state/approvals/pending/`

List the queue:

```bash
./agent openclaw approvals list
./agent openclaw approvals list --status pending --json
```

Approve a blocked request temporarily for one session:

```bash
./agent openclaw approvals approve <approval_id> --scope session --session-id <session_id> --ttl-sec 3600
```

Approve temporarily for all sessions:

```bash
./agent openclaw approvals approve <approval_id> --scope global --ttl-sec 21600
```

Refuse explicitly:

```bash
./agent openclaw approvals deny <approval_id> --scope global --reason "not allowed for this stack"
```

Promote persistently into the explicit allowlist artifact:

```bash
./agent openclaw approvals promote <approval_id>
```

Promotion writes to one of:
- `${AGENTIC_ROOT}/openclaw/config/dm_allowlist.txt`
- `${AGENTIC_ROOT}/openclaw/config/tool_allowlist.txt`

State transitions are durable and auditable:
- `pending`
- `approved`
- `denied`
- `expired`

Audit events are appended to:
- `${AGENTIC_ROOT}/openclaw/logs/audit.jsonl`

Queue records intentionally avoid storing secrets, tokens, message bodies, or raw tool arguments.

## Step 3c: Use the Operator Control Surface

OpenClaw now exposes a separate operator-facing CLI on the host wrapper.

Read runtime status:

```bash
./agent openclaw status
./agent openclaw status --json
```

Inspect and extend local policy artefacts:

```bash
./agent openclaw policy list
./agent openclaw policy list --json
./agent openclaw policy add dm-target discord:user:ops
./agent openclaw policy add tool diagnostics.echo
```

Set the default OpenClaw model stored in the shared operator runtime file:

```bash
./agent openclaw model set qwen3-coder:14b
```

Inspect or administer sandbox runtime state:

```bash
./agent openclaw sandbox ls
./agent openclaw sandbox ls --json
./agent openclaw sandbox attach <sandbox_id>
./agent openclaw sandbox destroy <sandbox_id>
```

The shared operator runtime file is:
- `${AGENTIC_ROOT}/openclaw/config/operator-runtime.v1.json`

The module blueprint/manifest is:
- `${AGENTIC_ROOT}/openclaw/config/module/openclaw.module-manifest.v1.json`

## Step 3d: Use the In-Chat Status Command

The stack now bootstraps a managed OpenClaw slash command for quick operator checks in chat:

```text
/openclaw status
```

Behavior:
- this is a UX shortcut, not an admin surface,
- it reads the existing local OpenClaw status API (`/v1/dashboard/status`),
- it returns a short sanitized summary:
  - module/sandbox health,
  - current/default session,
  - default model/provider,
  - active sandbox/session counts,
  - approvals and relay queue counters.

Non-goals:
- no secret/token/path disclosure,
- no lifecycle or policy mutation from chat,
- no bypass of `agent openclaw ...` or the internal sandbox API.

Note:
- OpenClaw snapshots skills per session, so after enabling/updating the stack you may need a new chat session before the slash command appears.

## Step 4: Start Services

Start the core stack:

```bash
./agent up core
```

Open an operator shell for OpenClaw service context:

```bash
./agent openclaw
```

This shell reminds you of:
- host loopback endpoint: `http://127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`
- internal endpoint: `http://openclaw:8111`
- dashboard endpoint: `http://127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}/dashboard`
- upstream Web UI endpoint: `http://127.0.0.1:${OPENCLAW_GATEWAY_HOST_PORT:-18789}`
- upstream Gateway WS endpoint: `ws://127.0.0.1:${OPENCLAW_GATEWAY_HOST_PORT:-18789}`
- relay ingress endpoint: `http://127.0.0.1:${OPENCLAW_RELAY_HOST_PORT:-18112}/v1/providers/<provider>/webhook`

Run OpenClaw CLI wizard-like setup directly in container:

```bash
# Inside `./agent openclaw` shell:
openclaw --version
openclaw onboard --workspace /workspace/wizard-default --non-interactive --accept-risk --skip-health --skip-daemon --skip-skills --skip-ui --skip-channels --skip-search
openclaw configure --section channels
openclaw agents add operator --workspace /workspace/wizard-default --non-interactive --json
openclaw agents list
```

CLI runtime now uses four explicit layers:
- immutable stack-managed config:
  - `${AGENTIC_ROOT}/openclaw/config/immutable/openclaw.stack-config.v1.json`
  - owns gateway mode/bind/auth token wiring/tailscale posture
- provider bridge layer:
  - `${AGENTIC_ROOT}/openclaw/config/bridge/openclaw.provider-bridge.json`
  - generated from stack-managed provider secret files and used to seed Telegram/Slack/Discord channel wiring plus optional WhatsApp bootstrap
- validated operator overlay:
  - `${AGENTIC_ROOT}/openclaw/config/overlay/openclaw.operator-overlay.json`
  - allowed keys only: `agents.defaults.workspace`, `tools.profile`, `commands.{native,nativeSkills,restart,ownerDisplay}`, `session.dmScope`
- writable runtime state:
  - `${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/openclaw.state.json`
  - plus `${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/.openclaw/` and `${AGENTIC_ROOT}/openclaw/workspaces/`

`OPENCLAW_CONFIG_PATH` now points to a derived tmpfs file (`/tmp/openclaw.effective.json`) regenerated from those layers before each CLI invocation; it is no longer the source of truth.

Provider secret file contract used by the bridge:
- Telegram: `${AGENTIC_ROOT}/secrets/runtime/telegram.bot_token`
- Discord: `${AGENTIC_ROOT}/secrets/runtime/discord.bot_token`
- Slack Socket Mode: `${AGENTIC_ROOT}/secrets/runtime/slack.bot_token` and `${AGENTIC_ROOT}/secrets/runtime/slack.app_token`
- Slack HTTP mode fallback: `${AGENTIC_ROOT}/secrets/runtime/slack.signing_secret`
- WhatsApp: no static bot token; set `OPENCLAW_PROVIDER_WHATSAPP_ENABLE=true` before `./agent up core`, then complete `openclaw channels login --channel whatsapp` for QR pairing

If you need a "brand-new install" reset (CLI-only or full module reset), follow:
- `docs/runbooks/openclaw-explique-debutants.md` section `8. Reset "installation neuve" (clean reset)`

## Step 4b: Beginner-Safe Setup Path

For a beginner, the safest path is:
1. let the stack own gateway/runtime wiring,
2. use `openclaw onboard` only to seed a valid workspace/provider choice,
3. configure chat channels afterwards with `openclaw configure --section channels`,
4. do not start a second gateway manually.

Recommended baseline inside `./agent openclaw`:

```bash
export OPENCLAW_GATEWAY_TOKEN="$(tr -d '\n' </run/secrets/openclaw.token)"
openclaw onboard \
  --workspace /workspace/openclaw-default \
  --non-interactive \
  --accept-risk \
  --skip-health \
  --skip-daemon \
  --skip-skills \
  --skip-ui \
  --skip-channels \
  --skip-search
openclaw configure --section channels
openclaw agents list
```

Why this is the recommended beginner flow:
- `--workspace /workspace/...` avoids the most common stack-specific breakage.
- `--skip-health` avoids a misleading upstream wizard health probe that expects a gateway on `127.0.0.1:8111`, while this stack exposes the managed upstream gateway on `127.0.0.1:18789`.
- `--skip-daemon` and `--skip-ui` avoid creating the impression that you must run `openclaw gateway run` yourself. In this stack, `./agent up core` already owns the gateway lifecycle.
- `openclaw configure --section channels` is the safe place to add Telegram/Discord/Slack after the base config is valid.

Do not use this for normal stack operation:

```bash
openclaw gateway run
```

That command starts a second unmanaged upstream gateway inside the operator shell. It does not represent the stack-managed `openclaw-gateway` service and can fall back to upstream defaults such as `anthropic/claude-opus-4-6`, which is why you can see misleading "No API key found for provider anthropic" errors there.

## Step 4c: Manual Onboard Wizard Choices (This Stack)

If you run interactive/manual onboarding (`openclaw onboard` prompts, or Web UI onboarding forms), use the following choices.

| Wizard item | Choose in this stack | Why / notes |
|---|---|---|
| Workspace path | `/workspace/<project>` (example: `/workspace/wizard-default`) | Mandatory stack-safe choice. Do not leave the upstream default `/state/cli/openclaw-home/.openclaw/workspace`. |
| Why `/state/...` is wrong here | Never keep it as the selected agent workspace | The validated operator overlay only allows `agents.defaults.workspace` under `/workspace/`. If you keep `/state/...`, capture fails closed with `agents.defaults.workspace must stay under /workspace/` and your onboarding changes may not persist. |
| Is `/state/cli/openclaw-home/.openclaw/workspace` persistent? | Technically yes, but do not select it as the default workspace | `/state` is persistent, but this stack reserves it for CLI/runtime state. User workspaces must stay under `/workspace/...`. |
| Custom provider base URL | `http://ollama-gate:11435/v1` | From containers, use Docker DNS service name `ollama-gate` (not host loopback). |
| "IP of ollama-gate" | Do not set fixed IP | Container IPs are ephemeral. Always use `ollama-gate` hostname on the `agentic` network. |
| API key field for custom provider | Non-empty placeholder (example: `local-gate`) | Empty keys can be rejected by onboarding forms; local `ollama-gate` path does not require a real upstream key. |
| Entrypoint compatibility | OpenAI-compatible / enabled | `ollama-gate` OpenAI endpoint is `/v1/*`. |
| Model ID | `${AGENTIC_DEFAULT_MODEL}` (default: `nemotron-cascade-2:30b`) | Keeps onboarding aligned with stack defaults and `agent doctor` checks. |
| Gateway port | Leave the stack-managed value unchanged if already proposed; do not try to "fix" it manually | The stack-managed upstream gateway service listens on host loopback port `18789`. The core API service is a different service on port `8111`. Mixing them in the wizard causes confusing health output. |
| Gateway auth mode | `Token` | Stack gateway service is configured with `OPENCLAW_GATEWAY_AUTH_MODE=token`. |
| Gateway bind | `Loopback (127.0.0.1)` | Required by stack security policy. |
| Tailscale exposure (inside container) | `Off` | Exposure is handled at host level via SSH/Tailscale tunnel to loopback ports. |
| "How should I provide the gateway token?" | `Use SecretRef` -> Environment variable | Matches secret storage contract used by this stack. |
| Secret provider type | `Environment variable` | Recommended for this stack (no external secret manager required). |
| Environment variable name | `OPENCLAW_GATEWAY_TOKEN` | This is the expected SecretRef variable name in onboarding. |
| Why `OPENCLAW_GATEWAY_TOKEN` is not present by default in shell | Expected behavior | Token is file-backed (`/run/secrets/openclaw.token`) and intentionally not auto-exported to reduce accidental leakage. |
| Zsh shell completion | Usually `Off` | Optional convenience only; not required for stack operation. |

Set the onboarding env variable explicitly when needed in `./agent openclaw` shell:

```bash
export OPENCLAW_GATEWAY_TOKEN="$(tr -d '\n' </run/secrets/openclaw.token)"
```

Quick probe from inside the `openclaw` container context:

```bash
curl -fsS http://ollama-gate:11435/healthz
curl -fsS http://ollama-gate:11435/v1/models | sed -n '1,40p'
```

## Step 4d: What Went Wrong in the Broken Example

The failure report mixed three separate concepts:

1. The wizard kept the default workspace under `/state/cli/openclaw-home/.openclaw/workspace`.
2. The stack only accepts persisted operator workspaces under `/workspace/...`.
3. A manual `openclaw gateway run` was started afterwards, which is not the managed gateway service used by this stack.

Effect of each issue:
- `agents.defaults.workspace must stay under /workspace/`
  - This is the real configuration error.
  - It means onboarding tried to persist a default workspace outside the allowed stack mount.
  - Result: the wrapper refused to save the overlay, so some onboarding choices were not captured cleanly.

- `Health check failed: gateway closed (1006...)` against `ws://127.0.0.1:8111`
  - This is a wizard/runtime mismatch, not the primary failure.
  - In this stack, the OpenClaw API lives on `8111`, but the managed upstream gateway UI/WS lives on `18789`.
  - The upstream onboarding health probe assumes a local gateway on `8111`, which is not how this stack is split.

- `No API key found for provider "anthropic"` after `openclaw gateway run`
  - This came from launching an extra upstream gateway by hand.
  - That process used upstream defaults because it was not the managed service path and no Anthropic credentials were configured.
  - This does not mean the stack requires Anthropic. The intended local provider remains `ollama-gate`.

## Step 4e: Clean Recovery After This Specific Failure

If you hit the exact symptoms above, recover with this sequence:

```bash
./agent stop openclaw
./agent up core
./agent openclaw
```

Inside the `./agent openclaw` shell:

```bash
export OPENCLAW_GATEWAY_TOKEN="$(tr -d '\n' </run/secrets/openclaw.token)"
openclaw onboard \
  --workspace /workspace/openclaw-default \
  --non-interactive \
  --accept-risk \
  --skip-health \
  --skip-daemon \
  --skip-skills \
  --skip-ui \
  --skip-channels \
  --skip-search
openclaw configure --section channels
openclaw agents list
```

Then verify from the host:

```bash
./agent doctor
./agent ls
./agent logs openclaw
```

Optional sanity checks for persisted stack-safe values:

```bash
cat "${AGENTIC_ROOT}/openclaw/config/overlay/openclaw.operator-overlay.json"
cat "${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/openclaw.state.json"
```

Expected outcome:
- overlay file contains `agents.defaults.workspace` only under `/workspace/...`,
- no need to run `openclaw gateway run`,
- host dashboard/UI remains on `http://127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}/dashboard`,
- upstream Web UI/WS remains on `http://127.0.0.1:${OPENCLAW_GATEWAY_HOST_PORT:-18789}` and `ws://127.0.0.1:${OPENCLAW_GATEWAY_HOST_PORT:-18789}`.

## Step 5: Access Dashboard via SSH/Tailscale Tunnel

Dashboard remains loopback-only on the DGX host.

Linux/macOS (OpenSSH):

```bash
ssh -N -L 18111:127.0.0.1:18111 <user>@<dgx-host-or-tailscale-ip>
# then open:
# http://127.0.0.1:18111/dashboard
```

Windows PowerShell (OpenSSH client):

```powershell
ssh -N -L 18111:127.0.0.1:18111 <user>@<dgx-host-or-tailscale-ip>
# then open:
# http://127.0.0.1:18111/dashboard
```

Windows PuTTY:
1. `Connection > SSH > Tunnels`
2. Source port: `18111`
3. Destination: `127.0.0.1:18111`
4. Add, then connect to `<dgx-host-or-tailscale-ip>`
5. Open `http://127.0.0.1:18111/dashboard` locally

If you need upstream OpenClaw Web UI + Gateway WS in parallel:

Linux/macOS (OpenSSH):

```bash
ssh -N -L 18789:127.0.0.1:18789 <user>@<dgx-host-or-tailscale-ip>
# then open:
# http://127.0.0.1:18789/
```

If your local machine reports `bind [127.0.0.1]:18789: Permission denied`, use another local source port:

```bash
ssh -N -L 28789:127.0.0.1:18789 <user>@<dgx-host-or-tailscale-ip>
# then open:
# http://127.0.0.1:28789/
```

## Step 6: Validate Health, Dashboard, Relay, and Compliance

Run compliance and OpenClaw tests:

```bash
./agent doctor
./agent test K
./agent openclaw approvals list
```

Quick API smoke from host:

```bash
openclaw_port="${OPENCLAW_WEBHOOK_HOST_PORT:-18111}"
openclaw_token="$(cat "${AGENTIC_ROOT}/secrets/runtime/openclaw.token")"

curl -fsS "http://127.0.0.1:${openclaw_port}/healthz"
curl -fsS "http://127.0.0.1:${openclaw_port}/v1/profile"
curl -fsS "http://127.0.0.1:${openclaw_port}/dashboard" >/dev/null
curl -fsS "http://127.0.0.1:${openclaw_port}/v1/dashboard/status"

# Expected 401 without token.
curl -sS -o /tmp/openclaw-noauth.out -w '%{http_code}\n' \
  -X POST -H 'Content-Type: application/json' \
  -d '{"target":"discord:user:example","message":"hello"}' \
  "http://127.0.0.1:${openclaw_port}/v1/dm"

# Expected 202 only if target is in dm_allowlist.txt.
curl -sS -o /tmp/openclaw-auth.out -w '%{http_code}\n' \
  -X POST \
  -H "Authorization: Bearer ${openclaw_token}" \
  -H 'Content-Type: application/json' \
  -d '{"target":"discord:user:example","message":"hello"}' \
  "http://127.0.0.1:${openclaw_port}/v1/dm"

# Relay queue visibility.
relay_port="${OPENCLAW_RELAY_HOST_PORT:-18112}"
curl -fsS "http://127.0.0.1:${relay_port}/v1/queue/status"

# Execution-plane visibility (private docker network).
toolbox_cid="$(docker ps --filter "label=com.docker.compose.service=toolbox" --format '{{.ID}}' | head -n1)"
docker exec "${toolbox_cid}" sh -lc "curl -fsS -H 'Authorization: Bearer ${openclaw_token}' http://openclaw-sandbox:8112/v1/sandboxes/status"
```

Expected:
- `./agent ls` shows `openclaw ... sandboxes=<n>` in the runtime column,
- `http://127.0.0.1:${openclaw_port}/v1/dashboard/status` includes `execution_plane.active`,
- `openclaw-sandbox` reports the active `session+model` sandboxes via `/v1/sandboxes/status`.

Loopback-only host bind check:

```bash
ss -lntp | grep ":${OPENCLAW_WEBHOOK_HOST_PORT:-18111}"
ss -lntp | grep ":${OPENCLAW_GATEWAY_HOST_PORT:-18789}"
ss -lntp | grep ":${OPENCLAW_RELAY_HOST_PORT:-18112}"
```

Expected listener address: `127.0.0.1`, never `0.0.0.0`, for OpenClaw API/dashboard, upstream gateway, and relay.

Provider relay signature probe (telegram example):

```bash
relay_port="${OPENCLAW_RELAY_HOST_PORT:-18112}"
telegram_secret="$(cat "${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.telegram.secret")"
relay_body='{"message":"relay smoke","target":"discord:user:example"}'
relay_ts="$(date +%s)"
relay_sig="$(RELAY_SECRET="${telegram_secret}" RELAY_TS="${relay_ts}" RELAY_BODY="${relay_body}" python3 - <<'PY'
import hashlib
import hmac
import os

secret = os.environ["RELAY_SECRET"].encode("utf-8")
ts = os.environ["RELAY_TS"].encode("utf-8")
body = os.environ["RELAY_BODY"].encode("utf-8")
print(hmac.new(secret, ts + b"." + body, hashlib.sha256).hexdigest())
PY
)"

curl -sS -o /tmp/openclaw-relay-ingest.out -w '%{http_code}\n' \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-Relay-Timestamp: ${relay_ts}" \
  -H "X-Relay-Signature: sha256=${relay_sig}" \
  -d "${relay_body}" \
  "http://127.0.0.1:${relay_port}/v1/providers/telegram/webhook"
```

Expected: HTTP `202` with `queued` or `duplicate` status.

## Step 7: Operate and Rotate

Logs:

```bash
./agent logs openclaw
```

If you modify allowlist files, restart OpenClaw core services to reload config:

```bash
./agent stop openclaw
./agent up core
```

Rotate OpenClaw secrets:

```bash
umask 077
openssl rand -hex 24 > "${AGENTIC_ROOT}/secrets/runtime/openclaw.token"
openssl rand -hex 24 > "${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret"
openssl rand -hex 24 > "${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.telegram.secret"
openssl rand -hex 24 > "${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.whatsapp.secret"
chmod 600 "${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.telegram.secret" \
  "${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.whatsapp.secret"
./agent stop openclaw
./agent up core
./agent doctor
```

## Troubleshooting

- `openclaw service is not running`
  - start or recreate the core stack with `./agent up core`.

- `requires a secret file with mode 600`
  - create/fix `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`, `openclaw.webhook_secret`, `openclaw.relay.telegram.secret`, and `openclaw.relay.whatsapp.secret`, then `chmod 600`.

- `integration profile is invalid`
  - restore from template:
    - `examples/optional/openclaw.integration-profile.v1.json`
    - `${AGENTIC_ROOT}/openclaw/config/integration-profile.current.json`

- `/overlay/openclaw.operator-overlay.json: agents.defaults.workspace must stay under /workspace/`
  - onboarding tried to persist a default workspace outside the allowed stack mount.
  - rerun onboarding with `--workspace /workspace/<project>` or choose `/workspace/<project>` in the wizard.

- `Health check failed: gateway closed (1006 abnormal closure (no close frame))`
  - when this appears at the end of `openclaw onboard`, it usually means the upstream wizard probed `127.0.0.1:8111` instead of the stack-managed upstream gateway on `127.0.0.1:18789`.
  - use the recommended onboarding command with `--skip-health`; validate the real stack health with `./agent doctor`, `./agent ls`, and `./agent logs openclaw`.

- `No API key found for provider "anthropic"` after `openclaw gateway run`
  - you started an extra unmanaged gateway process from inside the operator shell.
  - stop it, return to the stack-managed lifecycle (`./agent up core`), and do not use `openclaw gateway run` for normal operation in this repository.

- DM call returns `403`
  - target is not present in `dm_allowlist.txt` (or file changes were not reloaded yet).

- Relay call returns `403`
  - provider signature/timestamp is invalid, secret mismatch, or clock skew exceeds allowed window.

- Relay queue `dead` count increases
  - downstream OpenClaw webhook injection failed repeatedly; inspect:
    - `${AGENTIC_ROOT}/openclaw/relay/logs/relay-audit.jsonl`
    - `${AGENTIC_ROOT}/openclaw/relay/state/queue/dead/`
  - then fix root cause (token/secret mismatch, openclaw service unavailable), and replay manually if required.

## Security Notes

- No `docker.sock` mount is used for OpenClaw in this stack.
- Published ingress is local loopback only (`127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`).
- OpenClaw and sandbox containers run with `cap_drop: ALL` and `no-new-privileges`.
- Secrets are file-based under `${AGENTIC_ROOT}/secrets/runtime`, outside git.
- For upstream gateway hardening patterns (sandbox + controlled egress), see:
  - `docs/security/openclaw-sandbox-egress.md`
