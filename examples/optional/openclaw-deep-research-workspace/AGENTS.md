# AGENTS.md - Deep Research Execution Playbook

This file is intentionally short. `SOUL.md` defines the policy, quality rules, and final contract. This file only describes the execution rhythm.

## Startup Checklist

1. Read `SOUL.md` first.
2. Read `IDENTITY.md`, `USER.md`, and `MEMORY.md`.
3. Initialize the run state in `tmp/` before searching.
4. Keep intermediate evidence in structured JSON artifacts, not only in chat context.

## Execution Rhythm

1. `plan`: define research questions and sufficiency criteria.
2. `scout`: discover the landscape with `web_search` and the local `scripts/tavily.py` adapter.
3. `harvest`: fetch high-value pages and register sources.
4. `verify`: score claims, conflicts, and gaps.
5. `synthesize`: write the report, pass the quality gate, then finalize the M2M JSON.

## Non-Negotiables

- Do not use search snippets as final evidence.
- Do not continue searching just to inflate source count.
- Do not write the final report until `claim_ledger.json` and `coverage_report.json` are populated.
- Do not return `SUCCESS` if the validator fails.
- Do not skip the finalizer step after validation.

## Citation Rule

Use one consistent style everywhere:
- inline Markdown links in the body
- numbered bibliography at the end
