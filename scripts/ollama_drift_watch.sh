#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

usage() {
  cat <<'USAGE'
Usage:
  agent ollama-drift watch [--ack-baseline] [--no-beads] [--issue-id <id>] [--state-dir <path>] [--sources-dir <path>] [--sources <csv>] [--timeout-sec <int>] [--quiet]

Description:
  Watch upstream Ollama contract drift for launch/integrations/API compatibility docs.
  --sources limits verification to a comma-separated subset among:
  cli,codex,claude,opencode,openclaw,hermes,openai,anthropic

Exit codes:
  0  no drift detected
  2  drift detected
  1  operational error
USAGE
}

log() {
  [[ "${QUIET}" == "1" ]] && return 0
  printf '%s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

source_url() {
  local source_id="$1"
  case "${source_id}" in
    cli)
      printf '%s\n' 'https://raw.githubusercontent.com/ollama/ollama/main/docs/cli.mdx'
      ;;
    codex)
      printf '%s\n' 'https://raw.githubusercontent.com/ollama/ollama/main/docs/integrations/codex.mdx'
      ;;
    claude)
      printf '%s\n' 'https://raw.githubusercontent.com/ollama/ollama/main/docs/integrations/claude-code.mdx'
      ;;
    opencode)
      printf '%s\n' 'https://raw.githubusercontent.com/ollama/ollama/main/docs/integrations/opencode.mdx'
      ;;
    openclaw)
      printf '%s\n' 'https://raw.githubusercontent.com/ollama/ollama/main/docs/integrations/openclaw.mdx'
      ;;
    hermes)
      printf '%s\n' 'https://raw.githubusercontent.com/ollama/ollama/main/docs/integrations/hermes.mdx'
      ;;
    openai)
      printf '%s\n' 'https://raw.githubusercontent.com/ollama/ollama/main/docs/api/openai-compatibility.mdx'
      ;;
    anthropic)
      printf '%s\n' 'https://raw.githubusercontent.com/ollama/ollama/main/docs/api/anthropic-compatibility.mdx'
      ;;
    *)
      return 1
      ;;
  esac
}

required_patterns() {
  local source_id="$1"
  case "${source_id}" in
    cli)
      cat <<'EOF_PATTERNS'
ollama launch
Supported integrations
OpenCode
Claude Code
Codex
EOF_PATTERNS
      ;;
    codex)
      cat <<'EOF_PATTERNS'
ollama launch codex
ollama launch codex --config
OLLAMA_API_KEY
EOF_PATTERNS
      ;;
    claude)
      cat <<'EOF_PATTERNS'
ollama launch claude
ollama launch claude --config
ANTHROPIC_AUTH_TOKEN
ANTHROPIC_BASE_URL=http://localhost:11434
EOF_PATTERNS
      ;;
    opencode)
      cat <<'EOF_PATTERNS'
ollama launch opencode
ollama launch opencode --config
~/.config/opencode/opencode.json
EOF_PATTERNS
      ;;
    openclaw)
      cat <<'EOF_PATTERNS'
ollama launch openclaw
ollama launch openclaw --config
ollama launch openclaw --model
ollama launch clawdbot
openclaw configure --section channels
openclaw gateway stop
EOF_PATTERNS
      ;;
    hermes)
      cat <<'EOF_PATTERNS'
ollama launch hermes
http://127.0.0.1:11434/v1
hermes gateway setup
hermes setup
EOF_PATTERNS
      ;;
    openai)
      cat <<'EOF_PATTERNS'
/v1/chat/completions
/v1/responses
/v1/embeddings
http://localhost:11434/v1/
EOF_PATTERNS
      ;;
    anthropic)
      cat <<'EOF_PATTERNS'
/v1/messages
ANTHROPIC_AUTH_TOKEN
ANTHROPIC_BASE_URL=http://localhost:11434
EOF_PATTERNS
      ;;
    *)
      return 1
      ;;
  esac
}

