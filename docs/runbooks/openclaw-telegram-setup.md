# Runbook: OpenClaw Telegram Channel Setup

This runbook explains how to make the stack-managed OpenClaw Telegram channel work in this repository.

Scope:
- `rootless-dev` day-to-day operation,
- stack-managed OpenClaw Telegram channel via provider bridge,
- Telegram DM access to the OpenClaw gateway-backed agent.

Use this runbook when:
- the Telegram bot does not answer,
- pairing seems unclear,
- OpenClaw says the message failed to process,
- you need the minimum working path without using the upstream channel wizard.

## What "working" means here

In this stack, Telegram works only when all of the following are true:
- the Telegram bot token is valid,
- the OpenClaw core services are running,
- the Telegram channel is enabled by the stack-managed provider bridge,
- the DM sender is paired and/or allowed,
- the local model provider can reach `ollama-gate`,
- the message reaches the gateway and the model call succeeds.

If one of those layers is broken, Telegram usually looks "silent" from the user side.

## Architecture Summary

Telegram is not configured manually through `openclaw configure --section channels` in the normal path.

This repository expects:
- a file-backed bot token at `${AGENTIC_ROOT}/secrets/runtime/telegram.bot_token`,
- a stack-generated provider bridge file at `${AGENTIC_ROOT}/openclaw/config/bridge/openclaw.provider-bridge.json`,
- OpenClaw bootstrap through `./agent openclaw init`,
- local model traffic routed to `http://ollama-gate:11435/v1`.

Normal control path:
1. Telegram bot token is mounted into the OpenClaw containers.
2. `openclaw-provider-bridge` generates the Telegram channel config.
3. `openclaw-gateway` starts the Telegram provider.
4. Telegram DM reaches the gateway.
5. The gateway calls the local provider `custom-ollama-gate-11435`.
6. The reply is sent back to Telegram.

## Step 1: Verify the Telegram Bot Token

Check the runtime secret file:

```bash
stat -c '%a %n' "${AGENTIC_ROOT}/secrets/runtime/telegram.bot_token"
```

Expected mode:
- `600`

Validate the token directly against Telegram:

```bash
TOKEN="$(cat "${AGENTIC_ROOT}/secrets/runtime/telegram.bot_token")"
curl -sS "https://api.telegram.org/bot${TOKEN}/getMe"
```

Expected result:
- `"ok": true`
- the expected bot username, for example `@Conseil_Clawbot`

If Telegram returns `401`:
- the token is wrong,
- the token was rotated,
- or a local test overwrote the runtime secret.

Rewrite the real BotFather token if needed:

```bash
printf '%s\n' '<REAL_BOTFATHER_TOKEN>' > "${AGENTIC_ROOT}/secrets/runtime/telegram.bot_token"
chmod 600 "${AGENTIC_ROOT}/secrets/runtime/telegram.bot_token"
```

## Step 2: Bootstrap OpenClaw the Stack-Managed Way

Do not start from the upstream wizard for the normal path.

Use:

```bash
./agent openclaw init openclaw-default
./agent start openclaw
```

This stack-managed init does all of the important repository-specific work:
- keeps the workspace under `/workspace/...`,
- reuses the file-backed Telegram token,
- configures the local provider against `ollama-gate`,
- persists stack-compatible OpenClaw state.

## Step 3: Confirm the Telegram Channel Is Enabled

Check provider bridge status:

```bash
cat "${AGENTIC_ROOT}/openclaw/state/provider-bridge-status.json"
```

Expected Telegram section:

```json
{
  "configured": true,
  "mode": "long-polling"
}
```

Check the generated bridge config:

```bash
cat "${AGENTIC_ROOT}/openclaw/config/bridge/openclaw.provider-bridge.json"
```

Expected:
- a `channels.telegram.enabled = true` entry,
- `botToken` referencing `TELEGRAM_BOT_TOKEN`

## Step 4: Pair the Sender

Telegram DMs use pairing by default in upstream OpenClaw.

List pending pairing requests from an operator shell:

```bash
./agent openclaw
openclaw pairing list telegram
```

Approve one:

```bash
openclaw pairing approve telegram <code>
```

