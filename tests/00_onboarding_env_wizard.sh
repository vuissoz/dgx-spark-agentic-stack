#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

wizard_script="${REPO_ROOT}/deployments/bootstrap/onboarding_env.sh"
[[ -x "${wizard_script}" ]] || fail "onboarding wizard is missing or not executable: ${wizard_script}"

default_trt_model="https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8"

work_dir="${REPO_ROOT}/.runtime/test-onboarding-env-$$"
default_env_file="${work_dir}/default.env.generated.sh"
override_env_file="${work_dir}/override.env.generated.sh"
default_log="${work_dir}/default.log"
override_log="${work_dir}/override.log"
non_interactive_env_file="${work_dir}/non-interactive.env.generated.sh"
recommended_context_env_file="${work_dir}/recommended-context.env.generated.sh"
rootless_default_env_file="${work_dir}/rootless-default.env.generated.sh"
warned_default_model_env_file="${work_dir}/warned-default-model.env.generated.sh"
warned_default_model_log="${work_dir}/warned-default-model.log"
warned_openhands_model_env_file="${work_dir}/warned-openhands-model.env.generated.sh"
warned_openhands_model_log="${work_dir}/warned-openhands-model.log"
openclaw_env_file="${work_dir}/openclaw-secrets.env.generated.sh"
openclaw_log="${work_dir}/openclaw-secrets.log"
ollama_fixtures_dir="${REPO_ROOT}/tests/fixtures/ollama"

trap 'rm -rf "${work_dir}"' EXIT
mkdir -p "${work_dir}"

run_default_answers() {
  if ! printf '\n%.0s' {1..80} \
    | AGENTIC_PROFILE=strict-prod \
      AGENTIC_OLLAMA_ESTIMATOR_TAGS_FILE="${ollama_fixtures_dir}/tags.context-estimator.json" \
      AGENTIC_OLLAMA_ESTIMATOR_SHOW_FILE="${ollama_fixtures_dir}/show.nemotron-cascade-2-30b.json" \
      "${wizard_script}" --output "${default_env_file}" >"${default_log}" 2>&1; then
    cat "${default_log}" >&2 || true
    fail "wizard failed with default Enter answers"
  fi
}

run_override_answers() {
  local custom_root="${work_dir}/custom-runtime-root"
  local custom_workspace_root="${work_dir}/custom-agent-workspaces"
  local custom_claude_workspace="${work_dir}/custom-workspaces/claude"
  local custom_codex_workspace="${work_dir}/custom-workspaces/codex"
  local custom_opencode_workspace="${work_dir}/custom-workspaces/opencode"
  local custom_vibestral_workspace="${work_dir}/custom-workspaces/vibestral"
  local custom_openhands_workspace="${work_dir}/custom-workspaces/openhands"
  local custom_openclaw_workspace="${work_dir}/custom-workspaces/openclaw"
  local custom_openclaw_init_project="wizard-openclaw"
  local custom_pi_mono_workspace="${work_dir}/custom-workspaces/pi-mono"
  local custom_goose_workspace="${work_dir}/custom-workspaces/goose"
  local custom_models="${work_dir}/custom-ollama-models"
  local custom_default_model="llama3.2:1b"
  local custom_trt_models="qwen3-nvfp4-demo,nemotron-cascade-2:30b"
  local custom_compose="agentic-ci"
  local custom_network="agentic-ci-net"
  local custom_egress_network="agentic-ci-egress"

  if ! cat <<EOF | AGENTIC_PROFILE=strict-prod "${wizard_script}" --output "${override_env_file}" >"${override_log}" 2>&1
rootless-dev
${custom_root}
${custom_workspace_root}
${custom_claude_workspace}
${custom_codex_workspace}
${custom_opencode_workspace}
${custom_vibestral_workspace}
${custom_openhands_workspace}
${custom_openclaw_workspace}
${custom_openclaw_init_project}
${custom_pi_mono_workspace}
${custom_goose_workspace}
${custom_compose}
yes
${custom_network}
${custom_egress_network}
${custom_models}
${custom_default_model}

${custom_trt_models}

0.55
640m








































EOF
  then
    cat "${override_log}" >&2 || true
    fail "wizard failed with overridden answers"
  fi
}

run_openclaw_secret_answers() {
  local openclaw_root="${work_dir}/openclaw-root"

  if ! printf '\n%.0s' {1..32} \
    | AGENTIC_PROFILE=strict-prod "${wizard_script}" \
      --profile rootless-dev \
      --root "${openclaw_root}" \
      --agent-workspaces-root "${work_dir}/openclaw-workspaces" \
      --compose-project agentic-openclaw \
      --network agentic-openclaw-net \
      --egress-network agentic-openclaw-egress \
      --ollama-models-dir "${work_dir}/openclaw-models" \
      --default-model qwen3-coder:30b \
      --grafana-admin-user admin \
      --grafana-admin-password replace-with-strong-password \
      --limits-default-cpus 0.60 \
      --limits-default-mem 768m \
      --limits-core-cpus 1.20 \
      --limits-core-mem 2g \
      --limits-ollama-mem 2g \
      --limits-agents-cpus 0.70 \
      --limits-agents-mem 1g \
      --limits-ui-cpus 0.80 \
      --limits-ui-mem 1g \
      --limits-obs-cpus 0.55 \
      --limits-obs-mem 768m \
      --limits-rag-cpus 0.90 \
      --limits-rag-mem 1g \
      --limits-optional-cpus 0.40 \
      --limits-optional-mem 512m \
      --skip-ui-bootstrap \
      --skip-network-bootstrap \
      --output "${openclaw_env_file}" >"${openclaw_log}" 2>&1; then
    cat "${openclaw_log}" >&2 || true
    fail "wizard failed during openclaw secret bootstrap"
  fi
}

assert_generated_file_baseline() {
  local file_path="$1"
  [[ -s "${file_path}" ]] || fail "generated file is missing or empty: ${file_path}"
  bash -n "${file_path}" || fail "generated file is not valid bash syntax: ${file_path}"

  if grep -Eq '^export (WEBUI_ADMIN_PASSWORD|OPENAI_API_KEY|OPENROUTER_API_KEY|HUGGINGFACE_TOKEN|OPENCLAW_TOKEN|MCP_TOKEN)=' "${file_path}"; then
    fail "generated onboarding env must not contain application bootstrap secrets: ${file_path}"
  fi
}

