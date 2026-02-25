#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AGENTIC_ROOT="${AGENTIC_ROOT:-/srv/agentic}"
TEMPLATE_DIR="${REPO_ROOT}/examples/optional"

log() {
  echo "INFO: $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

copy_if_missing() {
  local src="$1"
  local dst="$2"
  local mode="$3"

  [[ -f "${src}" ]] || die "template not found: ${src}"
  if [[ -f "${dst}" ]]; then
    log "preserve existing runtime file: ${dst}"
    return 0
  fi

  install -D -m "${mode}" "${src}" "${dst}"
  log "created runtime file: ${dst}"
}

ensure_secret_mode() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    chmod 0600 "${file}"
  fi
}

upsert_key_value_in_file() {
  local file_path="$1"
  local key="$2"
  local value="$3"
  local tmp_file

  [[ -f "${file_path}" ]] || return 1
  tmp_file="$(mktemp "${file_path}.tmp.XXXXXX")" || return 1

  awk -v k="${key}" -v v="${value}" '
    BEGIN { replaced=0 }
    $0 ~ ("^" k "=") {
      if (!replaced) {
        print k "=" v
        replaced=1
      }
      next
    }
    { print }
    END {
      if (!replaced) {
        print k "=" v
      }
    }
  ' "${file_path}" >"${tmp_file}" || {
    rm -f "${tmp_file}"
    return 1
  }

  chmod 0640 "${tmp_file}" || {
    rm -f "${tmp_file}"
    return 1
  }
  mv "${tmp_file}" "${file_path}" || {
    rm -f "${tmp_file}"
    return 1
  }
}

optional_request_default_need() {
  local module="$1"
  case "${module}" in
    openclaw) printf '%s\n' "Enable scoped OpenClaw webhook and DM automation for approved workflows." ;;
    mcp) printf '%s\n' "Expose a restricted MCP catalog for local automation workflows." ;;
    pi-mono) printf '%s\n' "Provide an additional isolated CLI agent runtime for targeted tasks." ;;
    goose) printf '%s\n' "Provide an isolated Goose CLI runtime for approved workflows." ;;
    portainer) printf '%s\n' "Provide temporary loopback-only Portainer visibility for local diagnostics." ;;
    *) return 1 ;;
  esac
}

optional_request_default_success() {
  local module="$1"
  case "${module}" in
    openclaw) printf '%s\n' "Webhook auth succeeds, deny paths stay blocked, and service healthcheck stays green." ;;
    mcp) printf '%s\n' "Only allowlisted tools are available and service healthcheck stays green." ;;
    pi-mono) printf '%s\n' "Container starts with expected user/workspace mappings and no forbidden mounts." ;;
    goose) printf '%s\n' "Container starts successfully with isolated workspace and expected proxy controls." ;;
    portainer) printf '%s\n' "UI is reachable on loopback only and runs without docker.sock mount." ;;
    *) return 1 ;;
  esac
}

ensure_optional_request_file() {
  local module="$1"
  local request_file="${AGENTIC_ROOT}/deployments/optional/${module}.request"
  local need_value
  local success_value
  local owner_value

  need_value="$(optional_request_default_need "${module}")" \
    || die "unable to resolve default need for optional module '${module}'"
  success_value="$(optional_request_default_success "${module}")" \
    || die "unable to resolve default success for optional module '${module}'"
  owner_value="${SUDO_USER:-${USER:-operator}}"

  copy_if_missing "${TEMPLATE_DIR}/activation.request.example" "${request_file}" 0640

  if ! grep -Eq '^need=[^[:space:]].+$' "${request_file}"; then
    upsert_key_value_in_file "${request_file}" "need" "${need_value}" \
      || die "failed to update need= in ${request_file}"
  fi

  if ! grep -Eq '^success=[^[:space:]].+$' "${request_file}"; then
    upsert_key_value_in_file "${request_file}" "success" "${success_value}" \
      || die "failed to update success= in ${request_file}"
  fi

  if ! grep -Eq '^owner=' "${request_file}"; then
    upsert_key_value_in_file "${request_file}" "owner" "${owner_value}" \
      || die "failed to update owner= in ${request_file}"
  fi

  if ! grep -Eq '^expires_at=' "${request_file}"; then
    upsert_key_value_in_file "${request_file}" "expires_at" "" \
      || die "failed to update expires_at= in ${request_file}"
  fi
}

