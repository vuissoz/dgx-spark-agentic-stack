#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

wizard_script="${REPO_ROOT}/deployments/bootstrap/onboarding_env.sh"
[[ -x "${wizard_script}" ]] || fail "onboarding wizard is missing or not executable: ${wizard_script}"

work_dir="${REPO_ROOT}/.runtime/test-onboarding-full-setup-$$"
root_dir="${work_dir}/runtime-root"
env_file="${work_dir}/full.env.generated.sh"
log_file="${work_dir}/full.log"
strict_env_file="${work_dir}/strict.env.generated.sh"
strict_log_file="${work_dir}/strict.log"

openwebui_email="admin@example.local"
openwebui_password="S3cure-Pass-123"
openwebui_secret="webui-secret-xyz"
default_model="qwen3-coder:30b"
default_context_window="262144"
openhands_model="${default_model}"
grafana_admin_user="grafana-admin"
grafana_admin_password="grafana-strong-password"
openhands_api_key="openhands-api-key"
openai_key="openai-api-key"
openrouter_key="openrouter-api-key"
huggingface_token="hf_token_read_abc123"
openclaw_token="openclaw-token"
openclaw_webhook="openclaw-webhook"
mcp_token="mcp-token"

trap 'rm -rf "${work_dir}"' EXIT
mkdir -p "${work_dir}"

if ! AGENTIC_PROFILE=strict-prod "${wizard_script}" \
  --non-interactive \
  --profile rootless-dev \
  --root "${root_dir}" \
  --compose-project agentic-onboard-full \
  --network agentic-onboard-full-net \
  --egress-network agentic-onboard-full-egress \
  --ollama-models-dir "${work_dir}/models" \
  --default-model "${default_model}" \
  --default-model-context-window "${default_context_window}" \
  --grafana-admin-user "${grafana_admin_user}" \
  --grafana-admin-password "${grafana_admin_password}" \
  --openwebui-admin-email "${openwebui_email}" \
  --openwebui-admin-password "${openwebui_password}" \
  --openwebui-secret-key "${openwebui_secret}" \
  --openwebui-allow-model-pull true \
  --openhands-llm-model "${openhands_model}" \
  --openhands-llm-api-key "${openhands_api_key}" \
  --allowlist-domains 'example.com,api.openai.com,10.1.0.0/24' \
  --openai-api-key "${openai_key}" \
  --openrouter-api-key "${openrouter_key}" \
  --huggingface-token "${huggingface_token}" \
  --optional-modules 'openclaw,mcp' \
  --openclaw-token "${openclaw_token}" \
  --openclaw-webhook-secret "${openclaw_webhook}" \
  --mcp-token "${mcp_token}" \
  --output "${env_file}" >"${log_file}" 2>&1; then
  cat "${log_file}" >&2 || true
  fail "full setup wizard run failed"
fi

[[ -s "${env_file}" ]] || fail "full setup env output is missing: ${env_file}"
bash -n "${env_file}" || fail "full setup env output is invalid bash: ${env_file}"
grep -q "^export AGENTIC_AGENT_NO_NEW_PRIVILEGES='false'$" "${env_file}" \
  || fail "full setup onboarding env must enable agent sudo-mode by default"
grep -q "^export AGENTIC_DEFAULT_MODEL='${default_model}'$" "${env_file}" \
  || fail "full setup onboarding env must export AGENTIC_DEFAULT_MODEL"
grep -q "^export AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW='${default_context_window}'$" "${env_file}" \
  || fail "full setup onboarding env must export AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW"
grep -q "^export OLLAMA_CONTEXT_LENGTH='${default_context_window}'$" "${env_file}" \
  || fail "full setup onboarding env must export OLLAMA_CONTEXT_LENGTH"
grep -q "^export OLLAMA_PRELOAD_GENERATE_MODEL='${default_model}'$" "${env_file}" \
  || fail "full setup onboarding env must export OLLAMA_PRELOAD_GENERATE_MODEL"
grep -q "^export AGENTIC_AGENT_WORKSPACES_ROOT='${root_dir}/agent-workspaces'$" "${env_file}" \
  || fail "full setup onboarding env must export rootless default AGENTIC_AGENT_WORKSPACES_ROOT"
grep -q "^export AGENTIC_CLAUDE_WORKSPACES_DIR='${root_dir}/agent-workspaces/claude/workspaces'$" "${env_file}" \
  || fail "full setup onboarding env must export AGENTIC_CLAUDE_WORKSPACES_DIR"
grep -q "^export AGENTIC_CODEX_WORKSPACES_DIR='${root_dir}/agent-workspaces/codex/workspaces'$" "${env_file}" \
  || fail "full setup onboarding env must export AGENTIC_CODEX_WORKSPACES_DIR"