assert_git_ignored() {
  local file_path="$1"
  local relative_path="${file_path#${REPO_ROOT}/}"
  if [[ "${relative_path}" == "${file_path}" ]]; then
    fail "file path is outside repository: ${file_path}"
  fi

  git -C "${REPO_ROOT}" check-ignore -q "${relative_path}" \
    || fail "generated onboarding file is not git-ignored: ${relative_path}"
}

run_default_answers
assert_generated_file_baseline "${default_env_file}"

grep -q "^export AGENTIC_PROFILE='strict-prod'$" "${default_env_file}" \
  || fail "default profile is not strict-prod"
grep -q "^export AGENTIC_ROOT='/srv/agentic'$" "${default_env_file}" \
  || fail "default AGENTIC_ROOT is not /srv/agentic"
grep -q "^export AGENTIC_AGENT_WORKSPACES_ROOT='/srv/agentic'$" "${default_env_file}" \
  || fail "default AGENTIC_AGENT_WORKSPACES_ROOT is not /srv/agentic"
grep -q "^export AGENTIC_CLAUDE_WORKSPACES_DIR='/srv/agentic/claude/workspaces'$" "${default_env_file}" \
  || fail "default AGENTIC_CLAUDE_WORKSPACES_DIR is not /srv/agentic/claude/workspaces"
grep -q "^export AGENTIC_CODEX_WORKSPACES_DIR='/srv/agentic/codex/workspaces'$" "${default_env_file}" \
  || fail "default AGENTIC_CODEX_WORKSPACES_DIR is not /srv/agentic/codex/workspaces"
grep -q "^export AGENTIC_OPENCODE_WORKSPACES_DIR='/srv/agentic/opencode/workspaces'$" "${default_env_file}" \
  || fail "default AGENTIC_OPENCODE_WORKSPACES_DIR is not /srv/agentic/opencode/workspaces"
grep -q "^export AGENTIC_VIBESTRAL_WORKSPACES_DIR='/srv/agentic/vibestral/workspaces'$" "${default_env_file}" \
  || fail "default AGENTIC_VIBESTRAL_WORKSPACES_DIR is not /srv/agentic/vibestral/workspaces"
grep -q "^export AGENTIC_OPENHANDS_WORKSPACES_DIR='/srv/agentic/openhands/workspaces'$" "${default_env_file}" \
  || fail "default AGENTIC_OPENHANDS_WORKSPACES_DIR is not /srv/agentic/openhands/workspaces"
grep -q "^export AGENTIC_OPENCLAW_WORKSPACES_DIR='/srv/agentic/openclaw/workspaces'$" "${default_env_file}" \
  || fail "default AGENTIC_OPENCLAW_WORKSPACES_DIR is not /srv/agentic/openclaw/workspaces"
grep -q "^export AGENTIC_OPENCLAW_INIT_PROJECT='openclaw-default'$" "${default_env_file}" \
  || fail "default AGENTIC_OPENCLAW_INIT_PROJECT is not openclaw-default"
grep -q "^export AGENTIC_PI_MONO_WORKSPACES_DIR='/srv/agentic/optional/pi-mono/workspaces'$" "${default_env_file}" \
  || fail "default AGENTIC_PI_MONO_WORKSPACES_DIR is not /srv/agentic/optional/pi-mono/workspaces"
grep -q "^export AGENTIC_GOOSE_WORKSPACES_DIR='/srv/agentic/optional/goose/workspaces'$" "${default_env_file}" \
  || fail "default AGENTIC_GOOSE_WORKSPACES_DIR is not /srv/agentic/optional/goose/workspaces"
grep -q "^export AGENTIC_OPTIONAL_MODULES=''$" "${default_env_file}" \
  || fail "default AGENTIC_OPTIONAL_MODULES must be empty"
grep -q "^export AGENTIC_COMPOSE_PROJECT='agentic'$" "${default_env_file}" \
  || fail "default AGENTIC_COMPOSE_PROJECT is not agentic"
grep -q "^export COMPOSE_PROFILES=''$" "${default_env_file}" \
  || fail "default COMPOSE_PROFILES must be empty"
grep -q "^export AGENTIC_NETWORK='agentic'$" "${default_env_file}" \
  || fail "default AGENTIC_NETWORK is not agentic"
grep -q "^export AGENTIC_EGRESS_NETWORK='agentic-egress'$" "${default_env_file}" \
  || fail "default AGENTIC_EGRESS_NETWORK is not agentic-egress"
grep -q "^export OLLAMA_MODELS_DIR='/srv/agentic/ollama/models'$" "${default_env_file}" \
  || fail "default OLLAMA_MODELS_DIR is not /srv/agentic/ollama/models"
grep -q "^export AGENTIC_DEFAULT_MODEL='nemotron-cascade-2:30b'$" "${default_env_file}" \
  || fail "default AGENTIC_DEFAULT_MODEL is not nemotron-cascade-2:30b"
grep -q "^export AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW='91239'$" "${default_env_file}" \
  || fail "default AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW is not 91239"
grep -q "^export OLLAMA_CONTEXT_LENGTH='91239'$" "${default_env_file}" \
  || fail "default OLLAMA_CONTEXT_LENGTH is not 91239"
grep -q "^export TRTLLM_MODELS='${default_trt_model}'$" "${default_env_file}" \
  || fail "default TRTLLM_MODELS must be ${default_trt_model}"
grep -q "^export TRTLLM_NATIVE_MAX_BATCH_SIZE='1'$" "${default_env_file}" \
  || fail "default TRTLLM_NATIVE_MAX_BATCH_SIZE must be 1"
grep -q "^export TRTLLM_NATIVE_MAX_NUM_TOKENS='4096'$" "${default_env_file}" \
  || fail "default TRTLLM_NATIVE_MAX_NUM_TOKENS must be 4096"
