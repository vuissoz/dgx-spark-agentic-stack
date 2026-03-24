# ADR-0080: OpenClaw in-chat `/openclaw status` via managed slash skill and local status tool

Date: 2026-03-24
Status: Accepted

## Context

Issue `dgx-spark-agentic-stack-irt` asks for a minimal in-chat operator surface for OpenClaw, inspired by NemoClaw's `/nemoclaw status`.

The stack already had:

- a host operator surface: `agent openclaw status`,
- a sanitized local status API: `GET /v1/dashboard/status`,
- separate control-plane and execution-plane state in the OpenClaw runtime.

What was missing:

- a chat-native command for quick status checks from the OpenClaw UI,
- without routing through `./agent`,
- without exposing secrets, token material, or host-only paths.

## Decision

Implement `/openclaw status` as a stack-managed OpenClaw plugin+skill pair stored in the OpenClaw home state:

- plugin root:
  - `${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/.openclaw/extensions/openclaw-chat-status`
- slash command skill:
  - `skills/openclaw/SKILL.md`
- runtime tool:
  - `openclaw_chat_status_command`

Design choices:

1. The slash command is a user-invocable skill named `openclaw`.
   - `command-dispatch: tool`
   - `command-tool: openclaw_chat_status_command`
   - `disable-model-invocation: true`
2. The tool runs inside the OpenClaw runtime and reads the already-sanitized local status surface:
   - `http://openclaw:8111/v1/dashboard/status`
3. The tool renders a short text summary containing only operator-safe data:
   - module status,
   - profile id,
   - sandbox reachability,
   - current/default session ids,
   - default model and provider,
   - active sandbox/session counts,
   - approval queue counters,
   - relay queue counters.
4. The runtime state file pins trust and enables the managed plugin:
   - `plugins.allow += ["openclaw-chat-status"]`
   - `plugins.entries.openclaw-chat-status.enabled = true`

## Consequences

- Operators can type `/openclaw status` directly in chat for a quick stack summary.
- The feature reuses the existing OpenClaw status/runtime contract instead of introducing a second source of truth.
- No management action is exposed in chat; destructive/admin workflows remain on:
  - `agent openclaw ...`
  - the internal sandbox lifecycle API
- No secret, token, raw approval payload, or sensitive host path is surfaced by the command.

## Validation

- `deployments/core/init_runtime.sh` bootstraps the managed plugin and enables it in runtime state.
- `tests/K6_openclaw_cli_dashboard_relay.sh` verifies:
  - managed plugin files are present under `OPENCLAW_HOME`,
  - runtime state pins/enables the plugin,
  - `openclaw plugins list` exposes the plugin,
  - `openclaw skills list` exposes the `/openclaw` skill.
- `scripts/doctor.sh` validates the managed plugin manifest/skill presence and state enablement.
