# ADR-0084: Notices for Default Tool-Calling Model Regressions

## Status
Accepted

## Context
The stack baseline assumes that the default local model is usable for agentic tool-calling in:
- Codex
- OpenHands
- the shared stack onboarding path

Issue `dgx-spark-agentic-stack-0uk` captured a concrete regression with `qwen3.5:35b` in `rootless-dev`: the model can emit pseudo tool tags such as `<read_file>...</read_file>` instead of real tool-call events.

At the same time, Ollama upstream advertises Qwen 3.5 with `tools` support, so this repository should treat the regression as a stack integration bug until disproven, not as a permanent model incompatibility contract.

## Decision
1. Introduce an explicit stack regression notice policy in `scripts/lib/model_compat.sh`.
2. Keep onboarding permissive:
   - allow `AGENTIC_DEFAULT_MODEL`,
   - allow OpenHands `LLM_MODEL`,
   - but emit an explicit warning when a model has a known stack tool-calling regression.
3. Extend `agent doctor` to surface the same situation as a warning, not a compliance failure.
4. Recommend `qwen3-coder:30b` as a temporary fallback for operators who need a stable local default while the real integration bug remains open.

## Consequences
- Operators get a deterministic, actionable warning without losing access to models that upstream says should support tools.
- Existing runtimes that pin `qwen3.5:35b` are surfaced by `agent doctor` instead of failing silently during Codex/OpenHands sessions.
- The notice list stays explicit and small until the integration bug is fixed or more validated cases need to be tracked.
