# Eight Queens Agent E2E

This repository is the stack-managed reference problem for the multi-agent,
repository-driven end-to-end integration run.

## Goal

Read the repository, fix the Python implementation under `src/`, run the tests,
and summarize the run.

The problem statement is intentionally stored in the repository instead of in
the orchestrator prompt so that every agent works from the same checked out
source tree.

## Problem

Implement `solve_eight_queens()` in `src/eight_queens.py`.

The function must return all valid solutions to the classic 8 queens puzzle.

Use this exact output format so the result stays easy to verify:

- return a `list` of `92` items,
- each item must be a `tuple` of `8` distinct column indexes, one per row,
- each column index must be an integer between `0` and `7`,
- the outer list must be sorted in ascending lexicographic order.

Every tuple describes one board where:

- no two queens share a column,
- no two queens share a diagonal.

Example format only:

```python
[
    (0, 4, 7, 5, 2, 6, 1, 3),
    (0, 5, 7, 2, 6, 3, 1, 4),
    ...
]
```

## Contract

- The implementation must stay in Python.
- The repository must remain executable with `python3 -m pytest -q`.
- The orchestrator verifies both repository tests and git artefacts.
- Agent accounts must never push to `main`; only `agent/<tool>` branches are
  allowed for agent runs.

## Files

- `src/eight_queens.py`: target implementation
- `tests/test_eight_queens.py`: functional verification
- `.agentic/reference-e2e.manifest.json`: stack-managed manifest
