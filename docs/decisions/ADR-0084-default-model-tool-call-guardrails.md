# ADR-0084: Guardrails for Default Tool-Calling Models

## Status
Accepted

## Context
The stack baseline assumes that the default local model is usable for agentic tool-calling in:
- Codex
- OpenHands
- the shared stack onboarding path

Issue `dgx-spark-agentic-stack-0uk` captured a concrete regression with `qwen3.5:35b` in `rootless-dev`: the model can emit pseudo tool tags such as `<read_file>...</read_file>` instead of real tool-call events.

Leaving this model selectable as the stack default makes onboarding succeed while core agent workflows fail later in a confusing way.

## Decision
1. Introduce an explicit tool-calling compatibility policy in `scripts/lib/model_compat.sh`.
2. Block known-incompatible models from:
   - `AGENTIC_DEFAULT_MODEL` during onboarding,
   - `LLM_MODEL` for OpenHands during onboarding.
3. Extend `agent doctor` to fail explicitly when:
   - `AGENTIC_DEFAULT_MODEL` is a known-incompatible tool-calling model,
   - or the running OpenHands container is configured with one.
4. Recommend `qwen3-coder:30b` as the default replacement for the current known-bad case.

## Consequences
- Operators get a deterministic, actionable failure before relying on a broken default model.
- Existing runtimes that still pin `qwen3.5:35b` are surfaced by `agent doctor` instead of failing silently during Codex/OpenHands sessions.
- The compatibility list stays explicit and small until more validated cases need to be added.
