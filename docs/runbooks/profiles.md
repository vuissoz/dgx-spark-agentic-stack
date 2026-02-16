# Runbook: Execution Profiles

## Profiles

The stack supports two explicit profiles via `AGENTIC_PROFILE`.

### `strict-prod` (default)
- Purpose: CDC-compliant production-like deployment.
- Runtime root: `/srv/agentic`.
- Requires host-level privileges for:
  - filesystem ownership/permissions under `/srv/agentic`,
  - `DOCKER-USER` enforcement (`iptables`).
- `agent doctor` treats structural drift as failure.

### `rootless-dev`
- Purpose: local development without root on the main host.
- Runtime root (default): `${HOME}/.local/share/agentic`.
- `DOCKER-USER` checks/application are skipped by default.
- `agent doctor` keeps applicable checks and warns on root-only host controls.

## How To Select

```bash
export AGENTIC_PROFILE=rootless-dev
./agent profile
```

Switch back to strict mode:

```bash
export AGENTIC_PROFILE=strict-prod
./agent profile
```

## Notes
- `rootless-dev` is a development mode, not final CDC compliance.
- Final acceptance gates must be validated in `strict-prod`.
