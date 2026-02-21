# ADR-0029 — Step J4: hybrid retrieval orchestrator full mode

## Status
Accepted

## Context
Step J4 was implemented as a skeleton (`status=skeleton`, empty dense/lexical hits) to validate wiring and security baseline first.

The CDC expectation is to move beyond contract-only behavior and provide an operational hybrid retrieval path:
- dense retrieval on Qdrant,
- optional lexical retrieval on OpenSearch (`rag-lexical` profile),
- deterministic fusion strategy (`rrf`),
- async indexing worker with auditable execution.

## Decision
- Upgrade `deployments/rag/retriever_api.py` from skeleton to a full internal orchestrator:
  - `/v1/retrieve` now executes real dense retrieval (`qdrant`) and optional lexical retrieval (`opensearch`);
  - fusion is implemented with reciprocal rank fusion (`rrf`);
  - request audit events are persisted in `${AGENTIC_ROOT}/rag/retriever/logs/retrieval.audit.jsonl`.
- Upgrade `deployments/rag/rag_worker.py` to an async indexing worker:
  - task API: `POST /v1/index`, `GET /v1/tasks/<id>`;
  - startup bootstrap task indexes local corpus docs;
  - indexed payloads include canonical chunk fields from Step J3 schema expectations.
- Extend RAG Compose/runtime wiring:
  - new env vars for backend URLs, collection/index names, embedding model, dry-run behavior;
  - runtime mounts for worker docs and opensearch logs.
- Extend compliance/test coverage:
  - `agent doctor` now validates RAG worker/retriever hardening and confirms no host-published ports on retrieval services;
  - `tests/J4_rag_hybrid_skeleton.sh` now validates full behavior (indexing + retrieval contract + fusion + audit) while keeping file name compatibility.

## Consequences
- J4 now provides an end-to-end retrieval pipeline instead of a static contract stub.
- Hybrid retrieval remains internal-only and compatible with the stack security baseline (no host publish, no `docker.sock`).
- Lexical retrieval remains opt-in and isolated behind `rag-lexical` profile to keep baseline footprint minimal.
