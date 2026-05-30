---
name: deep-research
description: Conduct comprehensive deep research using a compact task contract, structured run artifacts, hybrid search, claim verification, and a local quality gate.
---

# Deep Research Skill

Use this skill when the user asks for deep research, comprehensive analysis, a detailed report, or a multi-source investigation.

Do not answer these requests from memory or by reusing a stale prior report unless the user explicitly asked for a recap, resend, or summary of an already completed report. For a fresh request, retest, rerun, or current-day analysis, always spawn `deep-researcher`. A new user session asking a similar topic is still a fresh request by default.
On the first user turn of a research request, if the message does not explicitly ask for a recap/resend/summary of a previous report, you must not say the report was already completed. Ask clarifying questions and treat it as a new research request.

## Main-Agent Responsibilities

1. Clarify the research target before spawning the subagent.
2. Convert the request into a compact task contract.
3. Before spawn, pre-initialize the research workspace by running `python /workspace/deep-researcher/scripts/init_research_run.py --workspace /workspace/deep-researcher --topic "<goal-summary>" --language "<user-language>" --task-date "<YYYY-MM-DD>"`. This must clear stale files from `/workspace/deep-researcher/tmp`.
4. Spawn `deep-researcher` with the contract only.
5. Accept the result as final only after the subagent returns finalized M2M JSON.
6. Treat the run as suspicious if the research workspace does not materialize a fresh `/workspace/deep-researcher/tmp/research_plan.json` for the current topic and task date early in the run; prefer a rerun over trusting stale artifacts.

## Compact Task Contract

Send the subagent a task shaped like this:

```text
Perform deep research using your local SOUL.md contract.

GOAL:
- <what the user wants to learn or decide>

SCOPE:
- In scope: <topics / questions / regions / time horizon>
- Out of scope: <what not to spend time on>

SUCCESS CRITERIA:
- Answer these research questions:
  1. <question 1>
  2. <question 2>
  3. <question 3>
- Highlight contradictions, gaps, and confidence limits.
- Use primary sources whenever possible.
- Treat source_count as a soft breadth signal, not the pass condition.
- Expect one bounded coverage-expansion pass when core questions remain open or coverage stays below the working threshold.
- Preserve breadth honestly by allowing discovery-only external URLs from `web_search` and Tavily to be materialized into `source_registry.json`, while keeping findings limited to verified or partially verified claims.

TASK DATE:
- <today in YYYY-MM-DD>

DELIVERABLES:
- Final Markdown report in `reports/`
- Required JSON artifacts in `tmp/`
- Finalized M2M JSON response from `scripts/finalize_research_run.py`

LANGUAGE:
- <user language>

CONSTRAINTS:
- Time-sensitive facts must include concrete dates.
- Default temporal framing to the task date unless the user explicitly requests historical analysis.
- The report must explicitly mention the task date in ISO format.
- Machine-readable JSON artifacts should stay English and ASCII-safe even when the report language is non-English.
- Do not optimize for raw source count once coverage is strong.
- Do not return SUCCESS if the local validator fails.
```

## Spawn Settings

Use `sessions_spawn` with:
- `agentId`: `deep-researcher`
- `runTimeoutSeconds`: `1800`
- `thinking`: `medium`

Do not override the subagent model unless there is a confirmed routing/auth issue that requires explicit pinning.
Do not inject hardcoded success criteria like `min_sources: 50` into the spawn ack unless the user explicitly requested a very broad landscape report.

## Status Discipline

When the user asks for progress while the subagent is still running:
- report only actual status, timing, and known metadata
- do not invent findings from incomplete work
- do not summarize conclusions unless they come from a completed report or explicit artifact/log evidence
- if JSON is requested, return clean JSON only

## Quality Checks After Completion

Before post-processing the result, verify:
- `report_path` exists and points into `/workspace/deep-researcher/reports/`
- `source_count` is non-zero
- `artifacts` contains all five required JSON files
- `coverage_score` is present and above the working threshold
- the report passes `report_lint.py`, not just the validator
- `coverage_score` alone is not enough if evidence-gating or encoding-hygiene issues are present
- the run is not trustworthy if artifact state is clearly anchored to a previous task topic or date
- every artifact path is absolute and materialized on disk before treating the run as final
- `status` is not `SUCCESS` when validation failed, artifacts are stale/missing, or open gaps/conflicts dominate the result
- if `report_lint.py` fails, present the output only as a provisional research note even if a PDF was generated

## Soft Source Target

For broad market or landscape reports, 50+ unique sources is still a good target.
For narrower technical investigations, prioritize coverage, source quality, and verification over a hard source quota.

## Delivery

If the research passes validation:
1. Generate PDF from the returned Markdown report when the channel supports files.
2. Send the user a short executive summary.
3. Mention unresolved conflicts or open questions explicitly.

If the research fails validation:
- present it only as `PARTIAL`
- steer or rerun the subagent with the missing coverage, evidence, or artifact requirements
- treat top recommendations as a provisional shortlist with caveats when evidence gating failed
- do not present the report as finalized
