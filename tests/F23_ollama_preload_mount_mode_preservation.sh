#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F23 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

preload_script="${REPO_ROOT}/deployments/ollama/preload_and_lock.sh"
[[ -x "${preload_script}" ]] || fail "preload script is missing or not executable"

tmp_root="$(mktemp -d)"
fake_bin="${tmp_root}/bin"
mkdir -p "${fake_bin}"

cleanup() {
  rm -rf "${tmp_root}"
}
trap cleanup EXIT

cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${FAKE_DOCKER_STATE_DIR:?}"
mount_mode_file="${state_dir}/mount_mode"
container_present_file="${state_dir}/container_present"
compose_log="${state_dir}/compose.log"
pull_log="${state_dir}/pull.log"

subcommand="${1:-}"
shift || true

case "${subcommand}" in
  ps)
    service=""
    while [[ $# -gt 0 ]]; do
      case "${1}" in
        --filter)
          filter="${2:-}"
          case "${filter}" in
            label=com.docker.compose.service=*)
              service="${filter#label=com.docker.compose.service=}"
              ;;
          esac
          shift 2
          ;;
        --format)
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    if [[ "${service}" == "ollama" ]] && [[ -f "${container_present_file}" ]]; then
      printf '%s\n' "fake-ollama-cid"
    fi
    ;;
  inspect)
    format=""
    if [[ "${1:-}" == "--format" ]]; then
      format="${2:-}"
      shift 2
    fi
    cid="${1:-}"
    [[ "${cid}" == "fake-ollama-cid" ]] || exit 1
    mount_mode="$(cat "${mount_mode_file}")"
    case "${format}" in
      *'.Destination'*)
        if [[ "${mount_mode}" == "rw" ]]; then
          printf '%s\n' "true"
        else
          printf '%s\n' "false"
        fi
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  compose)
    while [[ $# -gt 0 ]]; do
      case "${1}" in
        --project-name|-f)
          shift 2
          ;;
        up)
          shift
          break
          ;;
        *)
          shift
          ;;
      esac
    done

    printf 'compose up %s\n' "$*" >>"${compose_log}"
    printf '%s\n' "${OLLAMA_MODELS_MOUNT_MODE:-rw}" >"${mount_mode_file}"
    : >"${container_present_file}"
    ;;
  exec)
    cid="${1:-}"
    shift || true
    [[ "${cid}" == "fake-ollama-cid" ]] || exit 1
    mount_mode="$(cat "${mount_mode_file}")"

    if [[ "${1:-}" == "sh" && "${2:-}" == "-lc" ]]; then
      command="${3:-}"
      case "${command}" in
        id\ -u)
          printf '0\n'
          ;;
        test\ -w*)
          [[ "${mount_mode}" == "rw" ]]
          ;;
        *)
          exit 1
          ;;
      esac
      exit 0
    fi

    if [[ "${1:-}" == "ollama" && "${2:-}" == "pull" ]]; then
      printf 'pull %s\n' "${3:-}" >>"${pull_log}"
      exit 0
    fi

    exit 1
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "${fake_bin}/docker"

cat >"${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "${fake_bin}/curl"

run_case() {
  local case_name="$1"
  local initial_mode="$2"
  local with_running_container="$3"
  local args="$4"
  local expected_final_mode="$5"
  local expected_recreate_count="$6"
  local expected_plain_up_count="$7"

  local case_root="${tmp_root}/${case_name}"
  local state_dir="${case_root}/state"
  local runtime_root="${case_root}/runtime"
  local output_file="${case_root}/output.log"
  mkdir -p "${state_dir}" "${runtime_root}/deployments" "${runtime_root}/ollama/models"

  printf '%s\n' "${initial_mode}" >"${state_dir}/mount_mode"
  if [[ "${with_running_container}" == "1" ]]; then
    : >"${state_dir}/container_present"
  fi

  (
    export PATH="${fake_bin}:$PATH"
    export FAKE_DOCKER_STATE_DIR="${state_dir}"
    export AGENTIC_PROFILE=rootless-dev
    export AGENTIC_ROOT="${runtime_root}"
    export AGENTIC_COMPOSE_PROJECT="agentic-${case_name}"
    export AGENTIC_COMPOSE_DIR="${REPO_ROOT}/compose"
    export OLLAMA_MODELS_DIR="${runtime_root}/ollama/models"
    export OLLAMA_CONTAINER_MODELS_PATH="/models"
    export OLLAMA_MODELS_MOUNT_MODE="${initial_mode}"
    bash "${preload_script}" --generate-model "test-generate" --embed-model "test-embed" --budget-gb 1 ${args}
  ) >"${output_file}" 2>&1 || {
    cat "${output_file}" >&2
    fail "${case_name}: preload script failed"
  }

  local final_mode
  final_mode="$(sed -n 's/^OLLAMA_MODELS_MOUNT_MODE=//p' "${runtime_root}/deployments/runtime.env" | tail -n 1)"
  [[ "${final_mode}" == "${expected_final_mode}" ]] \
    || fail "${case_name}: expected final runtime mount mode ${expected_final_mode}, got ${final_mode:-<unset>}"

  local recreate_count plain_up_count
  if [[ -f "${state_dir}/compose.log" ]]; then
    recreate_count="$(grep -c -- '--force-recreate ollama' "${state_dir}/compose.log" || true)"
    plain_up_count="$(grep -c -- 'compose up -d ollama' "${state_dir}/compose.log" || true)"
  else
    recreate_count="0"
    plain_up_count="0"
  fi
  [[ "${recreate_count}" == "${expected_recreate_count}" ]] \
    || fail "${case_name}: expected ${expected_recreate_count} force-recreate calls, got ${recreate_count}"
  [[ "${plain_up_count}" == "${expected_plain_up_count}" ]] \
    || fail "${case_name}: expected ${expected_plain_up_count} plain up calls, got ${plain_up_count}"

  grep -q '^pull test-generate$' "${state_dir}/pull.log" \
    || fail "${case_name}: generate model pull missing"
  grep -q '^pull test-embed$' "${state_dir}/pull.log" \
    || fail "${case_name}: embed model pull missing"
}

run_case "rw-running-preserved" "rw" "1" "" "rw" "0" "0"
ok "rw-start path keeps rw and avoids unnecessary recreate"

run_case "ro-running-restores-ro" "ro" "1" "" "ro" "2" "0"
ok "ro-start path restores ro after preload by default"

run_case "ro-running-no-lock" "ro" "1" "--no-lock-ro" "rw" "1" "0"
ok "--no-lock-ro keeps rw after temporary switch from ro"

ok "F23_ollama_preload_mount_mode_preservation passed"
