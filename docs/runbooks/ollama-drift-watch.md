# Runbook: Ollama Contract Drift Watch

This runbook covers automated drift detection for upstream Ollama launch/integrations/API contracts.

## Scope

The watcher validates these official upstream docs sources:

- `docs/cli.mdx` (launch contract)
- `docs/integrations/codex.mdx`
- `docs/integrations/claude-code.mdx`
- `docs/integrations/opencode.mdx`
- `docs/integrations/openclaw.mdx`
- `docs/api/openai-compatibility.mdx`
- `docs/api/anthropic-compatibility.mdx`

Source origin:

- `https://raw.githubusercontent.com/ollama/ollama/main/docs/...`

## What is checked

For each source, the watcher verifies:

- key integration/launch commands,
- key endpoint paths (`/v1/chat/completions`, `/v1/responses`, `/v1/messages`, `/v1/embeddings`),
- key env variable names used by integrations (`OLLAMA_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`),
- content hash drift versus local baseline snapshots.

## Run manually

```bash
export AGENTIC_PROFILE=rootless-dev
./agent ollama-drift watch
```

Exit codes:

- `0`: no drift detected
- `2`: drift detected
- `1`: operational failure (network/tooling/etc.)

Outputs:

- report files: `${AGENTIC_ROOT}/deployments/ollama-drift/reports/`
- latest text report: `${AGENTIC_ROOT}/deployments/ollama-drift/latest-report.txt`
- latest JSON summary: `${AGENTIC_ROOT}/deployments/ollama-drift/latest-report.json`

## Baseline behavior

Baseline snapshots are stored in:

- `${AGENTIC_ROOT}/deployments/ollama-drift/baseline/*.mdx`

First run initializes missing baseline files automatically.

To explicitly accept a non-breaking upstream update and refresh hashes:

```bash
./agent ollama-drift watch --ack-baseline
```

Use this only after review.

## Beads automation

On drift, the watcher updates a Beads issue automatically (default `dgx-spark-agentic-stack-ygu`):

- ensures the issue is open,
- appends a report comment,
- deduplicates repeated notifications via drift fingerprint.

Disable automation for an ad-hoc run:

```bash
./agent ollama-drift watch --no-beads
```

Override issue target:

```bash
./agent ollama-drift watch --issue-id <issue-id>
```

## Weekly scheduling

Install weekly schedule:

```bash
export AGENTIC_PROFILE=rootless-dev
./agent ollama-drift schedule
```

Behavior:

- prefers a `systemd --user` timer,
- falls back to user `crontab` automatically.

Remove schedule:

```bash
./agent ollama-drift schedule --disable
```

Preview without applying changes:

```bash
./agent ollama-drift schedule --dry-run
```

## Incident response workflow

When drift is detected:

1. Read latest report and identify changed sources/invariants.
2. Confirm upstream change is real and intended.
3. Decide action:
   - update stack code/docs/tests, or
   - update watcher invariants/baseline if the upstream contract change is accepted.
4. Re-run:
   - `./agent ollama-drift watch`
   - optionally `--ack-baseline` after validation.
5. Close/update the corresponding Beads issue with remediation details.
