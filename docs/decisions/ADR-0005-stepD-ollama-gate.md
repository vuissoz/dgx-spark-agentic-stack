# ADR-0005: Step D ollama-gate with queue discipline, sticky sessions, and metrics

## Status
Accepted

## Context
Step D introduces `ollama-gate` as the single control point in front of Ollama, with deterministic concurrency behavior, sticky model policy by session, and operational visibility.

The implementation must stay local-only for host exposure and preserve Step B/Step C hardening patterns.

## Decision
- Add `ollama-gate` to `compose/compose.core.yml`:
  - internal service on `agentic` network (no host port),
  - persisted state and logs in `${AGENTIC_ROOT}/gate/{state,logs}`,
  - security baseline: `read_only`, `tmpfs /tmp`, `cap_drop: ALL`, `no-new-privileges`.
- Implement gate service at `deployments/gate/app.py`:
  - OpenAI-compatible endpoints:
    - `GET /v1/models` (translated from Ollama `/api/tags`),
    - `POST /v1/chat/completions` (translated to Ollama `/api/chat`).
  - Concurrency policy:
    - single active request (`GATE_CONCURRENCY=1`),
    - queued waiting with timeout (`GATE_QUEUE_WAIT_TIMEOUT_SECONDS`),
    - explicit denial response on timeout (`429`, reason `queue_timeout`).
  - Sticky model policy:
    - session identity from `X-Agent-Session`,
    - stable model per session,
    - explicit switch via `POST /admin/sessions/{session}/switch`.
  - Observability:
    - `GET /metrics` with `queue_depth` and decision counters,
    - JSONL structured logs with required fields:
      `ts`, `session`, `project`, `decision`, `latency_ms`, `model_requested`, `model_served`.
- Add runtime prep for gate directories in `deployments/core/init_runtime.sh`.
- Add Step D tests:
  - `tests/D1_gate_up_metrics.sh`
  - `tests/D2_gate_concurrency.sh`
  - `tests/D3_gate_sticky.sh`

## Consequences
- All clients can be converged on `ollama-gate` for serialized and auditable model access.
- Gate behavior is testable without pulling additional models by using deterministic dry-run test mode.
- A follow-up hardening task remains for tighter egress constraints now that control flow depends on the gate path.
