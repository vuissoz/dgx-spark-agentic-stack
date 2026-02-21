# ADR-0022 — Step C3/D4: TRT-LLM backend profile and deterministic gate routing

## Status
Accepted

## Context
Remaining scope for PLAN step C3/D4 required:
- optional TRT-LLM backend service without host exposure,
- deterministic model-based routing in `ollama-gate` (`ollama` vs `trtllm`),
- backend audit evidence in gate logs,
- explicit failure when a model routed to `trtllm` cannot be served.

## Decision
1. Add `trtllm` service to `compose/compose.core.yml` under profile `trt`.
2. Keep `trtllm` internal-only (no `ports:` publish) and attach it only to a dedicated internal network (`agentic-llm`) shared with `ollama-gate`.
3. Persist TRT runtime paths under `${AGENTIC_ROOT}/trtllm/{models,state,logs}`.
4. Version routing policy in `${AGENTIC_ROOT}/gate/config/model_routes.yml` seeded from `examples/core/model_routes.yml`.
5. Extend `ollama-gate` to:
   - resolve backend by model pattern from routing policy,
   - expose resolved `backend` in JSON logs and response headers,
   - return explicit `backend_unavailable` errors for routed `trtllm` requests when backend is down, with no silent fallback.
6. Add tests:
   - `tests/C3_trtllm_basic.sh`
   - `tests/D4_gate_backend_routing.sh`

## Consequences
- Default baseline behavior is unchanged (`trtllm` remains disabled unless `COMPOSE_PROFILES=trt`).
- C3/D4 tests skip when `trt` profile is not active.
- Operators can enable TRT routing incrementally while preserving a single client endpoint (`ollama-gate`).
