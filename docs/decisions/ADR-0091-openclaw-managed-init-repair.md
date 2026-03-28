# ADR-0091: Managed `agent openclaw init` for stack-owned onboarding and repair

Date: 2026-03-28
Status: Accepted

## Context

OpenClaw already had:
- stack-owned runtime files under `${AGENTIC_ROOT}/openclaw/...`,
- a layered config model that protects immutable stack policy,
- provider bridge sync from file-backed secrets,
- an operator shell via `./agent openclaw`.

But the primary onboarding story still depended on the upstream CLI wizard.
That produced two practical problems in `rootless-dev`:

1. operators could keep the default workspace under `/state/cli/openclaw-home/.openclaw/workspace` instead of `/workspace/...`,
2. operators were pushed toward upstream health/gateway flows that do not match this repository's split between `openclaw` (`8111`) and `openclaw-gateway` (`18789`).

The follow-up Beads issue `dgx-spark-agentic-stack-u326` requires a stack-managed path that is safe to rerun as repair.

## Decision

Add `./agent openclaw init [project]` as the default OpenClaw onboarding and repair entry point.

The command:

1. repairs the host-side OpenClaw overlay/state inputs before normal runtime init runs,
2. starts the stack-managed OpenClaw core services if needed,
3. runs a non-interactive OpenClaw bootstrap against the stack-safe local provider path:
   - workspace under `/workspace/<project>`,
   - `ollama-gate` as the local OpenAI-compatible provider,
   - token auth with `OPENCLAW_GATEWAY_TOKEN` exported from the file-backed stack secret,
   - `--skip-health --skip-daemon --skip-ui --skip-channels --skip-skills --skip-search`,
4. reconciles `agents.defaults.workspace` back into the validated overlay,
5. prints exact next steps for file-backed provider/channel setup,
6. keeps `openclaw onboard`, `openclaw configure --section channels`, and `openclaw gateway run` as expert/manual fallback only.

The pre-repair helper is intentionally host-side so it can fix the broken workspace case before `deployments/core/init_runtime.sh` validates the overlay again.

## Consequences

Positive:
- first-time OpenClaw setup no longer depends on correctly interpreting the upstream wizard,
- rerunning the same command repairs the common `/state/...` workspace drift without destructive reset,
- Telegram/Discord/Slack stay aligned with the provider bridge and file-backed secret contract,
- docs can position the upstream wizard as fallback instead of the primary beginner path.

Trade-offs:
- `agent openclaw init` now owns a repo-specific bootstrap contract and must be kept aligned with upstream OpenClaw CLI flags.
- repair logic may back up and normalize broken overlay/state files rather than preserving every invalid artifact in place.

## Validation

- `tests/K11_openclaw_init.sh` covers:
  - first-run managed init on a fresh stack,
  - rerun/repair after forcing the old `/state/...` workspace drift into the overlay.
- `docs/runbooks/openclaw-onboarding-rootless-dev.md` and beginner OpenClaw docs now point to `./agent openclaw init` as the primary path.