main() {
  local runtime_uid="${AGENT_RUNTIME_UID:-1000}"
  local runtime_gid="${AGENT_RUNTIME_GID:-1000}"

  install -d -m 0750 "${AGENTIC_ROOT}/optional"
  install -d -m 0750 "${AGENTIC_ROOT}/optional/openclaw"
  install -d -m 0750 "${AGENTIC_ROOT}/optional/openclaw/config"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/openclaw/state"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/openclaw/logs"
  install -d -m 0750 "${AGENTIC_ROOT}/optional/openclaw/sandbox"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/openclaw/sandbox/state"

  install -d -m 0750 "${AGENTIC_ROOT}/optional/mcp"
  install -d -m 0750 "${AGENTIC_ROOT}/optional/mcp/config"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/mcp/state"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/mcp/logs"

  install -d -m 0750 "${AGENTIC_ROOT}/optional/pi-mono"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/pi-mono/state"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/pi-mono/logs"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/pi-mono/workspaces"

  install -d -m 0750 "${AGENTIC_ROOT}/optional/goose"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/goose/state"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/goose/logs"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/goose/workspaces"

  install -d -m 0750 "${AGENTIC_ROOT}/optional/portainer"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/portainer/data"
  install -d -m 0770 "${AGENTIC_ROOT}/optional/portainer/logs"

  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  install -d -m 0750 "${AGENTIC_ROOT}/deployments/optional"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets"
  install -d -m 0700 "${AGENTIC_ROOT}/secrets/runtime"

  copy_if_missing "${TEMPLATE_DIR}/openclaw.dm_allowlist.txt" "${AGENTIC_ROOT}/optional/openclaw/config/dm_allowlist.txt" 0640
  copy_if_missing "${TEMPLATE_DIR}/openclaw.tool_allowlist.txt" "${AGENTIC_ROOT}/optional/openclaw/config/tool_allowlist.txt" 0640
  copy_if_missing "${TEMPLATE_DIR}/mcp.tool_allowlist.txt" "${AGENTIC_ROOT}/optional/mcp/config/tool_allowlist.txt" 0640
  ensure_optional_request_file "openclaw"
  ensure_optional_request_file "mcp"
  ensure_optional_request_file "pi-mono"
  ensure_optional_request_file "goose"
  ensure_optional_request_file "portainer"

  chmod 0644 "${AGENTIC_ROOT}/optional/openclaw/config/dm_allowlist.txt" \
    "${AGENTIC_ROOT}/optional/openclaw/config/tool_allowlist.txt" \
    "${AGENTIC_ROOT}/optional/mcp/config/tool_allowlist.txt"

  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/openclaw.token"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret"
  ensure_secret_mode "${AGENTIC_ROOT}/secrets/runtime/mcp.token"

  if [[ "${EUID}" -eq 0 ]]; then
    chown -R "${runtime_uid}:${runtime_gid}" \
      "${AGENTIC_ROOT}/optional/openclaw/state" \
      "${AGENTIC_ROOT}/optional/openclaw/sandbox/state" \
      "${AGENTIC_ROOT}/optional/openclaw/logs" \
      "${AGENTIC_ROOT}/optional/mcp/state" \
      "${AGENTIC_ROOT}/optional/mcp/logs" \
      "${AGENTIC_ROOT}/optional/pi-mono/state" \
      "${AGENTIC_ROOT}/optional/pi-mono/logs" \
      "${AGENTIC_ROOT}/optional/pi-mono/workspaces" \
      "${AGENTIC_ROOT}/optional/goose/state" \
      "${AGENTIC_ROOT}/optional/goose/logs" \
      "${AGENTIC_ROOT}/optional/goose/workspaces" \
      "${AGENTIC_ROOT}/optional/portainer/data" \
      "${AGENTIC_ROOT}/optional/portainer/logs"
    if [[ -f "${AGENTIC_ROOT}/secrets/runtime/openclaw.token" ]]; then
      chown "${runtime_uid}:${runtime_gid}" "${AGENTIC_ROOT}/secrets/runtime/openclaw.token"
    fi
    if [[ -f "${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret" ]]; then
      chown "${runtime_uid}:${runtime_gid}" "${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret"
    fi
    if [[ -f "${AGENTIC_ROOT}/secrets/runtime/mcp.token" ]]; then
      chown "${runtime_uid}:${runtime_gid}" "${AGENTIC_ROOT}/secrets/runtime/mcp.token"
    fi
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    chmod 0770 "${AGENTIC_ROOT}/optional/openclaw/state" \
      "${AGENTIC_ROOT}/optional/openclaw/sandbox/state" \
      "${AGENTIC_ROOT}/optional/openclaw/logs" \
      "${AGENTIC_ROOT}/optional/mcp/state" \
      "${AGENTIC_ROOT}/optional/mcp/logs" \
      "${AGENTIC_ROOT}/optional/pi-mono/state" \
      "${AGENTIC_ROOT}/optional/pi-mono/logs" \
      "${AGENTIC_ROOT}/optional/pi-mono/workspaces" \
      "${AGENTIC_ROOT}/optional/goose/state" \
      "${AGENTIC_ROOT}/optional/goose/logs" \
      "${AGENTIC_ROOT}/optional/goose/workspaces" \
      "${AGENTIC_ROOT}/optional/portainer/data" \
      "${AGENTIC_ROOT}/optional/portainer/logs"
    log "non-root runtime init: relaxed optional dirs permissions for userns compatibility"
  fi
}

main "$@"
