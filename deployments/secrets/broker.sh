#!/usr/bin/env bash
# deployments/secrets/broker.sh — ExternalAccessBroker (PLAN.md §10)
# Manages short-lived GitHub/HF credentials via SecretStore.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/runtime.sh"

AGENTIC_SECRET_STORE="${AGENTIC_ROOT:-/srv/agentic}/secrets/store.jsonl"
AGENTIC_HF_CACHE_ROOT="${AGENTIC_HF_CACHE_ROOT:-${AGENTIC_ROOT:-/srv/agentic}/hf-cache}"
AGENTIC_GITHUB_TOKEN_KEY="${AGENTIC_GITHUB_TOKEN_KEY:-external.github.token}"
AGENTIC_HF_TOKEN_KEY="${AGENTIC_HF_TOKEN_KEY:-external.hf.token}"

ensure_hf_cache() {
  mkdir -p "${AGENTIC_HF_CACHE_ROOT}"
  chown -R "${AGENT_RUNTIME_UID:-1000}:${AGENT_RUNTIME_GID:-1000}" "${AGENTIC_HF_CACHE_ROOT}" 2>/dev/null || true
  chmod 0755 "${AGENTIC_HF_CACHE_ROOT}"
}

broker_github_rotate() {
  local value="${1:-}"
  if [[ -z "${value}" ]]; then
    # Check env var first
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      value="${GITHUB_TOKEN}"
    elif [[ -f "${AGENTIC_GITHUB_TOKEN_FILE:-${HOME}/.config/github/token}" ]]; then
      value="$(cat "${AGENTIC_GITHUB_TOKEN_FILE:-${HOME}/.config/github/token}")"
    else
      echo "github-token-placeholder" > "/tmp/broker-github-rotate-placeholder"
      value="$(cat /tmp/broker-github-rotate-placeholder)"
      echo "WARN: no GITHUB_TOKEN found in env or file; using placeholder" >&2
    fi
  fi
  
  if [[ -z "${value}" ]]; then
    echo "ERROR: cannot rotate GitHub token — no source available" >&2
    return 1
  fi

  # Store with scope 'github' and 1h TTL (rotated frequently)
  bash "${SCRIPT_DIR}/store.sh" set "${AGENTIC_GITHUB_TOKEN_KEY}" "${value}" github
  rm -f /tmp/broker-github-rotate-placeholder
}

broker_hf_rotate() {
  local value="${1:-}"
  if [[ -z "${value}" ]]; then
    # Check env var first
    if [[ -n "${HF_TOKEN:-}" || -n "${HUGGING_FACE_TOKEN:-}" ]]; then
      value="${HF_TOKEN:-${HUGGING_FACE_TOKEN}}"
    elif [[ -f "${AGENTIC_HF_TOKEN_FILE:-${HOME}/.cache/huggingface/token}" ]]; then
      value="$(cat "${AGENTIC_HF_TOKEN_FILE:-${HOME}/.cache/huggingface/token}")"
    else
      echo "hf-token-placeholder" > "/tmp/broker-hf-rotate-placeholder"
      value="$(cat /tmp/broker-hf-rotate-placeholder)"
      echo "WARN: no HF token found in env or file; using placeholder" >&2
    fi
  fi

  if [[ -z "${value}" ]]; then
    echo "ERROR: cannot rotate HF token — no source available" >&2
    return 1
  fi

  bash "${SCRIPT_DIR}/store.sh" set "${AGENTIC_HF_TOKEN_KEY}" "${value}" hf
  rm -f /tmp/broker-hf-rotate-placeholder
  
  # Ensure cache directory exists for agent containers
  ensure_hf_cache
}

broker_inject() {
  local target_service="$1" target_scope="${2:-}"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  
  # GitHub token
  if bash "${SCRIPT_DIR}/store.sh" get "external.github.token" github >/tmp/broker-github-val 2>/dev/null; then
    cp /tmp/broker-github-val "${tmp_dir}/github_token"
    chmod 0600 "${tmp_dir}/github_token"
  fi
  
  # HF token
  if bash "${SCRIPT_DIR}/store.sh" get "external.hf.token" hf >/tmp/broker-hf-val 2>/dev/null; then
    cp /tmp/broker-hf-val "${tmp_dir}/hf_token"
    chmod 0600 "${tmp_dir}/hf_token"
  fi
  
  echo "${tmp_dir}"
}

broker_health() {
  echo "Broker health check for: ${AGENTIC_PROFILE:-unknown}"
  
  local github_status="missing" hf_status="missing"
  
  if bash "${SCRIPT_DIR}/store.sh" get "${AGENTIC_GITHUB_TOKEN_KEY}" github >/dev/null 2>&1; then
    github_status="present"
  else
    github_status="$(bash "${SCRIPT_DIR}/store.sh" get "${AGENTIC_GITHUB_TOKEN_KEY}" github 2>&1 || true)"
  fi
  
  if bash "${SCRIPT_DIR}/store.sh" get "${AGENTIC_HF_TOKEN_KEY}" hf >/dev/null 2>&1; then
    hf_status="present"
  else
    hf_status="$(bash "${SCRIPT_DIR}/store.sh" get "${AGENTIC_HF_TOKEN_KEY}" hf 2>&1 || true)"
  fi
  
  echo "GitHub token: ${github_status}"
  echo "HF token: ${hf_status}"
  
  ensure_hf_cache
  echo "HF cache root: ${AGENTIC_HF_CACHE_ROOT} (exists=$([ -d "${AGENTIC_HF_CACHE_ROOT}" ] && echo true || echo false))"
}

case "${1:-health}" in
  github-rotate) shift; broker_github_rotate "$@" ;;
  hf-rotate)     shift; broker_hf_rotate "$@" ;;
  inject)        shift; broker_inject "$@" ;;
  health)        broker_health ;;
  *)             echo "Usage: broker.sh {github-rotate|hf-rotate|inject|health}" >&2; exit 1 ;;
esac