grep -q "^export TRTLLM_NATIVE_MAX_SEQ_LEN='32768'$" "${default_env_file}" \
  || fail "default TRTLLM_NATIVE_MAX_SEQ_LEN must be 32768"
grep -q "^export TRTLLM_NATIVE_ENABLE_CUDA_GRAPH='false'$" "${default_env_file}" \
  || fail "default TRTLLM_NATIVE_ENABLE_CUDA_GRAPH must be false"
grep -q "^export TRTLLM_NATIVE_CUDA_GRAPH_MAX_BATCH_SIZE='1'$" "${default_env_file}" \
  || fail "default TRTLLM_NATIVE_CUDA_GRAPH_MAX_BATCH_SIZE must be 1"
grep -q "^export TRTLLM_NATIVE_CUDA_GRAPH_ENABLE_PADDING='false'$" "${default_env_file}" \
  || fail "default TRTLLM_NATIVE_CUDA_GRAPH_ENABLE_PADDING must be false"
grep -q "^export TRTLLM_NVFP4_PREPARE_ENABLED='auto'$" "${default_env_file}" \
  || fail "default TRTLLM_NVFP4_PREPARE_ENABLED must be auto"
if grep -q '^export TRTLLM_ACTIVE_MODEL_KEY=' "${default_env_file}"; then
  fail "default onboarding env must not export TRTLLM_ACTIVE_MODEL_KEY anymore"
fi
if grep -q '^export TRTLLM_NVFP4_LOCAL_MODEL_DIR=' "${default_env_file}"; then
  fail "default onboarding env must not hardcode TRTLLM_NVFP4_LOCAL_MODEL_DIR anymore"
fi
if grep -q '^export TRTLLM_NVFP4_HF_REPO=' "${default_env_file}"; then
  fail "default onboarding env must not hardcode TRTLLM_NVFP4_HF_REPO anymore"
fi
if grep -q '^export TRTLLM_NVFP4_HF_REVISION=' "${default_env_file}"; then
  fail "default onboarding env must not hardcode TRTLLM_NVFP4_HF_REVISION anymore"
fi
grep -q "^export AGENTIC_GOOSE_CONTEXT_LIMIT='91239'$" "${default_env_file}" \
  || fail "default AGENTIC_GOOSE_CONTEXT_LIMIT must align with AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW"
grep -q "^export OLLAMA_PRELOAD_GENERATE_MODEL='nemotron-cascade-2:30b'$" "${default_env_file}" \
  || fail "default OLLAMA_PRELOAD_GENERATE_MODEL is not nemotron-cascade-2:30b"
grep -q "^export GRAFANA_ADMIN_USER='admin'$" "${default_env_file}" \
  || fail "default GRAFANA_ADMIN_USER is not admin"
grep -q "^export GRAFANA_ADMIN_PASSWORD='replace-with-strong-password'$" "${default_env_file}" \
  || fail "default GRAFANA_ADMIN_PASSWORD is not replace-with-strong-password"
grep -q "^export OPENWEBUI_ENABLE_OLLAMA_API='False'$" "${default_env_file}" \
  || fail "default OPENWEBUI_ENABLE_OLLAMA_API must be False (gate-only mode)"
grep -q "^export OPENWEBUI_OLLAMA_BASE_URL='http://ollama-gate:11435'$" "${default_env_file}" \
  || fail "default OPENWEBUI_OLLAMA_BASE_URL must be http://ollama-gate:11435"
grep -q "^export AGENTIC_AGENT_NO_NEW_PRIVILEGES='false'$" "${default_env_file}" \
  || fail "onboarding default must enable agent sudo-mode (AGENTIC_AGENT_NO_NEW_PRIVILEGES=false)"
grep -q "^export AGENTIC_LIMIT_DEFAULT_CPUS='1.00'$" "${default_env_file}" \
  || fail "default AGENTIC_LIMIT_DEFAULT_CPUS is not 1.00"
grep -q "^export AGENTIC_LIMIT_DEFAULT_MEM='1g'$" "${default_env_file}" \
  || fail "default AGENTIC_LIMIT_DEFAULT_MEM is not 1g"
grep -q "^export AGENTIC_LIMIT_CORE_CPUS='1.50'$" "${default_env_file}" \
  || fail "default AGENTIC_LIMIT_CORE_CPUS is not 1.50"
grep -q "^export AGENTIC_LIMIT_CORE_MEM='3g'$" "${default_env_file}" \
  || fail "default AGENTIC_LIMIT_CORE_MEM is not 3g"
grep -q "^export AGENTIC_LIMIT_OLLAMA_MEM='96g'$" "${default_env_file}" \
  || fail "default AGENTIC_LIMIT_OLLAMA_MEM is not 96g for strict-prod"
grep -q "^export AGENTIC_OBS_RETENTION_TIME='30d'$" "${default_env_file}" \
  || fail "default AGENTIC_OBS_RETENTION_TIME is not 30d"
grep -q "^export AGENTIC_OBS_MAX_DISK='32GB'$" "${default_env_file}" \
  || fail "default AGENTIC_OBS_MAX_DISK is not 32GB"
grep -q "^export AGENTIC_PROMETHEUS_DISK_BUDGET='8GB'$" "${default_env_file}" \
  || fail "default AGENTIC_PROMETHEUS_DISK_BUDGET is not 8GB"
grep -q "^export AGENTIC_LOKI_DISK_BUDGET='24GB'$" "${default_env_file}" \
  || fail "default AGENTIC_LOKI_DISK_BUDGET is not 24GB"
grep -q "^export PROMETHEUS_RETENTION_TIME='30d'$" "${default_env_file}" \
  || fail "default PROMETHEUS_RETENTION_TIME is not 30d"
grep -q "^export PROMETHEUS_RETENTION_SIZE='8GB'$" "${default_env_file}" \
  || fail "default PROMETHEUS_RETENTION_SIZE is not 8GB"
grep -q "^export LOKI_RETENTION_PERIOD='30d'$" "${default_env_file}" \
  || fail "default LOKI_RETENTION_PERIOD is not 30d"
