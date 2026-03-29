#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

agent_bin="${REPO_ROOT}/agent"
[[ -f "${agent_bin}" ]] || fail "agent script missing: ${agent_bin}"

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

runtime_root="${tmp_root}/runtime"
fixture_source="${tmp_root}/fixture-model"
fake_bin="${tmp_root}/fake-bin"
mkdir -p "${runtime_root}" "${fixture_source}" "${fake_bin}"

cat > "${fixture_source}/config.json" <<'JSON'
{"model_type":"nemotron_h"}
JSON
cat > "${fixture_source}/model.safetensors.index.json" <<'JSON'
{"metadata":{"total_size":789},"weight_map":{"lm_head.weight":"model-00001-of-00001.safetensors"}}
JSON
printf 'fixture-weight\n' > "${fixture_source}/model-00001-of-00001.safetensors"

cat > "${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  info)
    exit 0
    ;;
  ps)
    if [[ -f "${AGENTIC_ROOT}/trtllm.state" ]]; then
      printf '%s\n' "fake-trtllm-id"
    fi
    exit 0
    ;;
  inspect)
    if [[ "${*}" == *".State.Status"* ]]; then
      if [[ -f "${AGENTIC_ROOT}/trtllm.state" ]]; then
        cat "${AGENTIC_ROOT}/trtllm.state"
      else
        printf '%s\n' "running"
      fi
    elif [[ "${*}" == *".State.Health.Status"* ]]; then
      if [[ -f "${AGENTIC_ROOT}/trtllm.health" ]]; then
        cat "${AGENTIC_ROOT}/trtllm.health"
      else
        printf '%s\n' "healthy"
      fi
    else
      printf '%s\n' "fake-trtllm-id"
    fi
    exit 0
    ;;
  compose)
    shift
    while [[ $# -gt 0 ]]; do
      case "${1}" in
        --project-name|-f)
          shift 2
          ;;
        up)
          shift
          while [[ $# -gt 0 ]]; do
            case "${1}" in
              -d|--no-deps)
                shift
                ;;
              trtllm)
                printf '%s\n' "running" > "${AGENTIC_ROOT}/trtllm.state"
                printf '%s\n' "healthy" > "${AGENTIC_ROOT}/trtllm.health"
                shift
                ;;
              *)
                shift
                ;;
            esac
          done
          exit 0
          ;;
        stop)
          shift
          if [[ "${1:-}" == "trtllm" ]]; then
            printf '%s\n' "exited" > "${AGENTIC_ROOT}/trtllm.state"
            printf '%s\n' "-" > "${AGENTIC_ROOT}/trtllm.health"
          fi
          exit 0
          ;;
        *)
          shift
          ;;
      esac
    done
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "${fake_bin}/docker"

PATH="${fake_bin}:${PATH}" \
AGENTIC_ROOT="${runtime_root}" \
COMPOSE_PROFILES=trt \
TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8" \
TRTLLM_NATIVE_MODEL_POLICY=strict-nvfp4-local-only \
TRTLLM_NVFP4_PREPARE_SOURCE_DIR="${fixture_source}" \
bash "${agent_bin}" strict-prod trtllm prepare \
  >/tmp/agent-c6-prepare.out 2>&1 || {
    cat /tmp/agent-c6-prepare.out >&2
    fail "agent trtllm prepare failed"
  }

[[ -f "${runtime_root}/trtllm/models/trtllm-model/model.safetensors.index.json" ]] \
  || fail "prepare must populate the single local TRT payload"
ok "agent trtllm prepare populates the configured local TRT payload"

status_output="$(
  PATH="${fake_bin}:${PATH}" \
  AGENTIC_ROOT="${runtime_root}" \
  COMPOSE_PROFILES=trt \
  TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8" \
  TRTLLM_NVFP4_LOCAL_MODEL_DIR="/models/trtllm-model" \
  bash "${agent_bin}" strict-prod trtllm status
)"

printf '%s\n' "${status_output}" | grep -q 'trtllm prepared=yes service_state=missing health=- runtime_mode=- native_ready=-' \
  || fail "status must degrade cleanly to missing when no live trtllm container exists"
printf '%s\n' "${status_output}" | grep -q 'model=https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8 local_dir=/models/trtllm-model ' \
  || fail "status must report the configured TRT model and local directory"
ok "agent trtllm status reports the configured single-model TRT state"

start_output="$(
  PATH="${fake_bin}:${PATH}" \
  AGENTIC_ROOT="${runtime_root}" \
  COMPOSE_PROFILES=trt \
  TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8" \
  TRTLLM_NVFP4_LOCAL_MODEL_DIR="/models/trtllm-model" \
  bash "${agent_bin}" strict-prod trtllm start
)"
printf '%s\n' "${start_output}" | grep -q 'trtllm prepared=yes service_state=running health=healthy ' \
  || fail "start must report a running healthy trtllm service"
ok "agent trtllm start brings the runtime up and reports healthy state"

stop_output="$(
  PATH="${fake_bin}:${PATH}" \
  AGENTIC_ROOT="${runtime_root}" \
  COMPOSE_PROFILES=trt \
  TRTLLM_MODELS="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8" \
  TRTLLM_NVFP4_LOCAL_MODEL_DIR="/models/trtllm-model" \
  bash "${agent_bin}" strict-prod trtllm stop
)"
printf '%s\n' "${stop_output}" | grep -q 'trtllm prepared=yes service_state=exited health=- ' \
  || fail "stop must report an exited trtllm service"
ok "agent trtllm stop stops the runtime cleanly"

if PATH="${fake_bin}:${PATH}" AGENTIC_ROOT="${runtime_root}" bash "${agent_bin}" strict-prod trtllm prepare extra >/tmp/agent-c6-prepare-invalid.out 2>&1; then
  fail "agent trtllm prepare must reject extra model arguments"
fi
grep -q 'Usage: agent trtllm prepare' /tmp/agent-c6-prepare-invalid.out \
  || fail "prepare usage must mention the single-model interface"
ok "agent trtllm prepare rejects obsolete multi-model arguments"

if PATH="${fake_bin}:${PATH}" AGENTIC_ROOT="${runtime_root}" bash "${agent_bin}" strict-prod trtllm stop extra >/tmp/agent-c6-stop-invalid.out 2>&1; then
  fail "agent trtllm stop must reject extra arguments"
fi
grep -q 'Usage: agent trtllm stop' /tmp/agent-c6-stop-invalid.out \
  || fail "stop usage must mention the dedicated interface"
ok "agent trtllm stop rejects unexpected arguments"

ok "C6_trtllm_model_operator passed"
