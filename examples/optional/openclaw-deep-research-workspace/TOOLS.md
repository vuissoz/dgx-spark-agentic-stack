# TOOLS.md - Research Toolkit

## Search Stack
Use a hybrid search strategy:
- `web_search` for broad discovery and recency checks
- Tavily for structured extraction, domain filtering, and raw-content oriented scouting
- `web_fetch` for validating high-value pages before they become evidence

## Required Run Artifacts
Every research run must maintain these files in `tmp/`:
- `research_plan.json`
- `query_log.json`
- `source_registry.json`
- `claim_ledger.json`
- `coverage_report.json`

## Local Scripts
- Initialize a research run:
  `python scripts/init_research_run.py --topic "<topic>" --language "<language>"`
- Validate a report before returning `SUCCESS`:
  `python scripts/validate_research_report.py --report "<absolute-report-path>"`

## Verification Sequence
1. Scout the landscape.
2. Harvest full pages.
3. Verify claims against primary or independent sources.
4. Validate the report and artifact set.