grep -q "^export LOKI_MAX_QUERY_LOOKBACK='30d'$" "${default_env_file}" \
  || fail "default LOKI_MAX_QUERY_LOOKBACK is not 30d"

assert_git_ignored "${default_env_file}"
ok "wizard default Enter flow generates expected defaults"

run_override_answers
assert_generated_file_baseline "${override_env_file}"

grep -q "^export AGENTIC_PROFILE='rootless-dev'$" "${override_env_file}" \
  || fail "override profile is not rootless-dev"
grep -q "^export AGENTIC_ROOT='${work_dir}/custom-runtime-root'$" "${override_env_file}" \
  || fail "override AGENTIC_ROOT is not applied"
grep -q "^export AGENTIC_AGENT_WORKSPACES_ROOT='${work_dir}/custom-agent-workspaces'$" "${override_env_file}" \
  || fail "override AGENTIC_AGENT_WORKSPACES_ROOT is not applied"
grep -q "^export AGENTIC_CLAUDE_WORKSPACES_DIR='${work_dir}/custom-workspaces/claude'$" "${override_env_file}" \
  || fail "override AGENTIC_CLAUDE_WORKSPACES_DIR is not applied"
grep -q "^export AGENTIC_CODEX_WORKSPACES_DIR='${work_dir}/custom-workspaces/codex'$" "${override_env_file}" \
  || fail "override AGENTIC_CODEX_WORKSPACES_DIR is not applied"
grep -q "^export AGENTIC_OPENCODE_WORKSPACES_DIR='${work_dir}/custom-workspaces/opencode'$" "${override_env_file}" \
  || fail "override AGENTIC_OPENCODE_WORKSPACES_DIR is not applied"
grep -q "^export AGENTIC_VIBESTRAL_WORKSPACES_DIR='${work_dir}/custom-workspaces/vibestral'$" "${override_env_file}" \
  || fail "override AGENTIC_VIBESTRAL_WORKSPACES_DIR is not applied"
grep -q "^export AGENTIC_OPENHANDS_WORKSPACES_DIR='${work_dir}/custom-workspaces/openhands'$" "${override_env_file}" \
  || fail "override AGENTIC_OPENHANDS_WORKSPACES_DIR is not applied"
grep -q "^export AGENTIC_OPENCLAW_WORKSPACES_DIR='${work_dir}/custom-workspaces/openclaw'$" "${override_env_file}" \
  || fail "override AGENTIC_OPENCLAW_WORKSPACES_DIR is not applied"
grep -q "^export AGENTIC_OPENCLAW_INIT_PROJECT='wizard-openclaw'$" "${override_env_file}" \
  || fail "override AGENTIC_OPENCLAW_INIT_PROJECT is not applied"
grep -q "^export AGENTIC_PI_MONO_WORKSPACES_DIR='${work_dir}/custom-workspaces/pi-mono'$" "${override_env_file}" \
  || fail "override AGENTIC_PI_MONO_WORKSPACES_DIR is not applied"
grep -q "^export AGENTIC_GOOSE_WORKSPACES_DIR='${work_dir}/custom-workspaces/goose'$" "${override_env_file}" \
  || fail "override AGENTIC_GOOSE_WORKSPACES_DIR is not applied"
grep -q "^export AGENTIC_COMPOSE_PROJECT='agentic-ci'$" "${override_env_file}" \
  || fail "override AGENTIC_COMPOSE_PROJECT is not applied"
grep -q "^export COMPOSE_PROFILES='trt'$" "${override_env_file}" \
  || fail "override COMPOSE_PROFILES must enable trt when the wizard prompt is accepted"
grep -q "^export AGENTIC_NETWORK='agentic-ci-net'$" "${override_env_file}" \
  || fail "override AGENTIC_NETWORK is not applied"
grep -q "^export AGENTIC_EGRESS_NETWORK='agentic-ci-egress'$" "${override_env_file}" \
  || fail "override AGENTIC_EGRESS_NETWORK is not applied"
grep -q "^export OLLAMA_MODELS_DIR='${work_dir}/custom-ollama-models'$" "${override_env_file}" \
  || fail "override OLLAMA_MODELS_DIR is not applied"
grep -q "^export AGENTIC_DEFAULT_MODEL='llama3.2:1b'$" "${override_env_file}" \
  || fail "override AGENTIC_DEFAULT_MODEL is not applied"
grep -q "^export AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW='50909'$" "${override_env_file}" \
  || fail "override default AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW should remain 50909 when not overridden"
grep -q "^export OLLAMA_CONTEXT_LENGTH='50909'$" "${override_env_file}" \
  || fail "override default OLLAMA_CONTEXT_LENGTH should remain 50909 when not overridden"
grep -q "^export TRTLLM_MODELS='qwen3-nvfp4-demo,nemotron-cascade-2:30b'$" "${override_env_file}" \
  || fail "override TRTLLM_MODELS is not applied after enabling trt"
if grep -q '^export TRTLLM_ACTIVE_MODEL_KEY=' "${override_env_file}"; then
  fail "override flow must not export TRTLLM_ACTIVE_MODEL_KEY anymore"
fi
grep -q "^export AGENTIC_GOOSE_CONTEXT_LIMIT='50909'$" "${override_env_file}" \
  || fail "override default AGENTIC_GOOSE_CONTEXT_LIMIT should remain aligned with default context window"
grep -q "^export OLLAMA_PRELOAD_GENERATE_MODEL='llama3.2:1b'$" "${override_env_file}" \
  || fail "override OLLAMA_PRELOAD_GENERATE_MODEL is not applied"
grep -q "^export GRAFANA_ADMIN_USER='admin'$" "${override_env_file}" \
  || fail "override flow default GRAFANA_ADMIN_USER must be admin unless explicitly overridden"
grep -q "^export GRAFANA_ADMIN_PASSWORD='replace-with-strong-password'$" "${override_env_file}" \
  || fail "override flow default GRAFANA_ADMIN_PASSWORD must be replace-with-strong-password unless explicitly overridden"
