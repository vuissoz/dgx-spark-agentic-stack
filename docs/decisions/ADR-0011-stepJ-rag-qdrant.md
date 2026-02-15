# ADR-0011: Step J RAG baseline (Qdrant + embeddings through ollama-gate)

## Status
Accepted

## Context
Step J introduces a minimal reproducible RAG baseline:
- vector database available on the internal Docker network only,
- ingestion and query smoke scripts with a local mini-corpus,
- embedding path controlled via `ollama-gate` instead of direct model access.

## Decision
- Add `compose/compose.rag.yml` with `qdrant`:
  - no host-published port,
  - persistence under `${AGENTIC_ROOT}/rag/qdrant`,
  - connected to external compose network `${AGENTIC_NETWORK}`.
- Add RAG runtime bootstrap `deployments/rag/init_runtime.sh`:
  - creates `${AGENTIC_ROOT}/rag/{qdrant,docs,scripts}`,
  - seeds docs from `examples/rag/corpus/*.txt`,
  - installs runtime scripts.
- Add host-side scripts:
  - `deployments/rag/ingest.sh`
  - `deployments/rag/query_smoke.sh`
- Extend `ollama-gate` with `/v1/embeddings`:
  - queue/concurrency behavior consistent with `/v1/chat/completions`,
  - dry-run deterministic embeddings for reproducible tests.
- Add tests:
  - `tests/J1_qdrant.sh`
  - `tests/J2_rag_smoke.sh`

## Consequences
- Baseline RAG can run without exposing Qdrant externally.
- Ingestion/query tests remain runnable even without a local embedding model by using gate dry-run mode.
- The embedding path stays observable through gate logs and policies.