If there is no pending pairing code, make sure the user has:
- opened the correct bot chat,
- clicked `Start` or sent `/start`,
- then sent a normal message.

## Step 5: Allow the DM Target

In this repository, DM policy is still allowlist-driven on the OpenClaw service side.

Show the current allowlist:

```bash
./agent openclaw policy list
```

Add the Telegram user target:

```bash
./agent openclaw policy add dm-target telegram:user:<telegram_username_without_at>
```

Example:

```bash
./agent openclaw policy add dm-target telegram:user:UlysseChouette
```

Direct file path:
- `${AGENTIC_ROOT}/openclaw/config/dm_allowlist.txt`

## Step 6: Verify the Local Model Provider Path

The OpenClaw Telegram message may enter correctly and still fail before reply if the model provider cannot be reached.

In this repository, the local provider is:
- `custom-ollama-gate-11435`
- `http://ollama-gate:11435/v1`

Check the provider config:

```bash
docker exec agentic-dev-openclaw-1 sh -lc 'openclaw config get models.providers.custom-ollama-gate-11435.baseUrl'
docker exec agentic-dev-openclaw-1 sh -lc 'openclaw config get models.providers.custom-ollama-gate-11435.request.allowPrivateNetwork'
```

Expected:
- `http://ollama-gate:11435/v1`
- `true`

Why this matters:
- OpenClaw's gateway protects outbound provider fetches with an SSRF guard,
- `ollama-gate` resolves to a private/internal Docker address,
- without `request.allowPrivateNetwork=true`, Telegram messages can arrive but model execution fails before reply.

If needed, repair manually:

```bash
docker exec agentic-dev-openclaw-1 sh -lc \
  'openclaw config set models.providers.custom-ollama-gate-11435.request.allowPrivateNetwork true'
./agent stop openclaw
./agent start openclaw
```

## Step 7: Read the Right Logs

There are two important log views.

OpenClaw gateway log:

```bash
docker logs --since 10m agentic-dev-openclaw-gateway-1 2>&1
```

OpenClaw audit log:

```bash
tail -n 80 "${AGENTIC_ROOT}/openclaw/logs/audit.jsonl"
```

What different failures look like:

- `Telegram bot token unauthorized ... getMe returned 401`
  - the Telegram bot token is invalid

- `Inbound message telegram:...`
  - Telegram reached the gateway successfully

- `Blocked: resolves to private/internal/special-use IP address`
  - the local provider path to `ollama-gate` is blocked by OpenClaw SSRF protection

- `LLM request failed: network connection error`
  - the model call failed after ingress; inspect provider fetch errors just above it

- no new Telegram lines at all
  - the bot is not receiving updates, or the wrong bot/token is in use

## Known Good Verification Sequence

Run:

```bash
TOKEN="$(cat "${AGENTIC_ROOT}/secrets/runtime/telegram.bot_token")"
curl -sS "https://api.telegram.org/bot${TOKEN}/getMe"
./agent openclaw status --json
./agent openclaw policy list
docker logs --since 5m agentic-dev-openclaw-gateway-1 2>&1
```

Then from Telegram:
1. open the correct bot,
2. send `/start`,
3. send `hello`

Expected gateway log flow:
- Telegram provider starts cleanly,
- inbound Telegram message appears,
- no `401`,
- no SSRF/private-network block,
- a `sendMessage ok` line appears.

## What Not To Do

For the normal repository path, avoid:
- `openclaw gateway run` manually,
- relying on `openclaw configure --section channels` for Telegram as the primary path,
- storing the token in git or committed `.env` files,
- assuming a Telegram failure is always an egress problem.

This stack is opinionated:
- Telegram token comes from a runtime secret file,
- channel wiring comes from the provider bridge,
- model traffic must stay aligned with `ollama-gate`.

## Related Runbooks

- [OpenClaw Onboarding for `rootless-dev`](./openclaw-onboarding-rootless-dev.md)
- [OpenClaw Explained for Beginners (EN)](./openclaw-explained-beginners.en.md)
- [OpenClaw expliqué pour débutants (FR)](./openclaw-explique-debutants.md)