grep -q "^export OPENWEBUI_ENABLE_OLLAMA_API='False'$" "${override_env_file}" \
  || fail "override flow default OPENWEBUI_ENABLE_OLLAMA_API must remain False unless explicitly enabled"
grep -q "^export OPENWEBUI_OLLAMA_BASE_URL='http://ollama-gate:11435'$" "${override_env_file}" \
  || fail "override flow default OPENWEBUI_OLLAMA_BASE_URL must remain http://ollama-gate:11435"
grep -q "^export AGENTIC_AGENT_NO_NEW_PRIVILEGES='false'$" "${override_env_file}" \
  || fail "override flow must keep onboarding sudo-mode default enabled"
grep -q "^export AGENTIC_LIMIT_DEFAULT_CPUS='0.55'$" "${override_env_file}" \
  || fail "override AGENTIC_LIMIT_DEFAULT_CPUS is not applied"
grep -q "^export AGENTIC_LIMIT_DEFAULT_MEM='640m'$" "${override_env_file}" \
  || fail "override AGENTIC_LIMIT_DEFAULT_MEM is not applied"
grep -q "^export AGENTIC_LIMIT_OBS_CPUS='0.50'$" "${override_env_file}" \
  || fail "rootless default AGENTIC_LIMIT_OBS_CPUS is not applied"
grep -q "^export AGENTIC_LIMIT_OBS_MEM='512m'$" "${override_env_file}" \
  || fail "rootless default AGENTIC_LIMIT_OBS_MEM is not applied"
grep -q "^export AGENTIC_LIMIT_OLLAMA_MEM='64g'$" "${override_env_file}" \
  || fail "override flow default AGENTIC_LIMIT_OLLAMA_MEM is not 64g for rootless-dev"
grep -q "^export AGENTIC_OBS_RETENTION_TIME='7d'$" "${override_env_file}" \
  || fail "rootless default AGENTIC_OBS_RETENTION_TIME is not applied"
grep -q "^export AGENTIC_OBS_MAX_DISK='8GB'$" "${override_env_file}" \
  || fail "rootless default AGENTIC_OBS_MAX_DISK is not applied"
grep -q "^export AGENTIC_PROMETHEUS_DISK_BUDGET='2GB'$" "${override_env_file}" \
  || fail "rootless default AGENTIC_PROMETHEUS_DISK_BUDGET is not applied"
grep -q "^export AGENTIC_LOKI_DISK_BUDGET='6GB'$" "${override_env_file}" \
  || fail "rootless default AGENTIC_LOKI_DISK_BUDGET is not applied"
grep -q "^export PROMETHEUS_RETENTION_TIME='7d'$" "${override_env_file}" \
  || fail "rootless default PROMETHEUS_RETENTION_TIME is not applied"
grep -q "^export PROMETHEUS_RETENTION_SIZE='2GB'$" "${override_env_file}" \
  || fail "rootless default PROMETHEUS_RETENTION_SIZE is not applied"
grep -q "^export LOKI_RETENTION_PERIOD='7d'$" "${override_env_file}" \
  || fail "rootless default LOKI_RETENTION_PERIOD is not applied"
grep -q "^export LOKI_MAX_QUERY_LOOKBACK='7d'$" "${override_env_file}" \
  || fail "rootless default LOKI_MAX_QUERY_LOOKBACK is not applied"

assert_git_ignored "${override_env_file}"
ok "wizard override flow writes custom values"

if ! AGENTIC_PROFILE=strict-prod "${wizard_script}" \
  --non-interactive \
  --profile rootless-dev \
  --root "${work_dir}/rootless-default-root" \
  --skip-ui-bootstrap \
  --skip-network-bootstrap \
  --skip-secret-bootstrap \
  --output "${rootless_default_env_file}" >/dev/null 2>&1; then
  fail "wizard rootless default mode failed"
fi
assert_generated_file_baseline "${rootless_default_env_file}"
grep -q "^export OLLAMA_MODELS_DIR='${HOME}/wkdir/open-webui/ollama_data/models'$" "${rootless_default_env_file}" \
  || fail "rootless default OLLAMA_MODELS_DIR is not ${HOME}/wkdir/open-webui/ollama_data/models"
grep -q "^export COMPOSE_PROFILES=''$" "${rootless_default_env_file}" \
  || fail "rootless default COMPOSE_PROFILES must stay empty"
grep -q "^export AGENTIC_AGENT_WORKSPACES_ROOT='${work_dir}/rootless-default-root/agent-workspaces'$" "${rootless_default_env_file}" \
  || fail "rootless default AGENTIC_AGENT_WORKSPACES_ROOT is not <root>/agent-workspaces"
grep -q "^export AGENTIC_CLAUDE_WORKSPACES_DIR='${work_dir}/rootless-default-root/agent-workspaces/claude/workspaces'$" "${rootless_default_env_file}" \
  || fail "rootless default AGENTIC_CLAUDE_WORKSPACES_DIR is not <root>/agent-workspaces/claude/workspaces"
grep -q "^export AGENTIC_CODEX_WORKSPACES_DIR='${work_dir}/rootless-default-root/agent-workspaces/codex/workspaces'$" "${rootless_default_env_file}" \
  || fail "rootless default AGENTIC_CODEX_WORKSPACES_DIR is not <root>/agent-workspaces/codex/workspaces"
grep -q "^export AGENTIC_OPENCODE_WORKSPACES_DIR='${work_dir}/rootless-default-root/agent-workspaces/opencode/workspaces'$" "${rootless_default_env_file}" \
  || fail "rootless default AGENTIC_OPENCODE_WORKSPACES_DIR is not <root>/agent-workspaces/opencode/workspaces"
grep -q "^export AGENTIC_VIBESTRAL_WORKSPACES_DIR='${work_dir}/rootless-default-root/agent-workspaces/vibestral/workspaces'$" "${rootless_default_env_file}" \
  || fail "rootless default AGENTIC_VIBESTRAL_WORKSPACES_DIR is not <root>/agent-workspaces/vibestral/workspaces"
