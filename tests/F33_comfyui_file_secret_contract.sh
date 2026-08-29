#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

runtime_root="$(mktemp -d)"
placeholder_root="$(mktemp -d)"

cleanup() {
  purge_runtime_root_test_safe "${runtime_root}" >/dev/null 2>&1 || true
  purge_runtime_root_test_safe "${placeholder_root}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_ui_init() {
  local target_root="$1"
  AGENTIC_PROFILE=strict-prod \
  AGENTIC_ROOT="${target_root}" \
  AGENT_RUNTIME_UID="$(id -u)" \
  AGENT_RUNTIME_GID="$(id -g)" \
    "${REPO_ROOT}/deployments/ui/init_runtime.sh" >/dev/null
}

install -d -m 0750 "${runtime_root}/deployments"
printf '%s\n' \
  'COMFYUI_AUTH_USERNAME=operator' \
  'COMFYUI_AUTH_PASSWORD=f33-legacy-password' \
  'AGENTIC_PROFILE=strict-prod' \
  >"${runtime_root}/deployments/runtime.env"
chmod 0640 "${runtime_root}/deployments/runtime.env"

run_ui_init "${runtime_root}"

secret_file="${runtime_root}/secrets/runtime/comfyui.auth_password"
[[ -s "${secret_file}" ]] || fail "ComfyUI runtime initialization must create the password file"
[[ "$(tr -d '\r\n' <"${secret_file}")" == "f33-legacy-password" ]] \
  || fail "ComfyUI runtime initialization must migrate the legacy password exactly once"
[[ "$(stat -c '%a' "${runtime_root}/secrets/runtime")" == "700" ]] \
  || fail "ComfyUI secret directory must use mode 700"
[[ "$(stat -c '%a' "${secret_file}")" == "600" ]] \
  || fail "ComfyUI password file must use mode 600"
! grep -Eq '^COMFYUI_AUTH_PASSWORD=' "${runtime_root}/deployments/runtime.env" \
  || fail "legacy COMFYUI_AUTH_PASSWORD must be removed from runtime.env"
grep -qx 'COMFYUI_AUTH_USERNAME=operator' "${runtime_root}/deployments/runtime.env" \
  || fail "the non-sensitive ComfyUI username must remain in runtime.env"
ok "legacy ComfyUI password migrates to the canonical mode-600 secret file"

COMFYUI_AUTH_PASSWORD='f33-ignored-environment-password' run_ui_init "${runtime_root}"
[[ "$(tr -d '\r\n' <"${secret_file}")" == "f33-legacy-password" ]] \
  || fail "runtime initialization must preserve an existing valid ComfyUI password"
ok "ComfyUI password initialization is idempotent"

AGENTIC_PROFILE=strict-prod \
AGENTIC_ROOT="${runtime_root}" \
AGENTIC_NETWORK='agentic-f33' \
AGENTIC_LLM_NETWORK='agentic-f33-llm' \
AGENTIC_EGRESS_NETWORK='agentic-f33-egress' \
AGENTIC_COMPOSE_PROJECT='agentic-f33' \
AGENT_RUNTIME_UID="$(id -u)" \
AGENT_RUNTIME_GID="$(id -g)" \
  "${REPO_ROOT}/scripts/agent.sh" comfyui rotate-password >/dev/null
rotated_value="$(tr -d '\r\n' <"${secret_file}")"
[[ -n "${rotated_value}" && "${rotated_value}" != "f33-legacy-password" ]] \
  || fail "agent comfyui rotate-password must replace the current secret"
grep -q 'action=rotate-password' "${runtime_root}/deployments/changes.log" \
  || fail "ComfyUI password rotation must be audited without logging the value"
if grep -q "${rotated_value}" "${runtime_root}/deployments/changes.log"; then
  fail "ComfyUI password rotation log leaks the new value"
fi
ok "ComfyUI password rotation is atomic and audited without secret content"

install -d -m 0750 "${placeholder_root}/deployments"
printf '%s\n' 'COMFYUI_AUTH_PASSWORD=change-me' >"${placeholder_root}/deployments/runtime.env"
run_ui_init "${placeholder_root}"
placeholder_secret="${placeholder_root}/secrets/runtime/comfyui.auth_password"
placeholder_value="$(tr -d '\r\n' <"${placeholder_secret}")"
[[ -n "${placeholder_value}" && "${placeholder_value}" != "change-me" ]] \
  || fail "the legacy change-me placeholder must be replaced with a generated secret"
! grep -Eq '^COMFYUI_AUTH_PASSWORD=' "${placeholder_root}/deployments/runtime.env" \
  || fail "the change-me entry must be removed from runtime.env"
ok "insecure legacy ComfyUI placeholder is replaced"

compose_output="$(
  AGENTIC_ROOT="${runtime_root}" \
  AGENTIC_NETWORK='agentic-f33' \
  AGENTIC_LLM_NETWORK='agentic-f33-llm' \
  AGENTIC_EGRESS_NETWORK='agentic-f33-egress' \
  COMFYUI_AUTH_PASSWORD='f33-compose-leak-marker' \
    docker compose -f "${REPO_ROOT}/compose/compose.ui.yml" config
)"
if printf '%s\n' "${compose_output}" | grep -q 'f33-compose-leak-marker'; then
  fail "Compose effective configuration leaks COMFYUI_AUTH_PASSWORD"
