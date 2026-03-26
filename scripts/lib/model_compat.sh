#!/usr/bin/env bash

agentic_normalize_model_id() {
  local model="${1:-}"

  model="${model##*/}"
  printf '%s\n' "${model}"
}

agentic_tool_call_model_incompatibility_reason() {
  local model normalized

  model="${1:-}"
  normalized="$(agentic_normalize_model_id "${model}")"

  case "${normalized}" in
    qwen3.5:35b)
      printf '%s\n' "known tool-calling regression: Codex/OpenHands can emit pseudo tool tags (for example <read_file>...</read_file>) instead of real tool calls"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

agentic_tool_call_model_recommendation() {
  local model normalized

  model="${1:-}"
  normalized="$(agentic_normalize_model_id "${model}")"

  case "${normalized}" in
    qwen3.5:35b)
      printf '%s\n' "qwen3-coder:30b"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