grep -q "^export AGENTIC_OPENHANDS_WORKSPACES_DIR='${work_dir}/rootless-default-root/openhands/workspaces'$" "${rootless_default_env_file}" \
  || fail "rootless default AGENTIC_OPENHANDS_WORKSPACES_DIR is not <root>/openhands/workspaces"
grep -q "^export AGENTIC_OPENCLAW_WORKSPACES_DIR='${work_dir}/rootless-default-root/openclaw/workspaces'$" "${rootless_default_env_file}" \
  || fail "rootless default AGENTIC_OPENCLAW_WORKSPACES_DIR is not <root>/openclaw/workspaces"
grep -q "^export AGENTIC_OPENCLAW_INIT_PROJECT='openclaw-default'$" "${rootless_default_env_file}" \
  || fail "rootless default AGENTIC_OPENCLAW_INIT_PROJECT is not openclaw-default"
grep -q "^export AGENTIC_PI_MONO_WORKSPACES_DIR='${work_dir}/rootless-default-root/optional/pi-mono/workspaces'$" "${rootless_default_env_file}" \
  || fail "rootless default AGENTIC_PI_MONO_WORKSPACES_DIR is not <root>/optional/pi-mono/workspaces"
grep -q "^export AGENTIC_GOOSE_WORKSPACES_DIR='${work_dir}/rootless-default-root/optional/goose/workspaces'$" "${rootless_default_env_file}" \
  || fail "rootless default AGENTIC_GOOSE_WORKSPACES_DIR is not <root>/optional/goose/workspaces"
grep -q "^export AGENTIC_DEFAULT_MODEL='nemotron-cascade-2:30b'$" "${rootless_default_env_file}" \
  || fail "rootless default AGENTIC_DEFAULT_MODEL is not nemotron-cascade-2:30b"
grep -q "^export AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW='50909'$" "${rootless_default_env_file}" \
  || fail "rootless default AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW is not 50909"
grep -q "^export OLLAMA_CONTEXT_LENGTH='50909'$" "${rootless_default_env_file}" \
  || fail "rootless default OLLAMA_CONTEXT_LENGTH is not 50909"
grep -q "^export TRTLLM_MODELS='${default_trt_model}'$" "${rootless_default_env_file}" \
  || fail "rootless default TRTLLM_MODELS must stay ${default_trt_model}"
if grep -q '^export TRTLLM_ACTIVE_MODEL_KEY=' "${rootless_default_env_file}"; then
  fail "rootless default onboarding env must not export TRTLLM_ACTIVE_MODEL_KEY anymore"
fi
grep -q "^export AGENTIC_GOOSE_CONTEXT_LIMIT='50909'$" "${rootless_default_env_file}" \
  || fail "rootless default AGENTIC_GOOSE_CONTEXT_LIMIT must align with AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW"
grep -q "^export OPENWEBUI_ENABLE_OLLAMA_API='False'$" "${rootless_default_env_file}" \
  || fail "rootless default OPENWEBUI_ENABLE_OLLAMA_API must be False"
grep -q "^export OPENWEBUI_OLLAMA_BASE_URL='http://ollama-gate:11435'$" "${rootless_default_env_file}" \
  || fail "rootless default OPENWEBUI_OLLAMA_BASE_URL must be http://ollama-gate:11435"
grep -q "^export AGENTIC_OBS_RETENTION_TIME='7d'$" "${rootless_default_env_file}" \
  || fail "rootless default AGENTIC_OBS_RETENTION_TIME must be 7d"
grep -q "^export AGENTIC_OBS_MAX_DISK='8GB'$" "${rootless_default_env_file}" \
  || fail "rootless default AGENTIC_OBS_MAX_DISK must be 8GB"
ok "wizard rootless default models path is open-webui/ollama_data/models"

if ! AGENTIC_PROFILE=strict-prod "${wizard_script}" \
  --non-interactive \
  --profile rootless-dev \
  --root "${work_dir}/warned-default-model-root" \
  --skip-ui-bootstrap \
  --skip-network-bootstrap \
  --skip-secret-bootstrap \
  --default-model qwen3.5:35b \
  --output "${warned_default_model_env_file}" >"${warned_default_model_log}" 2>&1; then
  cat "${warned_default_model_log}" >&2 || true
  fail "wizard must allow qwen3.5:35b as AGENTIC_DEFAULT_MODEL while emitting a regression warning"
fi
grep -q "^export AGENTIC_DEFAULT_MODEL='qwen3.5:35b'$" "${warned_default_model_env_file}" \
  || fail "wizard warned default model flow must still export qwen3.5:35b"
grep -q "AGENTIC_DEFAULT_MODEL='qwen3.5:35b' has a known stack tool-calling regression" "${warned_default_model_log}" \
  || fail "wizard warned default model output must explain the stack regression"
grep -q "qwen3-coder:30b" "${warned_default_model_log}" \
  || fail "wizard warned default model output must suggest qwen3-coder:30b"
ok "wizard allows qwen3.5:35b as default model with an explicit regression warning"

if ! AGENTIC_PROFILE=strict-prod "${wizard_script}" \
  --non-interactive \
  --profile rootless-dev \
  --root "${work_dir}/warned-openhands-model-root" \
  --skip-network-bootstrap \
  --skip-secret-bootstrap \
  --default-model qwen3-coder:30b \
  --openhands-llm-model openai/qwen3.5:35b \
  --output "${warned_openhands_model_env_file}" >"${warned_openhands_model_log}" 2>&1; then
  cat "${warned_openhands_model_log}" >&2 || true
  fail "wizard must allow qwen3.5:35b as OpenHands LLM_MODEL while emitting a regression warning"
fi
grep -q "LLM_MODEL='openai/qwen3.5:35b' has a known stack tool-calling regression" "${warned_openhands_model_log}" \
  || fail "wizard warned OpenHands model output must explain the stack regression"
grep -q "pseudo tool tags" "${warned_openhands_model_log}" \
  || fail "wizard warned OpenHands model output must mention pseudo tool tags"
grep -q "^export AGENTIC_DEFAULT_MODEL='qwen3-coder:30b'$" "${warned_openhands_model_env_file}" \
  || fail "wizard warned OpenHands model flow must keep the selected default model"
