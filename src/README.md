# `src/agentic/` — v2 Control Plane & Adapters

This directory contains the structural scaffolding for PLAN.md §3–§5 and §11–§13.
It is dependency-light by default and can operate in stub mode when FastAPI/PostgreSQL are not available.

## Structure

| Path | Purpose | PLAN Section |
|---|---|---|
| `contracts/adapters.py` | ABC interfaces for all adapter contracts (§3.2) | §3.2 |
| `models/identity.py` | AgentDefinition, Project, RuntimeContext, Session, Run models (§5.1–5.4) | §5.1–5.4 |
| `control/api.py` | FastAPI control plane with versioned REST & SSE (§3.1) | §3.1 |
| `control/worker.py` | Background worker with PostgreSQL outbox pattern (§3.1) | §3.1 |
| `control/scheduler.py` | Admission controller, queues, priority, multi-agent aggregation (§11) | §11 |
| `migration/router.py` | v1/v2 command router with capability resolution (§13.1) | §13.1 |
| `implementations/` | Concrete adapter implementations (populated per M1–M9) | §3.2 |

## Usage

```bash
# Validate syntax and imports without external dependencies
python3 -c "import ast; [ast.parse(open(f).read()) for f in ['src/agentic/contracts/adapters.py', ...]]"

# Run with FastAPI (requires `pip install -r src/requirements-control.txt`)
python3 -m uvicorn src.agentic.control.api:control_api.app --host 127.0.0.1 --port 8080
```

## Constraints

- No hard-coded paths, secrets, or privileged operations.
- All adapters expose capabilities; they do not simulate absent ones.
- Multi-agent trees aggregate resources (CPU, memory, GPU, tokens) up the hierarchy.
- Idempotent execution via correlation identifiers in the outbox.
