#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
TEMPLATE_DIR="${REPO_ROOT}/examples/core"
AGENT_RUNTIME_UID="${AGENT_RUNTIME_UID:-1000}"
AGENT_RUNTIME_GID="${AGENT_RUNTIME_GID:-1000}"

log() {
  echo "INFO: $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

ensure_secret_mode() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    chmod 0600 "${file}"
  fi
}

copy_if_missing() {
  local src="$1"
  local dst="$2"
  local mode="$3"

  [[ -f "$src" ]] || die "template not found: ${src}"
  if [[ -f "$dst" ]]; then
    log "preserve existing runtime file: ${dst}"
    return 0
  fi

  install -D -m "$mode" "$src" "$dst"
  log "created runtime file: ${dst}"
}

iter_allowlist_entries() {
  local file="$1"
  awk '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line != "") {
        print line
      }
    }
  ' "${file}"
}

ensure_allowlist_baseline_entries() {
  local template_file="$1"
  local runtime_file="$2"
  local entry
  local missing_count=0

  [[ -f "${template_file}" ]] || die "allowlist template not found: ${template_file}"
  [[ -f "${runtime_file}" ]] || return 0

  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    if ! grep -Fxiq -- "${entry}" "${runtime_file}"; then
      printf '%s\n' "${entry}" >> "${runtime_file}"
      missing_count=$((missing_count + 1))
    fi
  done < <(iter_allowlist_entries "${template_file}")

  if (( missing_count > 0 )); then
    log "updated allowlist baseline: appended ${missing_count} missing entries to ${runtime_file}"
  fi
}

set_proxy_runtime_permissions() {
  local proxy_logs_dir="${AGENTIC_ROOT}/proxy/logs"
  local -a proxy_log_files=(
    "${proxy_logs_dir}/access.log"
    "${proxy_logs_dir}/cache.log"
  )

  chmod 0755 "${proxy_logs_dir}"

  if [[ "${EUID}" -eq 0 ]]; then
    chown 13:13 "${proxy_logs_dir}"
    local log_file
    for log_file in "${proxy_log_files[@]}"; do
      [[ -e "${log_file}" ]] || continue
      chown 13:13 "${log_file}" || true
      chmod 0640 "${log_file}" || true
    done
    return 0
  fi

  if command -v setfacl >/dev/null 2>&1; then
    # Squid opens log files before dropping from uid 0 to uid 13 (proxy).
    # With cap_drop=ALL, both uids need explicit write rights on bind-mounted logs.
    if ! setfacl -m u:0:rwx,u:13:rwx "${proxy_logs_dir}"; then
      log "non-root runtime init: unable to set ACL on ${proxy_logs_dir}; continuing"
      return 0
    fi
    if ! setfacl -d -m u:0:rwx,u:13:rwx "${proxy_logs_dir}"; then
      log "non-root runtime init: unable to set default ACL on ${proxy_logs_dir}; continuing"
      return 0
    fi

    local log_file
    for log_file in "${proxy_log_files[@]}"; do
      [[ -e "${log_file}" ]] || continue
      setfacl -m u:0:rw,u:13:rw "${log_file}" || true
    done

    log "non-root runtime init: applied ACL grants (uid 0 + uid 13) on ${proxy_logs_dir}"
    return 0
  fi

  log "non-root runtime init: setfacl not found, cannot enforce squid log ACLs on ${proxy_logs_dir}"
}

