# ADR-0024 — Step D6: LLM Operating Modes + External Provider Quotas

## Status
Accepted

## Context
Step D6 requires:
- an explicit operator mode switch (`local|hybrid|remote`) for LLM backend policy,
- deterministic behavior when local inference services are paused in `remote` mode,
- persistent provider usage counters and enforceable daily/monthly quotas,
- audit-friendly logs and metrics for quota monitoring.

## Decision
1. Add `agent llm mode [local|hybrid|remote]` to set runtime policy in `${AGENTIC_ROOT}/gate/state/llm_mode.json` and persist it in `${AGENTIC_ROOT}/deployments/runtime.env` (`AGENTIC_LLM_MODE`).
2. Extend `ollama-gate` with mode enforcement:
   - `local`: external providers are rejected with explicit `403 external_provider_disabled`.
   - `hybrid`: existing local-first routing behavior with external providers allowed by policy.
   - `remote`: external providers allowed; local backends can be stopped independently.
3. Add persistent quota accounting in `${AGENTIC_ROOT}/gate/state/quotas_state.json`:
   - counters per provider (`requests`, `tokens`, denied count),
   - windowed counters (daily/monthly),
   - optional per-project usage tracking for audit.
4. Support quota limits from routing policy (`model_routes.yml -> quotas.providers`) and optional env overrides (`AGENTIC_OPENAI_*`, `AGENTIC_OPENROUTER_*`).
5. Expose new metrics:
   - `external_requests_total`,
   - `external_tokens_total`,
   - `external_quota_remaining`,
   - `external_quota_denied_total`,
   - `gate_llm_mode`.
6. Add deterministic test `tests/D6_gate_quota_and_local_pause.sh` using gate dry-run mode to validate:
   - `remote` behavior with paused local backends,
   - `local` mode explicit external rejection,
   - quota exceed behavior and metric/log evidence.

## Consequences
- Operators can switch cost/latency posture without changing client endpoints.
- External spend controls are enforceable and auditable at the gate layer.
- Existing workflows remain compatible (`hybrid` default), while `local` provides a strict no-external path.