warned_openhands_env_path="${work_dir}/warned-openhands-model-root/openhands/config/openhands.env"
grep -q "^LLM_MODEL=openai/qwen3.5:35b$" "${warned_openhands_env_path}" \
  || fail "wizard warned OpenHands model flow must still write openai/qwen3.5:35b into openhands.env"
ok "wizard allows qwen3.5:35b as OpenHands model with an explicit regression warning"

run_openclaw_secret_answers
assert_generated_file_baseline "${openclaw_env_file}"
openclaw_token_file="${work_dir}/openclaw-root/secrets/runtime/openclaw.token"
openclaw_webhook_secret_file="${work_dir}/openclaw-root/secrets/runtime/openclaw.webhook_secret"
openclaw_profile_file="${work_dir}/openclaw-root/openclaw/config/integration-profile.current.json"
[[ -s "${openclaw_token_file}" ]] \
  || fail "openclaw token file must be generated during core OpenClaw bootstrap"
[[ -s "${openclaw_webhook_secret_file}" ]] \
  || fail "openclaw webhook secret file must be generated during core OpenClaw bootstrap"
[[ -s "${openclaw_profile_file}" ]] \
  || fail "openclaw integration profile file must be generated during core OpenClaw bootstrap"
grep -q "ERROR: input aborted" "${openclaw_log}" \
  && fail "openclaw secret bootstrap should not abort input in interactive mode"
ok "wizard openclaw secret bootstrap works with interactive stdin"

if ! AGENTIC_PROFILE=strict-prod "${wizard_script}" \
  --non-interactive \
  --profile rootless-dev \
  --root "${work_dir}/ni-root" \
  --agent-workspaces-root "${work_dir}/ni-agent-workspaces" \
  --claude-workspaces-dir "${work_dir}/ni-workspaces/claude" \
  --codex-workspaces-dir "${work_dir}/ni-workspaces/codex" \
  --opencode-workspaces-dir "${work_dir}/ni-workspaces/opencode" \
  --vibestral-workspaces-dir "${work_dir}/ni-workspaces/vibestral" \
  --openhands-workspaces-dir "${work_dir}/ni-workspaces/openhands" \
  --openclaw-workspaces-dir "${work_dir}/ni-workspaces/openclaw" \
  --pi-mono-workspaces-dir "${work_dir}/ni-workspaces/pi-mono" \
  --goose-workspaces-dir "${work_dir}/ni-workspaces/goose" \
  --compose-project agentic-ni \
  --compose-profiles trt \
  --network agentic-ni-net \
  --egress-network agentic-ni-egress \
  --ollama-models-dir "${work_dir}/ni-models" \
  --default-model tinyllama:latest \
  --default-model-context-window 32768 \
  --trtllm-models qwen3-nvfp4-demo,tinyllama:latest \
  --grafana-admin-user grafana-admin \
  --grafana-admin-password grafana-strong-password \
  --limits-default-cpus 0.60 \
  --limits-default-mem 768m \
  --limits-core-cpus 1.20 \
  --limits-core-mem 2g \
  --limits-ollama-mem 6g \
  --limits-agents-cpus 0.70 \
  --limits-agents-mem 1g \
  --limits-ui-cpus 0.80 \
  --limits-ui-mem 1g \
  --limits-obs-cpus 0.55 \
  --limits-obs-mem 768m \
  --obs-retention-time 14d \
  --obs-max-disk 12GB \
  --limits-rag-cpus 0.90 \
  --limits-rag-mem 1g \
  --limits-optional-cpus 0.40 \
  --limits-optional-mem 512m \
  --output "${non_interactive_env_file}" >/dev/null 2>&1; then
  fail "wizard non-interactive flag mode failed"
fi
assert_generated_file_baseline "${non_interactive_env_file}"
grep -q "^export AGENTIC_LIMIT_DEFAULT_CPUS='0.60'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_LIMIT_DEFAULT_CPUS is not applied"
grep -q "^export AGENTIC_DEFAULT_MODEL='tinyllama:latest'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_DEFAULT_MODEL is not applied"
grep -q "^export AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW='32768'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW is not applied"
grep -q "^export OLLAMA_CONTEXT_LENGTH='32768'$" "${non_interactive_env_file}" \
  || fail "non-interactive OLLAMA_CONTEXT_LENGTH is not applied"
grep -q "^export COMPOSE_PROFILES='trt'$" "${non_interactive_env_file}" \
  || fail "non-interactive COMPOSE_PROFILES must be applied"
grep -q "^export TRTLLM_MODELS='qwen3-nvfp4-demo,tinyllama:latest'$" "${non_interactive_env_file}" \
  || fail "non-interactive TRTLLM_MODELS must be applied"
grep -q "^export TRTLLM_NVFP4_PREPARE_ENABLED='auto'$" "${non_interactive_env_file}" \
  || fail "non-interactive flow must still export TRTLLM_NVFP4_PREPARE_ENABLED"
if grep -q '^export TRTLLM_ACTIVE_MODEL_KEY=' "${non_interactive_env_file}"; then
  fail "non-interactive flow must not export TRTLLM_ACTIVE_MODEL_KEY anymore"
