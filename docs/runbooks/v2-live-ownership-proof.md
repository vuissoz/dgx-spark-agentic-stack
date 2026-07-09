# V2 Live Ownership Proof

This runbook executes the v2 single-source-of-truth evidence path against an existing runtime root with a live compose project.

## Preconditions

- The target stack is already deployed and running.
- `./agent profile` resolves the intended runtime, or you know the exact `AGENTIC_ROOT`, profile, and compose project.
- The target runtime has:
  - `deployments/runtime.env`
  - `gate/state/llm_backend.json`
  - `gate/state/llm_backend_runtime.json`
  - `deployments/current`

## Default Path

Use the currently resolved runtime:

```bash
./agent profile
python3 scripts/run_v2_live_single_source_of_truth.py
```

The runner writes evidence under:

```text
${AGENTIC_ROOT}/deployments/test-reports/v2-single-source-of-truth/<timestamp>/evidence.json
```

It fails closed when the compose project has no running containers.

## Explicit Target

Use this when the current shell context is not the desired runtime:

```bash
python3 scripts/run_v2_live_single_source_of_truth.py \
  --agentic-root /srv/agentic \
  --profile strict-prod \
  --compose-project agentic
```

## Expected Success Signal

- command exits `0`
- output includes:
  - `gate_status=pass`
  - `live_stack_containers=<n>` where `<n>` is at least `1`

## Contradictory Ownership Check

If the runtime root is present but the live stack is not running, the command must fail and the evidence file must record:

- `gates.p0-single-source-of-truth.status=fail`
- `domains.live_stack.status=fail`

This is intentional. A passive host root is not accepted as live deployed proof.
