# ADR-0052: OpenWebUI Gate-Only Default and Explicit Direct Opt-In

## Status
Accepted

## Context
OpenWebUI was configured with:
- `OPENAI_API_BASE_URL` routed to `ollama-gate`, but
- `OLLAMA_BASE_URL` still hardwired to `ollama`.

This left a direct Ollama path available and created routing incoherence with gate-centric policy/audit expectations.  
Additionally, `H1_openwebui` smoke depended on gate dry-run behavior and failed in `rootless-dev` when gate test-mode was disabled (`GATE_ENABLE_TEST_MODE=0`).

## Decision
1. Switch OpenWebUI defaults to gate-only:
   - `ENABLE_OLLAMA_API=False`
   - `OLLAMA_BASE_URL=http://ollama-gate:11435`
2. Keep direct Ollama as explicit opt-in:
   - `ENABLE_OLLAMA_API=True`
   - `OLLAMA_BASE_URL=http://ollama:11434`
3. Persist and document opt-in controls through onboarding/runtime files:
   - `OPENWEBUI_ENABLE_OLLAMA_API`
   - `OPENWEBUI_OLLAMA_BASE_URL`
4. Extend `agent doctor` with OpenWebUI/gate coherence checks and actionable bypass signaling.
5. Make `tests/H1_openwebui.sh` robust when gate test-mode is disabled by falling back to a non-dry-run gate probe.

## Consequences
- Gate-only routing is now the default OpenWebUI posture.
- Any direct Ollama bypass is explicit and auditable.
- Doctor surfaces routing drift/misconfiguration earlier.
- Rootless-dev OpenWebUI smoke no longer fails on dry-run-only assumptions.
