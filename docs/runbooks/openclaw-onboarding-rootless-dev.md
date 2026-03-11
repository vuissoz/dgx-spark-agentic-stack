# Runbook: OpenClaw Onboarding for `rootless-dev`

This runbook explains how to configure and validate OpenClaw in this repository when running in `rootless-dev` mode.

Scope:
- this stack's optional OpenClaw module (`optional-openclaw` + `optional-openclaw-sandbox` + `optional-openclaw-relay`),
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
| `openclaw onboard` | `./agent onboard --profile rootless-dev --optional-modules openclaw` |
| `openclaw onboard` (operator in runtime container) | `./agent openclaw` then `openclaw onboard ...` |
| `openclaw configure` | `./agent openclaw` then `openclaw configure --section ...` |
| `openclaw agents add <name>` | `./agent openclaw` then `openclaw agents add <name> --workspace ... --non-interactive` |
| `openclaw gateway run --dashboard` | `AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional` |
| `openclaw gateway status` | `./agent ls` (service state) + `./agent doctor` (compliance) |
| `openclaw gateway logs` | `./agent logs openclaw` |
| `openclaw gateway stop` | `./agent down optional` (or `./agent stop openclaw`) |
| `openclaw node run` | not used in baseline stack path; this stack deploys a local optional OpenClaw API/sandbox pair |

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
  --optional-modules openclaw \
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
  --optional-modules openclaw \
  --output .runtime/env.generated.sh
source .runtime/env.generated.sh
```

## Step 2: Review Generated OpenClaw Artifacts

Onboarding/runtime init prepares these files:
- `${AGENTIC_ROOT}/deployments/optional/openclaw.request`
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret`
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.telegram.secret`
- `${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.whatsapp.secret`
- `${AGENTIC_ROOT}/optional/openclaw/config/dm_allowlist.txt`
- `${AGENTIC_ROOT}/optional/openclaw/config/tool_allowlist.txt`
- `${AGENTIC_ROOT}/optional/openclaw/config/relay_targets.json`
- `${AGENTIC_ROOT}/optional/openclaw/config/integration-profile.v1.json`
- `${AGENTIC_ROOT}/optional/openclaw/config/integration-profile.current.json`

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
${EDITOR:-vi} "${AGENTIC_ROOT}/optional/openclaw/config/dm_allowlist.txt"
```

Edit allowed sandbox tools:

```bash
${EDITOR:-vi} "${AGENTIC_ROOT}/optional/openclaw/config/tool_allowlist.txt"
```

Edit relay provider targets:

```bash
${EDITOR:-vi} "${AGENTIC_ROOT}/optional/openclaw/config/relay_targets.json"
```

Also verify request intent file:

```bash
cat "${AGENTIC_ROOT}/deployments/optional/openclaw.request"
```

It must keep non-empty `need=` and `success=` fields, otherwise optional activation is refused.

## Step 4: Start Services

Start baseline and then optional OpenClaw:

```bash
./agent up core
AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional
```

Open an operator shell for OpenClaw service context:

```bash
./agent openclaw
```

This shell reminds you of:
- host loopback endpoint: `http://127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`
- internal endpoint: `http://optional-openclaw:8111`
- dashboard endpoint: `http://127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}/dashboard`
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

CLI state files persist under:
- `${AGENTIC_ROOT}/optional/openclaw/state/cli/openclaw-home/` (`OPENCLAW_HOME`)
- `${AGENTIC_ROOT}/optional/openclaw/state/cli/openclaw-home/openclaw.json` (`OPENCLAW_CONFIG_PATH`)
- `${AGENTIC_ROOT}/optional/openclaw/workspaces/`

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

## Step 6: Validate Health, Dashboard, Relay, and Compliance

Run compliance and optional tests:

```bash
./agent doctor
./agent test K
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
```

Loopback-only host bind check:

```bash
ss -lntp | grep ":${OPENCLAW_WEBHOOK_HOST_PORT:-18111}"
ss -lntp | grep ":${OPENCLAW_RELAY_HOST_PORT:-18112}"
```

Expected listener address: `127.0.0.1`, never `0.0.0.0`, for both OpenClaw API/dashboard and relay.

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

If you modify allowlist files, restart optional services to reload config:

```bash
./agent down optional
AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional
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
./agent down optional
AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional
./agent doctor
```

## Troubleshooting

- `optional stack gating refused because 'agent doctor' is not green`
  - fix baseline doctor failures first, then re-run optional activation.

- `requires request file` or `missing need=/success=`
  - update `${AGENTIC_ROOT}/deployments/optional/openclaw.request` with non-empty `need` and `success`.

- `requires a secret file with mode 600`
  - create/fix `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`, `openclaw.webhook_secret`, `openclaw.relay.telegram.secret`, and `openclaw.relay.whatsapp.secret`, then `chmod 600`.

- `integration profile is invalid`
  - restore from template:
    - `examples/optional/openclaw.integration-profile.v1.json`
    - `${AGENTIC_ROOT}/optional/openclaw/config/integration-profile.current.json`

- DM call returns `403`
  - target is not present in `dm_allowlist.txt` (or file changes were not reloaded yet).

- Relay call returns `403`
  - provider signature/timestamp is invalid, secret mismatch, or clock skew exceeds allowed window.

- Relay queue `dead` count increases
  - downstream OpenClaw webhook injection failed repeatedly; inspect:
    - `${AGENTIC_ROOT}/optional/openclaw/relay/logs/relay-audit.jsonl`
    - `${AGENTIC_ROOT}/optional/openclaw/relay/state/queue/dead/`
  - then fix root cause (token/secret mismatch, openclaw service unavailable), and replay manually if required.

## Security Notes

- No `docker.sock` mount is used for OpenClaw in this stack.
- Published ingress is local loopback only (`127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`).
- OpenClaw and sandbox containers run with `cap_drop: ALL` and `no-new-privileges`.
- Secrets are file-based under `${AGENTIC_ROOT}/secrets/runtime`, outside git.
- For upstream gateway hardening patterns (sandbox + controlled egress), see:
  - `docs/security/openclaw-sandbox-egress.md`
