# ADR-0025 — Step D7: Local MCP service for gate runtime visibility

## Context

Step D7 requires an internal MCP endpoint that local agent containers can consume to:
- read the currently served model/backend/provider for a session,
- read remaining external quota counters,
- request an explicit sticky model switch for a session,
while keeping the service internal-only, authenticated, rate-limited, and auditable.

## Decision

1. Add a dedicated core service `gate-mcp` in `compose/compose.core.yml`:
   - internal network only (`agentic`),
   - no host `ports:` publication,
   - `read_only`, `cap_drop=ALL`, `no-new-privileges`.
2. Implement `gate-mcp` as a lightweight HTTP service (`deployments/gate_mcp/service.py`) with:
   - token auth (`Authorization: Bearer ...`) sourced from `${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token`,
   - in-memory token bucket rate limiting,
   - audit JSONL log in `${AGENTIC_ROOT}/gate/mcp/logs/audit.jsonl`.
3. Expose MCP tool execution endpoint `/v1/tools/execute` with tools:
   - `gate.current_model` (reads `ollama-gate` admin session state),
   - `gate.quota_remaining` (reads `ollama-gate` quota snapshot),
   - `gate.switch_model` (validated explicit switch through `ollama-gate` admin endpoint).
4. Wire all agent containers with dedicated runtime contract:
   - `GATE_MCP_URL=http://gate-mcp:8123`,
   - `GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token`,
   - read-only mount of the token file.

## Consequences

- Agents gain deterministic runtime introspection and model switch control without direct host exposure.
- Unauthorized callers and burst abuse are rejected with explicit errors (`401` / `429`) and audit traces.
- Runtime bootstrap now provisions the local MCP token and writable MCP log/state paths under `${AGENTIC_ROOT}/gate/mcp`.
