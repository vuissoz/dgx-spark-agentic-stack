#!/usr/bin/env bash
set -euo pipefail

OLLAMA_API_URL="${OLLAMA_API_URL:-http://127.0.0.1:11434}"
OLLAMA_SMOKE_TIMEOUT_SECONDS="${OLLAMA_SMOKE_TIMEOUT_SECONDS:-45}"
OLLAMA_SMOKE_MODEL="${OLLAMA_SMOKE_MODEL:-}"
OLLAMA_SMOKE_GENERATE_MODEL="${OLLAMA_SMOKE_GENERATE_MODEL:-${OLLAMA_PRELOAD_GENERATE_MODEL:-${AGENTIC_DEFAULT_MODEL:-}}}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

resolve_model() {
  if [[ -n "${OLLAMA_SMOKE_MODEL}" ]]; then
    printf '%s\n' "${OLLAMA_SMOKE_MODEL}"
    return 0
  fi

  local tags_json
  tags_json="$(curl -fsS --max-time 12 "${OLLAMA_API_URL}/api/tags")" || return 1
  if [[ -n "${OLLAMA_SMOKE_GENERATE_MODEL}" ]] && printf '%s\n' "${tags_json}" | grep -Fq "\"name\":\"${OLLAMA_SMOKE_GENERATE_MODEL}\""; then
    printf '%s\n' "${OLLAMA_SMOKE_GENERATE_MODEL}"
    return 0
  fi

  printf '%s\n' "${tags_json}" \
    | grep -o '"name":"[^"]*"' \
    | cut -d'"' -f4 \
    | while IFS= read -r candidate; do
        case "${candidate}" in
          *embed*|*embedding*)
            continue
            ;;
        esac
        printf '%s\n' "${candidate}"
        break
      done
}

main() {
  ensure_cmd curl
  ensure_cmd timeout

  curl -fsS --max-time 8 "${OLLAMA_API_URL}/api/version" >/dev/null \
    || die "ollama API unavailable at ${OLLAMA_API_URL}"

  local model
  model="$(resolve_model || true)"
  if [[ -z "${model}" ]]; then
    echo "SKIP: no local model found (set OLLAMA_SMOKE_MODEL to force one)"
    exit 0
  fi

  local payload
  payload="$(cat <<JSON
{"model":"${model}","prompt":"Reply with exactly: dgx-smoke-ok","stream":false}
JSON
)"

  local response_file http_code
  response_file="$(mktemp)"
  trap 'rm -f "${response_file:-}"' EXIT

  http_code="$(
    timeout "${OLLAMA_SMOKE_TIMEOUT_SECONDS}" \
      curl -sS -o "${response_file}" -w '%{http_code}' \
      -H 'Content-Type: application/json' \
      -d "${payload}" \
      "${OLLAMA_API_URL}/api/generate"
  )"

  [[ "${http_code}" == "200" ]] || {
    cat "${response_file}" >&2 || true
    die "generate failed with status ${http_code}"
  }

  grep -q '"response"' "${response_file}" \
    || die "generate response is missing 'response' field"

  response_bytes="$(wc -c <"${response_file}" | tr -d ' ')"
  if [[ "${response_bytes}" -le 2 ]]; then
    die "generate response is unexpectedly empty (${response_bytes} bytes)"
  fi

  echo "OK: ollama generate smoke passed (model=${model}, response_bytes=${response_bytes})"
}

main "$@"
