# Runbook: Execution Profiles

This stack exposes two runtime profiles controlled by `AGENTIC_PROFILE`.
The profile changes host paths, permission expectations, and compliance strictness.

## Why Profiles Exist

The CDC expects a production-like deployment rooted in `/srv/agentic` with host-level egress guardrails.
That mode is implemented as `strict-prod`.

For local iteration, testing, or CI where root privileges are limited, `rootless-dev` keeps the same container topology and hardening defaults but degrades host-only controls safely.

## Profile Matrix

### `strict-prod` (default)
- Purpose: CDC-aligned operational mode for acceptance and real operations.
- Runtime root: `/srv/agentic`.
- Typical operator context: `sudo` (or equivalent privileges).
- Host controls:
  - applies and validates `DOCKER-USER`-based enforcement via `./agent net apply`,
  - expects filesystem ownership/permissions under `/srv/agentic` to match contract.
- Doctor behavior: structural/security drift is treated as failure (non-zero exit).
- Use this profile for:
  - release validation,
  - production-like smoke tests,
  - final compliance checks before declaring a deployment healthy.

### `rootless-dev`
- Purpose: development mode without requiring root access for normal workflows.
- Runtime root (default): `${HOME}/.local/share/agentic`.
- Typical operator context: unprivileged user.
- Host controls:
  - skips root-only host firewall application/checks by default,
  - keeps container-level controls intact (`127.0.0.1` binds, no `docker.sock`, capabilities drop, etc.).
- Doctor behavior:
  - runs all applicable checks,
  - emits warnings where root-only host checks cannot be enforced.
- Use this profile for:
  - local documentation/testing iterations,
  - validating compose wiring and service behavior,
  - preparing changes before strict acceptance in `strict-prod`.

## How To Select

Select `rootless-dev`:

```bash
export AGENTIC_PROFILE=rootless-dev
./agent profile
```

Switch back to `strict-prod`:

```bash
export AGENTIC_PROFILE=strict-prod
./agent profile
```

The `./agent profile` output is the canonical runtime view and should be checked before `up`, `update`, `doctor`, or rollback operations.

It also reports effective host-mount path variables used by observability services, so operators can verify path overrides before deployment:
- `PROMTAIL_DOCKER_CONTAINERS_HOST_PATH`
- `PROMTAIL_HOST_LOG_PATH`
- `NODE_EXPORTER_HOST_ROOT_PATH`
- `CADVISOR_HOST_ROOT_PATH`
- `CADVISOR_DOCKER_LIB_HOST_PATH`
- `CADVISOR_SYS_HOST_PATH`
- `CADVISOR_DEV_DISK_HOST_PATH`

## Operational Guidance

### Recommended flow during development
1. Work in `rootless-dev` for rapid iteration.
2. Validate changes with `./agent doctor` and targeted tests.
3. Re-run the same scenario in `strict-prod`.
4. Only consider the result acceptance-grade after strict profile checks pass.

### How To Run A `rootless-dev` Test Cycle
Use one shell session with explicit profile exports so both `agent` and test scripts resolve the same runtime/project context:

```bash
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${HOME}/.local/share/agentic"
export AGENTIC_COMPOSE_PROJECT=agentic-dev
export AGENTIC_NETWORK=agentic-dev
export AGENTIC_EGRESS_NETWORK=agentic-dev-egress

./agent profile
./agent up core
./agent up agents,ui,obs,rag
./agent update
./agent doctor
./agent test all
```

Notes:
- `./agent test all` stops on first failure. For progressive diagnosis, run `./agent test A` ... `./agent test L`.
- In `rootless-dev`, some host-root checks are intentionally skipped/degraded (expected behavior).
- Optional module tests (`K*`) require a green baseline doctor and module prerequisites (request files/secrets).

### Optional Compose Profiles
The stack also exposes optional Compose profiles for specific backends/features.

`trt` profile:
- enables the internal `trtllm` backend used by `ollama-gate` model routing,
- keeps `trtllm` internal-only (no host-published port),
- persists runtime data under `${AGENTIC_ROOT}/trtllm/{models,state,logs}`.

Activation example:

```bash
export COMPOSE_PROFILES=trt
./agent up core
./agent test C
./agent test D
```

If `COMPOSE_PROFILES=trt` is not set, `trtllm` is not started and C3/D4 tests skip by design.

### Common pitfalls
- Running `strict-prod` commands without sufficient privileges can create partial host state.
- Assuming a successful `rootless-dev` doctor run implies full CDC conformance is incorrect; host-level controls still need strict validation.
- Mixing profile roots (`/srv/agentic` and `${HOME}/.local/share/agentic`) during troubleshooting can hide state differences. Always confirm active profile first.

## Notes
- `rootless-dev` is intentionally not an acceptance profile.
- Final compliance evidence should always be produced in `strict-prod`.
- For a full first-deployment sequence, use `docs/runbooks/first-time-setup.md`.