set_gate_runtime_permissions() {
  local gate_dir="${AGENTIC_ROOT}/gate"
  local gate_config_dir="${AGENTIC_ROOT}/gate/config"
  local gate_model_routes_file="${gate_config_dir}/model_routes.yml"
  local gate_state_dir="${AGENTIC_ROOT}/gate/state"
  local gate_logs_dir="${AGENTIC_ROOT}/gate/logs"
  local gate_mcp_dir="${AGENTIC_ROOT}/gate/mcp"
  local gate_mcp_state_dir="${AGENTIC_ROOT}/gate/mcp/state"
  local gate_mcp_logs_dir="${AGENTIC_ROOT}/gate/mcp/logs"
  local gate_mcp_token="${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token"
  local openai_key="${AGENTIC_ROOT}/secrets/runtime/openai.api_key"
  local openrouter_key="${AGENTIC_ROOT}/secrets/runtime/openrouter.api_key"
  local trtllm_models_dir="${AGENTIC_ROOT}/trtllm/models"
  local trtllm_state_dir="${AGENTIC_ROOT}/trtllm/state"
  local trtllm_logs_dir="${AGENTIC_ROOT}/trtllm/logs"

  if [[ "${EUID}" -eq 0 ]]; then
    chmod 0750 "${gate_dir}" "${gate_config_dir}"
    chmod 0750 "${gate_mcp_dir}"
    [[ -f "${gate_model_routes_file}" ]] && chmod 0640 "${gate_model_routes_file}" || true
    chmod 0770 "${gate_state_dir}" "${gate_logs_dir}" "${gate_mcp_state_dir}" "${gate_mcp_logs_dir}"
    chmod 0770 "${trtllm_models_dir}" "${trtllm_state_dir}" "${trtllm_logs_dir}"
    chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" \
      "${gate_config_dir}" \
      "${gate_state_dir}" "${gate_logs_dir}" "${gate_mcp_state_dir}" "${gate_mcp_logs_dir}" \
      "${trtllm_models_dir}" "${trtllm_state_dir}" "${trtllm_logs_dir}" || true
    [[ -f "${gate_model_routes_file}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${gate_model_routes_file}" || true
    # Normalize historical root-owned runtime files to avoid non-root startup failures.
    chown -R "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" \
      "${gate_state_dir}" "${gate_logs_dir}" "${gate_mcp_state_dir}" "${gate_mcp_logs_dir}" || true
    chmod -R u+rwX,g+rwX,o-rwx \
      "${gate_state_dir}" "${gate_logs_dir}" "${gate_mcp_state_dir}" "${gate_mcp_logs_dir}" || true
    [[ -f "${gate_mcp_token}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${gate_mcp_token}" || true
    [[ -f "${openai_key}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openai_key}" || true
    [[ -f "${openrouter_key}" ]] && chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${openrouter_key}" || true
    return 0
  fi

  # Non-root local runs can include userns-remapped containers; relax only runtime test paths.
  chmod 0755 "${gate_dir}" "${gate_config_dir}"
  chmod 0755 "${gate_mcp_dir}"
  chmod 0770 "${gate_state_dir}" "${gate_logs_dir}" "${gate_mcp_state_dir}" "${gate_mcp_logs_dir}"
  log "non-root runtime init: relaxed gate dir permissions for userns compatibility"
}

ensure_gate_mode_file() {
  local mode_file="${AGENTIC_ROOT}/gate/state/llm_mode.json"
  local default_mode="${AGENTIC_LLM_MODE:-hybrid}"

  case "${default_mode}" in
    local|hybrid|remote) ;;
    *) default_mode="hybrid" ;;
  esac

  if [[ -f "${mode_file}" ]]; then
    return 0
  fi

  cat >"${mode_file}" <<JSON
{"mode":"${default_mode}","updated_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","updated_by":"init_runtime"}
JSON
  chmod 0640 "${mode_file}"
  log "created runtime file: ${mode_file}"
}

ensure_gate_quotas_file() {
  local quotas_file="${AGENTIC_ROOT}/gate/state/quotas_state.json"
  if [[ -f "${quotas_file}" ]]; then
    return 0
  fi
  cat >"${quotas_file}" <<JSON
{"version":1,"providers":{}}
JSON
  chmod 0640 "${quotas_file}"
  log "created runtime file: ${quotas_file}"
}

ensure_gate_mcp_token() {
  local token_file="${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token"
  local token
  if [[ -s "${token_file}" ]]; then
    chmod 0600 "${token_file}" || true
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    token="$(openssl rand -hex 24)"
  else
    token="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi

  printf '%s\n' "${token}" >"${token_file}"
  chmod 0600 "${token_file}"
  log "created runtime file: ${token_file}"
}

main() {
  install -d -m 0750 "${AGENTIC_ROOT}/ollama"
  install -d -m 0770 "${AGENTIC_ROOT}/ollama/models"
  install -d -m 0750 "${AGENTIC_ROOT}/gate"
  install -d -m 0750 "${AGENTIC_ROOT}/gate/config"
  install -d -m 0770 "${AGENTIC_ROOT}/gate/state"
  install -d -m 0770 "${AGENTIC_ROOT}/gate/logs"
  install -d -m 0750 "${AGENTIC_ROOT}/gate/mcp"
  install -d -m 0770 "${AGENTIC_ROOT}/gate/mcp/state"
  install -d -m 0770 "${AGENTIC_ROOT}/gate/mcp/logs"
  install -d -m 0750 "${AGENTIC_ROOT}/trtllm"
  install -d -m 0770 "${AGENTIC_ROOT}/trtllm/models"
  install -d -m 0770 "${AGENTIC_ROOT}/trtllm/state"
  install -d -m 0770 "${AGENTIC_ROOT}/trtllm/logs"
  install -d -m 0750 "${AGENTIC_ROOT}/dns"
  install -d -m 0750 "${AGENTIC_ROOT}/proxy"
  install -d -m 0750 "${AGENTIC_ROOT}/proxy/config"
  install -d -m 0755 "${AGENTIC_ROOT}/proxy/logs"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets/runtime"

  copy_if_missing "${TEMPLATE_DIR}/model_routes.yml" "${AGENTIC_ROOT}/gate/config/model_routes.yml" 0640
  copy_if_missing "${TEMPLATE_DIR}/unbound.conf" "${AGENTIC_ROOT}/dns/unbound.conf" 0644
  copy_if_missing "${TEMPLATE_DIR}/squid.conf" "${AGENTIC_ROOT}/proxy/config/squid.conf" 0644
  copy_if_missing "${TEMPLATE_DIR}/allowlist.txt" "${AGENTIC_ROOT}/proxy/allowlist.txt" 0644
  ensure_allowlist_baseline_entries "${TEMPLATE_DIR}/allowlist.txt" "${AGENTIC_ROOT}/proxy/allowlist.txt"
  chmod 0640 "${AGENTIC_ROOT}/gate/config/model_routes.yml"
  chmod 0644 "${AGENTIC_ROOT}/dns/unbound.conf"
  chmod 0644 "${AGENTIC_ROOT}/proxy/config/squid.conf"
  chmod 0644 "${AGENTIC_ROOT}/proxy/allowlist.txt"
  ensure_gate_mode_file
  ensure_gate_quotas_file
  ensure_gate_mcp_token
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/openai.api_key"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/openrouter.api_key"
  set_gate_runtime_permissions
  set_proxy_runtime_permissions
}

main "$@"
