# ADR-0034 — Step J4: deterministic dry-run embeddings fallback for RAG

## Status
Accepted

## Context
J4 retrieval and J2/J4 smoke scripts depend on `ollama-gate /v1/embeddings`. In practice, tests can fail when:
- the configured embedding model is not present locally (`model not found`),
- an existing Qdrant collection uses a different vector dimension than the fallback implementation.

This breaks the expected "dry-run remains runnable without local embedding model" behavior from the RAG baseline ADR.

## Decision
- Add deterministic local embedding fallback in RAG components when `RAG_GATE_DRY_RUN=1` and gate embedding requests fail:
  - `deployments/rag/rag_worker.py`
  - `deployments/rag/retriever_api.py`
  - `deployments/rag/ingest.sh`
  - `deployments/rag/query_smoke.sh`
- Default dry-run vector size is aligned to `32` (`RAG_DRY_RUN_VECTOR_SIZE`, optional override).
- Add vector-size compatibility logic against existing Qdrant collection config:
  - when dry-run fallback is used, vectors are regenerated at the collection size to avoid dimension mismatch.
- For lexical indexing, use OpenSearch writes with `refresh=wait_for` for deterministic retrieval visibility after indexing.

## Consequences
- J4 dense retrieval remains functional even if the configured embedding model is unavailable.
- Dry-run behavior is deterministic and resilient across reruns with pre-existing Qdrant collections.
- Lexical retrieval checks are more stable immediately after indexing when `rag-lexical` is enabled.
