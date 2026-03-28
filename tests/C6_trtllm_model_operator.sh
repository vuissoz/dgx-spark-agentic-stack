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
fake_docker_log="${tmp_root}/docker.log"
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
printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG}"

case "${1:-}" in
  info)
    exit 0
    ;;
  compose)
    exit 0
    ;;
  ps)
    exit 0
    ;;
  inspect)
    if [[ "${*}" == *".State.Status"* ]]; then
      printf '%s\n' "running"
    elif [[ "${*}" == *".State.Health.Status"* ]]; then
      printf '%s\n' "healthy"
    else
      printf '%s\n' "fake-trtllm-id"
    fi
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
FAKE_DOCKER_LOG="${fake_docker_log}" \
TRTLLM_NVFP4_PREPARE_SOURCE_DIR="${fixture_source}" \
bash "${agent_bin}" strict-prod trtllm prepare all \
  >/tmp/agent-c6-prepare.out 2>&1 || {
    cat /tmp/agent-c6-prepare.out >&2
    fail "agent trtllm prepare all failed"
  }

[[ -f "${runtime_root}/trtllm/models/super_fp4/model.safetensors.index.json" ]] \
  || fail "prepare all must populate the super_fp4 payload"
[[ -f "${runtime_root}/trtllm/models/cascade_30b_nvfp4/model.safetensors.index.json" ]] \
  || fail "prepare all must populate the cascade_30b_nvfp4 payload"
ok "agent trtllm prepare all populates both known local TRT payloads"

PATH="${fake_bin}:${PATH}" \
AGENTIC_ROOT="${runtime_root}" \
FAKE_DOCKER_LOG="${fake_docker_log}" \
TRTLLM_NVFP4_PREPARE_SOURCE_DIR="${fixture_source}" \
bash "${agent_bin}" strict-prod trtllm load nemotron-cascade-30b \
  >/tmp/agent-c6-load.out 2>&1 || {
    cat /tmp/agent-c6-load.out >&2
    fail "agent trtllm load nemotron-cascade-30b failed"
  }

runtime_env_file="${runtime_root}/deployments/runtime.env"
grep -q '^COMPOSE_PROFILES=trt$' "${runtime_env_file}" \
  || fail "load must persist COMPOSE_PROFILES=trt"
grep -q '^TRTLLM_ACTIVE_MODEL_KEY=nemotron-cascade-30b$' "${runtime_env_file}" \
  || fail "load must persist the active TRT model key"
grep -q '^TRTLLM_MODELS=https://huggingface.co/chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4$' "${runtime_env_file}" \
  || fail "load must persist the active TRT model alias"
grep -q '^TRTLLM_NVFP4_LOCAL_MODEL_DIR=/models/cascade_30b_nvfp4$' "${runtime_env_file}" \
  || fail "load must persist the active local model directory"
grep -q '^TRTLLM_NVFP4_HF_REPO=chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4$' "${runtime_env_file}" \
  || fail "load must persist the active TRT repo"
grep -q '^TRTLLM_NVFP4_HF_REVISION=80ee3ccfe8cb5eb019a0cde78449e8b197a0155f$' "${runtime_env_file}" \
  || fail "load must persist the pinned Cascade revision"
grep -q '^TRTLLM_NATIVE_MODEL_POLICY=strict-nvfp4-local-only$' "${runtime_env_file}" \
  || fail "load must force strict local-only TRT serving"
grep -q 'compose .* up .* trtllm' "${fake_docker_log}" \
  || fail "load must restart the trtllm compose service"
grep -q 'trtllm load actor=' "${runtime_root}/deployments/changes.log" \
  || fail "load must append an operator trace to changes.log"
ok "agent trtllm load switches the active model and restarts the service"

list_output="$(
  PATH="${fake_bin}:${PATH}" \
  AGENTIC_ROOT="${runtime_root}" \
  FAKE_DOCKER_LOG="${fake_docker_log}" \
  bash "${agent_bin}" strict-prod trtllm list
)"

printf '%s\n' "${list_output}" | grep -q $'nemotron-super-120b\t-\tyes\t' \
  || fail "list must keep the super model prepared but inactive"
printf '%s\n' "${list_output}" | grep -q $'nemotron-cascade-30b\t\*\tyes\t' \
  || fail "list must show the Cascade model as active and prepared"
ok "agent trtllm list reports prepared and active catalog entries"

PATH="${fake_bin}:${PATH}" \
AGENTIC_ROOT="${runtime_root}" \
FAKE_DOCKER_LOG="${fake_docker_log}" \
bash "${agent_bin}" strict-prod trtllm unload \
  >/tmp/agent-c6-unload.out 2>&1 || {
    cat /tmp/agent-c6-unload.out >&2
    fail "agent trtllm unload failed"
  }

grep -q 'compose .* stop trtllm' "${fake_docker_log}" \
  || fail "unload must stop the trtllm compose service"
grep -q 'trtllm unload actor=' "${runtime_root}/deployments/changes.log" \
  || fail "unload must append an operator trace to changes.log"
ok "agent trtllm unload stops the current TRT service"

ok "C6_trtllm_model_operator passed"