grep -q "^export AGENTIC_OPENCODE_WORKSPACES_DIR='${root_dir}/agent-workspaces/opencode/workspaces'$" "${env_file}" \
  || fail "full setup onboarding env must export AGENTIC_OPENCODE_WORKSPACES_DIR"
grep -q "^export AGENTIC_VIBESTRAL_WORKSPACES_DIR='${root_dir}/agent-workspaces/vibestral/workspaces'$" "${env_file}" \
  || fail "full setup onboarding env must export AGENTIC_VIBESTRAL_WORKSPACES_DIR"
grep -q "^export AGENTIC_OPENHANDS_WORKSPACES_DIR='${root_dir}/openhands/workspaces'$" "${env_file}" \
  || fail "full setup onboarding env must export AGENTIC_OPENHANDS_WORKSPACES_DIR"
grep -q "^export GRAFANA_ADMIN_USER='${grafana_admin_user}'$" "${env_file}" \
  || fail "full setup onboarding env must export GRAFANA_ADMIN_USER"
grep -q "^export GRAFANA_ADMIN_PASSWORD='${grafana_admin_password}'$" "${env_file}" \
  || fail "full setup onboarding env must export GRAFANA_ADMIN_PASSWORD"
grep -q "^export AGENTIC_OLLAMA_GATE_BASE_URL='http://ollama-gate:11435'$" "${env_file}" \
  || fail "full setup onboarding env must export AGENTIC_OLLAMA_GATE_BASE_URL"
grep -q "^export ANTHROPIC_BASE_URL='http://ollama-gate:11435'$" "${env_file}" \
  || fail "full setup onboarding env must export ANTHROPIC_BASE_URL"
grep -q "^export ANTHROPIC_AUTH_TOKEN='local-ollama'$" "${env_file}" \
  || fail "full setup onboarding env must export ANTHROPIC_AUTH_TOKEN placeholder"
grep -q "^export ANTHROPIC_API_KEY='local-ollama'$" "${env_file}" \
  || fail "full setup onboarding env must export ANTHROPIC_API_KEY placeholder"
grep -q "^export ANTHROPIC_MODEL='${default_model}'$" "${env_file}" \
  || fail "full setup onboarding env must export ANTHROPIC_MODEL"
grep -q "^export AGENTIC_LIMIT_OLLAMA_MEM='64g'$" "${env_file}" \
  || fail "full setup onboarding env must export default rootless AGENTIC_LIMIT_OLLAMA_MEM"
grep -q "^export OPENWEBUI_ENABLE_OLLAMA_API='True'$" "${env_file}" \
  || fail "full setup onboarding env must export OPENWEBUI_ENABLE_OLLAMA_API"
grep -q "^export OPENWEBUI_OLLAMA_BASE_URL='http://ollama:11434'$" "${env_file}" \
  || fail "full setup onboarding env must export OPENWEBUI_OLLAMA_BASE_URL direct opt-in"

openwebui_env="${root_dir}/openwebui/config/openwebui.env"
openhands_env="${root_dir}/openhands/config/openhands.env"
openhands_settings="${root_dir}/openhands/state/settings.json"
allowlist_file="${root_dir}/proxy/allowlist.txt"
openai_secret_file="${root_dir}/secrets/runtime/openai.api_key"
openrouter_secret_file="${root_dir}/secrets/runtime/openrouter.api_key"
huggingface_secret_file="${root_dir}/secrets/runtime/huggingface.token"
openclaw_token_file="${root_dir}/secrets/runtime/openclaw.token"
openclaw_webhook_file="${root_dir}/secrets/runtime/openclaw.webhook_secret"
mcp_token_file="${root_dir}/secrets/runtime/mcp.token"
openclaw_request_file="${root_dir}/deployments/optional/openclaw.request"
mcp_request_file="${root_dir}/deployments/optional/mcp.request"
openclaw_profile_file="${root_dir}/optional/openclaw/config/integration-profile.current.json"

[[ -s "${openwebui_env}" ]] || fail "openwebui env file missing: ${openwebui_env}"
[[ -s "${openhands_env}" ]] || fail "openhands env file missing: ${openhands_env}"
[[ -s "${openhands_settings}" ]] || fail "openhands settings file missing: ${openhands_settings}"
[[ -s "${allowlist_file}" ]] || fail "allowlist file missing: ${allowlist_file}"
openhands_settings_perm="$(stat -c '%a' "${openhands_settings}")"
[[ "${openhands_settings_perm}" == "660" ]] \
  || fail "openhands settings file permissions must be 660: ${openhands_settings} (got ${openhands_settings_perm})"

for secret_file in \
  "${openai_secret_file}" \
  "${openrouter_secret_file}" \
  "${huggingface_secret_file}" \
  "${openclaw_token_file}" \
  "${openclaw_webhook_file}" \
  "${mcp_token_file}"; do
  [[ -s "${secret_file}" ]] || fail "secret file missing: ${secret_file}"
  perm="$(stat -c '%a' "${secret_file}")"
  [[ "${perm}" == "600" ]] || fail "secret file permissions must be 600: ${secret_file} (got ${perm})"
