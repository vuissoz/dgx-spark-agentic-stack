---
name: knowledge-base-rag
description: Build, refresh, or query a grounded knowledge base over local docs, code, notes, and approved sources.
---

# Knowledge Base (RAG)

Build, refresh, or query a grounded knowledge base over local docs, code, notes, and approved sources.

## Use When
- The user needs retrieval over a document or code corpus.
- Answers must be grounded in local knowledge assets.
- The corpus needs curation, chunking, refresh, or citation rules.

## Default Workflow
1. Define the corpus, freshness needs, and retrieval goal.
2. Identify canonical sources and exclude noisy or stale material.
3. Specify ingestion, metadata, retrieval, and citation behavior.
4. Return the RAG plan, gaps, and validation checks.

## Output
- Return a concise, decision-ready result with assumptions, risks, and recommended next steps.
- If evidence is weak or missing, say so explicitly instead of over-claiming.
