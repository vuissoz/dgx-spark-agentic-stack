# ADR-0107 — J4 RAG operator command, reranker, and OpenSearch bootstrap

## Status
Accepted

## Context
J4 already had dense Qdrant retrieval, optional OpenSearch lexical retrieval, RRF fusion, and an async worker API. Remaining gaps were operational rather than only wiring:
- operators had to call worker HTTP APIs manually;
- lexical relevance checks did not assert technical-token relevance;
- the response contract exposed `rerank` but kept it as a placeholder;
- OpenSearch index creation relied on implicit dynamic mapping.

## Decision
- Add `./agent rag` commands backed by the internal `rag-worker` service:
  - `./agent rag index --wait` triggers `/v1/index`;
  - `./agent rag task <task_id>` inspects task state;
  - `./agent rag bootstrap-lexical` calls the explicit lexical bootstrap endpoint.
- Keep RAG services internal-only. The operator command uses `docker exec` into `rag-worker` and does not publish host ports.
- Add an optional local lexical reranker in `rag-retriever`:
  - disabled by default (`RAG_RERANK_ENABLED=0`);
  - configurable by environment or per internal request;
  - unsupported backends degrade explicitly while preserving fused results.
- Make OpenSearch bootstrap explicit and repeatable:
  - `rag-worker` creates/updates an index mapping/settings document before lexical indexing;
  - the bootstrap result is logged and included in indexing task output.
- Add a lexical-sensitive corpus document and J4 assertions for identifiers, acronyms, versions, and CLI flags.

## Consequences
- Operators can reindex RAG through the normal `agent` entrypoint.
- Fresh lexical deployments fail earlier and with clearer errors if OpenSearch is unavailable or mapping setup fails.
- The default dense-only path remains lightweight and unchanged unless `rag-lexical` or reranking is explicitly enabled.
- The reranker is deterministic and local; it is not a semantic cross-encoder. A future model-backed reranker can be added behind the same response block if the cost/latency tradeoff is acceptable.