fi
printf '%s\n' "${compose_output}" | grep -q 'COMFYUI_AUTH_PASSWORD_FILE: /run/secrets/comfyui.auth_password' \
  || fail "Compose effective configuration must expose only the fixed password file path"
printf '%s\n' "${compose_output}" | grep -q "${runtime_root}/secrets/runtime/comfyui.auth_password" \
  || fail "Compose must mount the canonical ComfyUI password file"
ok "Compose effective configuration is secret-free and file-backed"

release_probe_dir="${runtime_root}/release-probe"
install -d -m 0750 "${release_probe_dir}"
printf '%s\n' \
  'services:' \
  '  comfyui-loopback:' \
  '    environment:' \
  '      COMFYUI_AUTH_PASSWORD: historical-inline-value' \
  >"${release_probe_dir}/compose.effective.yml"
python3 - "${REPO_ROOT}/deployments/releases/validate_release_artifacts.py" \
  "${release_probe_dir}" "${runtime_root}/secrets" <<'PY' \
  || fail "release validator must reject a historical inline ComfyUI password"
import importlib.util
import pathlib
import sys

module_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("validate_release_artifacts", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
errors = module.validate_secret_hygiene(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
if not any("forbidden inline secret key COMFYUI_AUTH_PASSWORD" in error for error in errors):
    raise SystemExit(f"missing ComfyUI inline-secret rejection: {errors}")
PY
ok "release validation rejects historical inline ComfyUI credentials"

legacy_release_id='f33-legacy-inline-secret'
legacy_release_dir="${runtime_root}/deployments/releases/${legacy_release_id}"
install -d -m 0750 "${legacy_release_dir}"
printf '%s\n' '[]' >"${legacy_release_dir}/images.json"
cp "${release_probe_dir}/compose.effective.yml" "${legacy_release_dir}/compose.effective.yml"
set +e
rollback_output="$(
  AGENTIC_PROFILE=strict-prod \
  AGENTIC_ROOT="${runtime_root}" \
  AGENTIC_NETWORK='agentic-f33' \
  AGENTIC_LLM_NETWORK='agentic-f33-llm' \
  AGENTIC_EGRESS_NETWORK='agentic-f33-egress' \
  AGENTIC_COMPOSE_PROJECT='agentic-f33' \
    "${REPO_ROOT}/deployments/releases/rollback.sh" "${legacy_release_id}" 2>&1
)"
rollback_rc=$?
set -e
[[ "${rollback_rc}" -ne 0 ]] || fail "rollback must refuse a release containing inline ComfyUI credentials"
printf '%s\n' "${rollback_output}" | grep -q 'contains legacy inline ComfyUI credentials' \
  || fail "unsafe rollback refusal must be actionable"
ok "rollback refuses historical inline ComfyUI credentials before deployment"

if rg -n 'COMFYUI_AUTH_PASSWORD[[:space:]]*:' "${REPO_ROOT}/compose" >/dev/null; then
  fail "Compose must not inject COMFYUI_AUTH_PASSWORD into any container environment"
fi
if rg -n '^COMFYUI_AUTH_PASSWORD=' "${REPO_ROOT}/examples" >/dev/null; then
  fail "tracked examples must not define COMFYUI_AUTH_PASSWORD"
fi
rg -q 'deprecated COMFYUI_AUTH_PASSWORD must not be stored' "${REPO_ROOT}/scripts/doctor.sh" \
  || fail "doctor must diagnose legacy runtime.env password storage"
rg -q 'ComfyUI authentication password is missing or empty' "${REPO_ROOT}/scripts/doctor.sh" \
  || fail "doctor must diagnose a missing ComfyUI password file"
rg -q 'ComfyUI authentication password must use mode 600' "${REPO_ROOT}/scripts/doctor.sh" \
  || fail "doctor must diagnose unsafe ComfyUI password permissions"
rg -q 'comfyui-loopback exposes COMFYUI_AUTH_PASSWORD' "${REPO_ROOT}/scripts/doctor.sh" \
  || fail "doctor must diagnose password exposure in container environment"
rg -q 'contains legacy inline ComfyUI credentials' "${REPO_ROOT}/deployments/releases/rollback.sh" \
  || fail "rollback must reject a legacy release containing inline ComfyUI credentials"
rg -q 'FORBIDDEN_INLINE_SECRET_KEYS' "${REPO_ROOT}/deployments/releases/validate_release_artifacts.py" \
  || fail "release validation must reject inline ComfyUI credentials"
rg -qF 'rotate-password)' "${REPO_ROOT}/scripts/agent.sh" \
  || fail "agent must expose an explicit ComfyUI password rotation command"
ok "static secret non-disclosure guards are present"

ok "F33_comfyui_file_secret_contract passed"