parse_sources_csv() {
  local raw_csv="$1"
  local -a parsed=()
  local -a tokens=()
  local token=""
  local normalized=""
  local -A allowed=(
    [cli]=1
    [codex]=1
    [claude]=1
    [opencode]=1
    [openclaw]=1
    [hermes]=1
    [openai]=1
    [anthropic]=1
  )
  local -A seen=()

  if [[ -z "${raw_csv}" ]]; then
    printf '%s\n' cli codex claude opencode openclaw hermes openai anthropic
    return 0
  fi

  IFS=',' read -r -a tokens <<<"${raw_csv}"
  for token in "${tokens[@]}"; do
    normalized="${token// /}"
    [[ -n "${normalized}" ]] || continue
    if [[ -z "${allowed[${normalized}]:-}" ]]; then
      die "unknown source id for --sources: ${normalized} (allowed: cli,codex,claude,opencode,openclaw,hermes,openai,anthropic)"
    fi
    if [[ -n "${seen[${normalized}]:-}" ]]; then
      continue
    fi
    parsed+=("${normalized}")
    seen["${normalized}"]=1
  done

  [[ "${#parsed[@]}" -gt 0 ]] || die "--sources must include at least one valid source id"
  printf '%s\n' "${parsed[@]}"
}

source_input_path() {
  local source_id="$1"
  local candidate=""

  if [[ -z "${SOURCES_DIR}" ]]; then
    return 1
  fi

  candidate="${SOURCES_DIR}/${source_id}.mdx"
  if [[ -f "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  candidate="${SOURCES_DIR}/${source_id}.txt"
  if [[ -f "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  return 1
}

fetch_source() {
  local source_id="$1"
  local output_file="$2"
  local local_source=""
  local url=""

  if local_source="$(source_input_path "${source_id}" 2>/dev/null)"; then
    cp "${local_source}" "${output_file}"
    return 0
  fi

  url="$(source_url "${source_id}")" || die "unknown source id: ${source_id}"
  if ! curl -fsSL --max-time "${TIMEOUT_SEC}" "${url}" -o "${output_file}"; then
    die "unable to fetch upstream source '${source_id}' (${url})"
  fi
}

sha256_file() {
  local file_path="$1"
  sha256sum "${file_path}" | awk '{print $1}'
}

ensure_beads_issue() {
  if bd show "${BEADS_ISSUE_ID}" >/dev/null 2>&1; then
    return 0
  fi

  local created_id
  created_id="$(bd create 'Veille automatisee: drift contrats Ollama launch/integrations' \
    --description 'Issue creee automatiquement par scripts/ollama_drift_watch.sh suite a un drift contractuel upstream Ollama.' \
    --labels ci,drift,ollama \
    --type task \
    --priority 2 \
    --silent)"

  [[ -n "${created_id}" ]] || die "unable to create Beads issue for drift report"
  BEADS_ISSUE_ID="${created_id}"
}

post_beads_report() {
  local report_file="$1"
  local fingerprint="$2"
  local notified_fingerprint_file="${STATE_DIR}/last_beads_drift_fingerprint"
  local previous_fingerprint=""

  [[ "${NO_BEADS}" == "1" ]] && return 0

  require_cmd bd

  if [[ -f "${notified_fingerprint_file}" ]]; then
    previous_fingerprint="$(cat "${notified_fingerprint_file}" 2>/dev/null || true)"
  fi

  if [[ -n "${previous_fingerprint}" && "${previous_fingerprint}" == "${fingerprint}" ]]; then
    log "ollama-drift: beads comment skipped (same drift fingerprint already notified: ${fingerprint})"
    return 0
  fi

  ensure_beads_issue
  bd update "${BEADS_ISSUE_ID}" --status open >/dev/null
  bd comments add "${BEADS_ISSUE_ID}" -f "${report_file}" >/dev/null

  printf '%s\n' "${fingerprint}" >"${notified_fingerprint_file}"
  chmod 0640 "${notified_fingerprint_file}" || true

  log "ollama-drift: beads issue updated id=${BEADS_ISSUE_ID}"
}

ACK_BASELINE=0
NO_BEADS=0
QUIET=0
TIMEOUT_SEC="20"
SOURCES_DIR="${AGENTIC_OLLAMA_DRIFT_SOURCES_DIR:-}"
SOURCES_CSV="${AGENTIC_OLLAMA_DRIFT_SOURCES:-}"
STATE_DIR="${AGENTIC_OLLAMA_DRIFT_STATE_DIR:-${AGENTIC_ROOT}/deployments/ollama-drift}"
BEADS_ISSUE_ID="${AGENTIC_OLLAMA_DRIFT_BEADS_ISSUE_ID:-dgx-spark-agentic-stack-ygu}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ack-baseline)
      ACK_BASELINE=1
      shift
      ;;
    --no-beads)
      NO_BEADS=1
      shift
      ;;
    --issue-id)
      [[ $# -ge 2 ]] || die "missing value for --issue-id"
      BEADS_ISSUE_ID="$2"
      shift 2
      ;;
    --state-dir)
      [[ $# -ge 2 ]] || die "missing value for --state-dir"
      STATE_DIR="$2"
      shift 2
      ;;
    --sources-dir)
      [[ $# -ge 2 ]] || die "missing value for --sources-dir"
      SOURCES_DIR="$2"
      shift 2
      ;;
    --sources)
      [[ $# -ge 2 ]] || die "missing value for --sources"
      SOURCES_CSV="$2"
      shift 2
      ;;
    --timeout-sec)
      [[ $# -ge 2 ]] || die "missing value for --timeout-sec"
      TIMEOUT_SEC="$2"
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "${TIMEOUT_SEC}" =~ ^[0-9]+$ ]] || die "--timeout-sec must be an integer"
[[ -n "${STATE_DIR}" ]] || die "state directory cannot be empty"

if [[ -n "${SOURCES_DIR}" && ! -d "${SOURCES_DIR}" ]]; then
  die "sources directory does not exist: ${SOURCES_DIR}"
fi

require_cmd curl
require_cmd diff
require_cmd sha256sum

install -d -m 0750 "${STATE_DIR}"
install -d -m 0750 "${STATE_DIR}/baseline"
install -d -m 0750 "${STATE_DIR}/latest"
install -d -m 0750 "${STATE_DIR}/reports"

timestamp="$(date -u +'%Y%m%dT%H%M%SZ')"
report_file="${STATE_DIR}/reports/${timestamp}-report.txt"
latest_report_link="${STATE_DIR}/latest-report.txt"
latest_json="${STATE_DIR}/latest-report.json"

source_ids=()
while IFS= read -r source_id; do
  [[ -n "${source_id}" ]] || continue
  source_ids+=("${source_id}")
done < <(parse_sources_csv "${SOURCES_CSV}")

summary_lines=()
drift_events=()
initialized_baselines=()
updated_baselines=()

{
  printf 'ollama-contract-watch report\n'
  printf 'timestamp_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf 'profile=%s\n' "${AGENTIC_PROFILE}"
  printf 'state_dir=%s\n' "${STATE_DIR}"
  if [[ -n "${SOURCES_DIR}" ]]; then
    printf 'sources_dir=%s\n' "${SOURCES_DIR}"
  else
    printf 'sources=upstream\n'
  fi
  printf 'source_ids=%s\n' "${source_ids[*]}"
  printf '\n'

  for source_id in "${source_ids[@]}"; do
    latest_file="${STATE_DIR}/latest/${source_id}.mdx"
    baseline_file="${STATE_DIR}/baseline/${source_id}.mdx"

    fetch_source "${source_id}" "${latest_file}"

    source_hash="$(sha256_file "${latest_file}")"
    source_ref=""
    if [[ -n "${SOURCES_DIR}" ]]; then
      source_ref="$(source_input_path "${source_id}" 2>/dev/null || true)"
      source_ref="${source_ref:-<missing-local-source>}"
    else
      source_ref="$(source_url "${source_id}")"
    fi

    printf '[source:%s]\n' "${source_id}"
    printf 'ref=%s\n' "${source_ref}"
    printf 'sha256=%s\n' "${source_hash}"

    if [[ ! -f "${baseline_file}" ]]; then
      cp "${latest_file}" "${baseline_file}"
      chmod 0640 "${baseline_file}" || true
      initialized_baselines+=("${source_id}")
      printf 'baseline=initialized\n'
    else
      baseline_hash="$(sha256_file "${baseline_file}")"
      printf 'baseline_sha256=%s\n' "${baseline_hash}"
      if [[ "${baseline_hash}" != "${source_hash}" ]]; then
        if [[ "${ACK_BASELINE}" == "1" ]]; then
          cp "${latest_file}" "${baseline_file}"
          chmod 0640 "${baseline_file}" || true
          updated_baselines+=("${source_id}")
          printf 'baseline=updated_by_ack\n'
        else
          drift_events+=("${source_id}:hash:${baseline_hash}->${source_hash}")
          diff_file="${STATE_DIR}/reports/${timestamp}-${source_id}.diff"
          set +e
          diff -u "${baseline_file}" "${latest_file}" >"${diff_file}"
          diff_rc=$?
          set -e
          if [[ "${diff_rc}" -eq 0 ]]; then
            :
          elif [[ "${diff_rc}" -eq 1 ]]; then
            :
          else
            die "failed to compute diff for source '${source_id}'"
          fi
          printf 'drift=content_changed\n'
          printf 'diff_excerpt_begin\n'
          sed -n '1,80p' "${diff_file}"
          printf 'diff_excerpt_end\n'
        fi
      fi
    fi

    while IFS= read -r required || [[ -n "${required}" ]]; do
      [[ -n "${required}" ]] || continue
      if ! grep -Fq -- "${required}" "${latest_file}"; then
        drift_events+=("${source_id}:missing:${required}")
        printf 'drift=missing_invariant:%s\n' "${required}"
      fi
    done < <(required_patterns "${source_id}")

    printf '\n'
  done
} >"${report_file}"

if [[ "${#initialized_baselines[@]}" -gt 0 ]]; then
  summary_lines+=("baseline_initialized=${initialized_baselines[*]}")
fi
if [[ "${#updated_baselines[@]}" -gt 0 ]]; then
  summary_lines+=("baseline_updated=${updated_baselines[*]}")
fi

status_label="ok"
if [[ "${#drift_events[@]}" -gt 0 ]]; then
  status_label="drift"
fi

fingerprint=""
if [[ "${#drift_events[@]}" -gt 0 ]]; then
  fingerprint="$(printf '%s\n' "${drift_events[@]}" | sha256sum | awk '{print $1}')"
fi

{
  printf '{\n'
  printf '  "timestamp_utc": "%s",\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf '  "status": "%s",\n' "${status_label}"
  printf '  "drift_count": %s,\n' "${#drift_events[@]}"
  if [[ -n "${fingerprint}" ]]; then
    printf '  "drift_fingerprint": "%s",\n' "${fingerprint}"
  else
    printf '  "drift_fingerprint": "",\n'
  fi
  printf '  "report_file": "%s"\n' "${report_file}"
  printf '}\n'
} >"${latest_json}"

if [[ "${#drift_events[@]}" -eq 0 ]]; then
  cp "${report_file}" "${latest_report_link}"
  chmod 0640 "${latest_report_link}" "${latest_json}" "${report_file}" || true
  log "ollama-drift: no drift detected"
  for line in "${summary_lines[@]}"; do
    log "ollama-drift: ${line}"
  done
  log "ollama-drift: report=${report_file}"
  exit 0
fi

{
  printf '\n'
  printf 'drift_summary\n'
  for event in "${drift_events[@]}"; do
    printf -- '- %s\n' "${event}"
  done
  printf 'drift_fingerprint=%s\n' "${fingerprint}"
} >>"${report_file}"

cp "${report_file}" "${latest_report_link}"
chmod 0640 "${latest_report_link}" "${latest_json}" "${report_file}" || true

if [[ "${NO_BEADS}" == "0" ]]; then
  post_beads_report "${report_file}" "${fingerprint}"
else
  log "ollama-drift: beads integration disabled (--no-beads)"
fi

warn "ollama-drift: drift detected count=${#drift_events[@]}"
warn "ollama-drift: report=${report_file}"
exit 2