done

for request_file in \
  "${openclaw_request_file}" \
  "${mcp_request_file}"; do
  [[ -s "${request_file}" ]] || fail "optional request file missing: ${request_file}"
  request_perm="$(stat -c '%a' "${request_file}")"
  [[ "${request_perm}" == "640" ]] || fail "optional request file permissions must be 640: ${request_file} (got ${request_perm})"
  grep -Eq '^need=[^[:space:]].+$' "${request_file}" \
    || fail "optional request need= must be non-empty: ${request_file}"
  grep -Eq '^success=[^[:space:]].+$' "${request_file}" \
    || fail "optional request success= must be non-empty: ${request_file}"
done

[[ -s "${openclaw_profile_file}" ]] || fail "openclaw integration profile file missing: ${openclaw_profile_file}"
openclaw_profile_perm="$(stat -c '%a' "${openclaw_profile_file}")"
[[ "${openclaw_profile_perm}" == "644" ]] \
  || fail "openclaw integration profile file permissions must be 644: ${openclaw_profile_file} (got ${openclaw_profile_perm})"

grep -q "^WEBUI_ADMIN_EMAIL=${openwebui_email}$" "${openwebui_env}" \
  || fail "WEBUI_ADMIN_EMAIL was not written"
grep -q "^WEBUI_ADMIN_PASSWORD=${openwebui_password}$" "${openwebui_env}" \
  || fail "WEBUI_ADMIN_PASSWORD was not written"
grep -q "^WEBUI_SECRET_KEY=${openwebui_secret}$" "${openwebui_env}" \
  || fail "WEBUI_SECRET_KEY was not written"
grep -q '^OPENWEBUI_ENABLE_OLLAMA_API=True$' "${openwebui_env}" \
  || fail "OPENWEBUI_ENABLE_OLLAMA_API=True was not written"
grep -q '^ENABLE_OLLAMA_API=True$' "${openwebui_env}" \
  || fail "ENABLE_OLLAMA_API=True was not written"
grep -q '^OLLAMA_BASE_URL=http://ollama:11434$' "${openwebui_env}" \
  || fail "OLLAMA_BASE_URL=http://ollama:11434 was not written for direct opt-in"
grep -q '^OPENWEBUI_OLLAMA_BASE_URL=http://ollama:11434$' "${openwebui_env}" \
  || fail "OPENWEBUI_OLLAMA_BASE_URL=http://ollama:11434 was not written for direct opt-in"
grep -q "^LLM_MODEL=${openhands_model}$" "${openhands_env}" \
  || fail "LLM_MODEL was not written"
grep -q "^LLM_API_KEY=${openhands_api_key}$" "${openhands_env}" \
  || fail "LLM_API_KEY was not written"
grep -q '^LLM_BASE_URL=http://ollama-gate:11435/v1$' "${openhands_env}" \
  || fail "LLM_BASE_URL was not written"
python3 - <<PY || fail "openhands settings.json does not contain expected defaults"
import json
from pathlib import Path

payload = json.loads(Path("${openhands_settings}").read_text(encoding="utf-8"))
assert payload.get("llm_model") == "openai/${openhands_model}"
assert payload.get("llm_api_key") == "${openhands_api_key}"
assert payload.get("llm_base_url") == "http://ollama-gate:11435/v1"
assert payload.get("v1_enabled") is True
PY

grep -q '^example.com$' "${allowlist_file}" || fail "allowlist missing example.com"
grep -q '^api.openai.com$' "${allowlist_file}" || fail "allowlist missing api.openai.com"
grep -q '^10.1.0.0/24$' "${allowlist_file}" || fail "allowlist missing CIDR entry"

if grep -Fq "${openwebui_password}" "${log_file}"; then
  fail "log leaked openwebui password"
fi
if grep -Fq "${openai_key}" "${log_file}"; then
  fail "log leaked openai key"
fi
if grep -Fq "${huggingface_token}" "${log_file}"; then
  fail "log leaked huggingface token"
fi

if AGENTIC_PROFILE=strict-prod "${wizard_script}" \
  --non-interactive \
  --require-complete \
  --profile strict-prod \
  --output "${strict_env_file}" >"${strict_log_file}" 2>&1; then
  cat "${strict_log_file}" >&2 || true
  fail "wizard should fail with --require-complete when strict-prod root is not writable"
fi

grep -Eq 'incomplete onboarding with --require-complete|runtime root is not writable|not writable' "${strict_log_file}" \
  || fail "strict require-complete failure message is not actionable"

ok "00_onboarding_full_setup_wizard passed"
