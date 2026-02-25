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
openhands_model="qwen3:0.6b"
openhands_api_key="openhands-api-key"
openai_key="openai-api-key"
openrouter_key="openrouter-api-key"
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
  --openwebui-admin-email "${openwebui_email}" \
  --openwebui-admin-password "${openwebui_password}" \
  --openwebui-secret-key "${openwebui_secret}" \
  --openhands-llm-model "${openhands_model}" \
  --openhands-llm-api-key "${openhands_api_key}" \
  --allowlist-domains 'example.com,api.openai.com,10.1.0.0/24' \
  --openai-api-key "${openai_key}" \
  --openrouter-api-key "${openrouter_key}" \
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

openwebui_env="${root_dir}/openwebui/config/openwebui.env"
openhands_env="${root_dir}/openhands/config/openhands.env"
allowlist_file="${root_dir}/proxy/allowlist.txt"
openai_secret_file="${root_dir}/secrets/runtime/openai.api_key"
openrouter_secret_file="${root_dir}/secrets/runtime/openrouter.api_key"
openclaw_token_file="${root_dir}/secrets/runtime/openclaw.token"
openclaw_webhook_file="${root_dir}/secrets/runtime/openclaw.webhook_secret"
mcp_token_file="${root_dir}/secrets/runtime/mcp.token"

[[ -s "${openwebui_env}" ]] || fail "openwebui env file missing: ${openwebui_env}"
[[ -s "${openhands_env}" ]] || fail "openhands env file missing: ${openhands_env}"
[[ -s "${allowlist_file}" ]] || fail "allowlist file missing: ${allowlist_file}"

for secret_file in \
  "${openai_secret_file}" \
  "${openrouter_secret_file}" \
  "${openclaw_token_file}" \
  "${openclaw_webhook_file}" \
  "${mcp_token_file}"; do
  [[ -s "${secret_file}" ]] || fail "secret file missing: ${secret_file}"
  perm="$(stat -c '%a' "${secret_file}")"
  [[ "${perm}" == "600" ]] || fail "secret file permissions must be 600: ${secret_file} (got ${perm})"
done

grep -q "^WEBUI_ADMIN_EMAIL=${openwebui_email}$" "${openwebui_env}" \
  || fail "WEBUI_ADMIN_EMAIL was not written"
grep -q "^WEBUI_ADMIN_PASSWORD=${openwebui_password}$" "${openwebui_env}" \
  || fail "WEBUI_ADMIN_PASSWORD was not written"
grep -q "^WEBUI_SECRET_KEY=${openwebui_secret}$" "${openwebui_env}" \
  || fail "WEBUI_SECRET_KEY was not written"
grep -q "^LLM_MODEL=${openhands_model}$" "${openhands_env}" \
  || fail "LLM_MODEL was not written"
grep -q "^LLM_API_KEY=${openhands_api_key}$" "${openhands_env}" \
  || fail "LLM_API_KEY was not written"

grep -q '^example.com$' "${allowlist_file}" || fail "allowlist missing example.com"
grep -q '^api.openai.com$' "${allowlist_file}" || fail "allowlist missing api.openai.com"
grep -q '^10.1.0.0/24$' "${allowlist_file}" || fail "allowlist missing CIDR entry"

if grep -Fq "${openwebui_password}" "${log_file}"; then
  fail "log leaked openwebui password"
fi
if grep -Fq "${openai_key}" "${log_file}"; then
  fail "log leaked openai key"
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