fi
grep -q "^export AGENTIC_GOOSE_CONTEXT_LIMIT='32768'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_GOOSE_CONTEXT_LIMIT must align with AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW"
grep -q "^export AGENTIC_AGENT_WORKSPACES_ROOT='${work_dir}/ni-agent-workspaces'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_AGENT_WORKSPACES_ROOT is not applied"
grep -q "^export AGENTIC_CLAUDE_WORKSPACES_DIR='${work_dir}/ni-workspaces/claude'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_CLAUDE_WORKSPACES_DIR is not applied"
grep -q "^export AGENTIC_CODEX_WORKSPACES_DIR='${work_dir}/ni-workspaces/codex'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_CODEX_WORKSPACES_DIR is not applied"
grep -q "^export AGENTIC_OPENCODE_WORKSPACES_DIR='${work_dir}/ni-workspaces/opencode'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_OPENCODE_WORKSPACES_DIR is not applied"
grep -q "^export AGENTIC_VIBESTRAL_WORKSPACES_DIR='${work_dir}/ni-workspaces/vibestral'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_VIBESTRAL_WORKSPACES_DIR is not applied"
grep -q "^export AGENTIC_OPENHANDS_WORKSPACES_DIR='${work_dir}/ni-workspaces/openhands'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_OPENHANDS_WORKSPACES_DIR is not applied"
grep -q "^export AGENTIC_OPENCLAW_WORKSPACES_DIR='${work_dir}/ni-workspaces/openclaw'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_OPENCLAW_WORKSPACES_DIR is not applied"
grep -q "^export AGENTIC_PI_MONO_WORKSPACES_DIR='${work_dir}/ni-workspaces/pi-mono'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_PI_MONO_WORKSPACES_DIR is not applied"
grep -q "^export AGENTIC_GOOSE_WORKSPACES_DIR='${work_dir}/ni-workspaces/goose'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_GOOSE_WORKSPACES_DIR is not applied"
grep -q "^export GRAFANA_ADMIN_USER='grafana-admin'$" "${non_interactive_env_file}" \
  || fail "non-interactive GRAFANA_ADMIN_USER is not applied"
grep -q "^export GRAFANA_ADMIN_PASSWORD='grafana-strong-password'$" "${non_interactive_env_file}" \
  || fail "non-interactive GRAFANA_ADMIN_PASSWORD is not applied"
grep -q "^export AGENTIC_OBS_RETENTION_TIME='14d'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_OBS_RETENTION_TIME is not applied"
grep -q "^export AGENTIC_OBS_MAX_DISK='12GB'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_OBS_MAX_DISK is not applied"
grep -q "^export AGENTIC_PROMETHEUS_DISK_BUDGET='3GB'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_PROMETHEUS_DISK_BUDGET is not derived correctly"
grep -q "^export AGENTIC_LOKI_DISK_BUDGET='9GB'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_LOKI_DISK_BUDGET is not derived correctly"
grep -q "^export PROMETHEUS_RETENTION_TIME='14d'$" "${non_interactive_env_file}" \
  || fail "non-interactive PROMETHEUS_RETENTION_TIME is not applied"
grep -q "^export PROMETHEUS_RETENTION_SIZE='3GB'$" "${non_interactive_env_file}" \
  || fail "non-interactive PROMETHEUS_RETENTION_SIZE is not derived correctly"
grep -q "^export LOKI_RETENTION_PERIOD='14d'$" "${non_interactive_env_file}" \
  || fail "non-interactive LOKI_RETENTION_PERIOD is not applied"
grep -q "^export LOKI_MAX_QUERY_LOOKBACK='14d'$" "${non_interactive_env_file}" \
  || fail "non-interactive LOKI_MAX_QUERY_LOOKBACK is not applied"
grep -q "^export OPENWEBUI_ENABLE_OLLAMA_API='False'$" "${non_interactive_env_file}" \
  || fail "non-interactive default OPENWEBUI_ENABLE_OLLAMA_API must be False"
grep -q "^export OPENWEBUI_OLLAMA_BASE_URL='http://ollama-gate:11435'$" "${non_interactive_env_file}" \
  || fail "non-interactive default OPENWEBUI_OLLAMA_BASE_URL must be http://ollama-gate:11435"
grep -q "^export AGENTIC_AGENT_NO_NEW_PRIVILEGES='false'$" "${non_interactive_env_file}" \
  || fail "non-interactive flow must keep onboarding sudo-mode default enabled"
grep -q "^export AGENTIC_LIMIT_OPTIONAL_MEM='512m'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_LIMIT_OPTIONAL_MEM is not applied"
grep -q "^export AGENTIC_LIMIT_OLLAMA_MEM='6g'$" "${non_interactive_env_file}" \
  || fail "non-interactive AGENTIC_LIMIT_OLLAMA_MEM is not applied"
non_interactive_allowlist_file="${work_dir}/ni-root/proxy/allowlist.txt"
[[ -s "${non_interactive_allowlist_file}" ]] \
  || fail "non-interactive flow did not write default allowlist file"
grep -q '^registry.ollama.ai$' "${non_interactive_allowlist_file}" \
  || fail "default allowlist must include registry.ollama.ai"
assert_git_ignored "${non_interactive_env_file}"
ok "wizard non-interactive flags mode works"

if ! AGENTIC_PROFILE=strict-prod \
  AGENTIC_OLLAMA_ESTIMATOR_TAGS_FILE="${ollama_fixtures_dir}/tags.context-estimator.json" \
  AGENTIC_OLLAMA_ESTIMATOR_SHOW_FILE="${ollama_fixtures_dir}/show.nemotron-cascade-2-30b.json" \
  "${wizard_script}" \
  --non-interactive \
  --profile rootless-dev \
  --root "${work_dir}/recommended-root" \
  --skip-ui-bootstrap \
  --skip-network-bootstrap \
  --skip-secret-bootstrap \
  --default-model nemotron-cascade-2:30b \
  --limits-ollama-mem 110g \
  --output "${recommended_context_env_file}" >/dev/null 2>&1; then
  fail "wizard recommended-context mode failed"
fi
assert_generated_file_baseline "${recommended_context_env_file}"
grep -q "^export AGENTIC_DEFAULT_MODEL='nemotron-cascade-2:30b'$" "${recommended_context_env_file}" \
  || fail "recommended-context flow must export the selected model"
grep -q "^export AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW='108883'$" "${recommended_context_env_file}" \
  || fail "recommended-context flow must auto-select the max fitting context"
grep -q "^export OLLAMA_CONTEXT_LENGTH='108883'$" "${recommended_context_env_file}" \
  || fail "recommended-context flow must propagate OLLAMA_CONTEXT_LENGTH"
grep -q "^export AGENTIC_GOOSE_CONTEXT_LIMIT='108883'$" "${recommended_context_env_file}" \
  || fail "recommended-context flow must align AGENTIC_GOOSE_CONTEXT_LIMIT with the recommended context"
ok "wizard auto-selects the estimated max fitting context when metadata is available"

ok "00_onboarding_env_wizard passed"
