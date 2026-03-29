#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

AGENT_RUNTIME_ENV_FILE="${AGENTIC_ROOT}/deployments/runtime.env"
AGENT_RELEASE_SNAPSHOT_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/releases/snapshot.sh"
AGENT_RELEASE_ROLLBACK_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/releases/rollback.sh"
AGENT_RELEASE_RESOLVE_LATEST_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/releases/resolve_latest.py"
AGENT_BACKUP_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/backups/time_machine.sh"
AGENT_DOCKER_USER_ROLLBACK_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/net/rollback_docker_user.sh"
AGENT_DOCTOR_SCRIPT="${SCRIPT_DIR}/doctor.sh"
AGENT_PREREQS_SCRIPT="${AGENTIC_REPO_ROOT}/scripts/check_prereqs.sh"
AGENT_ONBOARD_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/bootstrap/onboarding_env.sh"
AGENT_OLLAMA_PRELOAD_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/ollama/preload_and_lock.sh"
AGENT_TRTLLM_PREPARE_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/trtllm/prepare_nvfp4_model.sh"
AGENT_OLLAMA_LINK_SCRIPT="${AGENTIC_REPO_ROOT}/scripts/setup-ollama-models-link.sh"
AGENT_OLLAMA_LINK_ROLLBACK_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/ollama/rollback_models_link.sh"
AGENT_OLLAMA_DRIFT_WATCH_SCRIPT="${AGENTIC_REPO_ROOT}/scripts/ollama_drift_watch.sh"
AGENT_OLLAMA_DRIFT_SCHEDULE_SCRIPT="${AGENTIC_REPO_ROOT}/scripts/install_ollama_drift_watch_schedule.sh"
AGENT_COMFYUI_FLUX_SETUP_SCRIPT="${AGENTIC_REPO_ROOT}/scripts/comfyui_flux_setup.sh"
AGENT_OPENCLAW_APPROVALS_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/optional/openclaw_approvals.py"
AGENT_OPENCLAW_OPERATOR_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/optional/openclaw_operator.py"
AGENT_OPENCLAW_MODULE_MANIFEST_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/optional/openclaw_module_manifest.py"
AGENT_OPENCLAW_MANAGED_INIT_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/optional/openclaw_managed_init.py"
AGENT_GIT_FORGE_BOOTSTRAP_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/optional/git_forge_bootstrap.py"
AGENT_VM_CREATE_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/vm/create_strict_prod_vm.sh"
AGENT_VM_TEST_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/vm/test_strict_prod_vm.sh"
AGENT_VM_CLEANUP_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/vm/cleanup_strict_prod_vm.sh"
AGENT_TOOLS=(claude codex opencode vibestral openclaw pi-mono goose)
AGENT_STATUS_TARGETS=(claude codex opencode vibestral openclaw pi-mono goose openwebui openhands comfyui)
STOP_START_TARGETS=(claude codex opencode vibestral openclaw pi-mono goose openwebui openhands comfyui)
OPTIONAL_MODULES=(mcp git-forge pi-mono goose portainer)
FORGET_TARGETS=(ollama claude codex opencode vibestral comfyui openclaw openhands openwebui qdrant obs all)
STACK_START_ORDER=(core agents ui obs rag optional)
STACK_STOP_ORDER=(optional rag obs ui agents core)

usage() {
  cat <<USAGE
Usage:
  agent [strict-prod|rootless-dev] <command ...>
  agent profile
  agent first-up [--env-file <path>] [--no-env] [--dry-run]
  agent up <core|agents|ui|obs|rag|optional>
  agent down <core|agents|ui|obs|rag|optional>
  agent stack <start|stop> <core|agents|ui|obs|rag|optional|all>
  agent <claude|codex|opencode|vibestral|openclaw|pi-mono|goose> [project]
  agent openclaw init [project]
  agent openclaw status [--json]
  agent openclaw policy [list [--json] | add <dm-target|tool> <value> [--json]]
  agent openclaw model set <id> [--json]
  agent openclaw sandbox [ls [--json] | attach <sandbox_id> | destroy <sandbox_id> [--json]]
  agent openclaw approvals [list [--status <pending|approved|denied|expired|all>] [--json] | approve <id> --scope <session|global> [--session-id <id>] [--ttl-sec <sec>] | deny <id> --scope <session|global> [--session-id <id>] [--ttl-sec <sec>] [--reason <text>] | promote <id>]
  agent ls
  agent status
  agent ps
  agent llm mode [local|hybrid|mixed|remote]
  agent llm backend [ollama|trtllm|both|remote]
  agent llm test-mode [on|off]
  agent comfyui flux-1-dev [--download] [--hf-token-file <path>] [--no-egress-check] [--dry-run]
  agent logs <service>
  agent stop <target>
  agent stop service <service...>
  agent stop container <container...>
  agent start <target>
  agent start service <service...>
  agent start container <container...>
  agent backup <run|list|restore <snapshot_id> [--yes]>
  agent forget <target> [--yes] [--no-backup]
  agent cleanup [--yes] [--backup|--no-backup]
  agent net apply
  agent ollama unload <model>
  agent trtllm [status|prepare|start|stop]
  agent ollama-link
  agent ollama-drift watch [--ack-baseline] [--no-beads] [--issue-id <id>] [--state-dir <path>] [--sources-dir <path>] [--sources <csv>] [--timeout-sec <int>] [--quiet]
  agent ollama-drift schedule [--disable] [--dry-run] [--on-calendar <expr>] [--cron <expr>] [--force-cron]
  agent ollama-preload [--generate-model <model>] [--embed-model <model>] [--budget-gb <int>] [--no-lock-ro]
  agent ollama-models [status|rw|ro]
  agent sudo-mode [status|on|off]
  agent update
  agent rollback all <release_id>
  agent rollback host-net <backup_id>
  agent rollback ollama-link <backup_id|latest>
  agent prereqs
  agent onboard [runtime flags...] [--compose-profiles ... --default-model ... --default-model-context-window ... --trtllm-models ... --grafana-admin-user ... --grafana-admin-password ... --obs-retention-time ... --obs-max-disk ... --openwebui-admin-email ... --openwebui-admin-password ... --openhands-llm-model ... --allowlist-domains ... --huggingface-token ... --openclaw-init-project ... --telegram-bot-token ... --discord-bot-token ... --slack-bot-token ... --slack-app-token ... --slack-signing-secret ... --optional-modules ... --output ... --non-interactive --require-complete]
  agent vm create [--name ... --cpus ... --memory ... --disk ... --image ... --workspace-path ... --reuse-existing --mount-repo|--no-mount-repo --require-gpu --skip-bootstrap --dry-run]
  agent vm test [--name ... --workspace-path ... --test-selectors ... --require-gpu|--allow-no-gpu --skip-d5-tests --dry-run]
  agent vm cleanup [--name ... --yes --dry-run]
  agent test <A|B|C|D|E|F|G|H|I|J|K|L|V|all> [--skip-d5-tests]
  agent doctor [--fix-net] [--check-tool-stream-e2e]

Optional modules (disabled by default):
  AGENTIC_OPTIONAL_MODULES=mcp,git-forge,pi-mono,goose,portainer agent up optional
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

read_secret_value() {
  local inline_value="$1"
  local file_path="$2"

  if [[ -n "${inline_value}" && -n "${file_path}" ]]; then
    die "choose only one of inline secret value or secret file path"
  fi

  if [[ -n "${file_path}" ]]; then
    [[ -r "${file_path}" ]] || die "secret file is not readable: ${file_path}"
    tr -d '\r\n' <"${file_path}"
    return 0
  fi

  printf '%s' "${inline_value}"
}

write_runtime_secret_file() {
  local destination="$1"
  local value="$2"

  [[ -n "${value}" ]] || die "secret value for ${destination} must be non-empty"
  install -d -m 0700 "$(dirname "${destination}")"
  umask 077
  printf '%s\n' "${value}" >"${destination}"
  chmod 0600 "${destination}" || true
  if [[ "${EUID}" -eq 0 ]]; then
    chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${destination}" || true
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

canonicalize_path() {
  local path="$1"
  readlink -f "${path}" 2>/dev/null || printf '%s\n' "${path}"
}

path_within() {
  local path="$1"
  local root="$2"
  [[ -n "${root}" ]] || return 1
  [[ "${path}" == "${root}" || "${path}" == "${root}"/* ]]
}

path_allowed_for_purge() {
  local path="$1"
  path_within "${path}" "${AGENTIC_ROOT}" && return 0
  path_within "${path}" "${AGENTIC_AGENT_WORKSPACES_ROOT}" && return 0
  path_within "${path}" "${AGENTIC_CLAUDE_WORKSPACES_DIR}" && return 0
  path_within "${path}" "${AGENTIC_CODEX_WORKSPACES_DIR}" && return 0
  path_within "${path}" "${AGENTIC_OPENCODE_WORKSPACES_DIR}" && return 0
  path_within "${path}" "${AGENTIC_VIBESTRAL_WORKSPACES_DIR}" && return 0
  path_within "${path}" "${AGENTIC_OPENHANDS_WORKSPACES_DIR}" && return 0
  path_within "${path}" "${AGENTIC_OPENCLAW_WORKSPACES_DIR}" && return 0
  path_within "${path}" "${AGENTIC_PI_MONO_WORKSPACES_DIR}" && return 0
  path_within "${path}" "${AGENTIC_GOOSE_WORKSPACES_DIR}" && return 0
  return 1
}

cleanup_model_paths() {
  local -a candidates=()
  local configured_source=""
  local path

  candidates+=("${AGENTIC_ROOT}/trtllm/models")
  candidates+=("${AGENTIC_ROOT}/comfyui/models")
  candidates+=("${AGENTIC_ROOT}/ollama/models")

  configured_source="$(canonicalize_path "${OLLAMA_MODELS_DIR}")"
  if [[ -n "${configured_source}" ]] && path_within "${configured_source}" "${AGENTIC_ROOT}"; then
    candidates+=("${configured_source}")
  fi

  for path in "${candidates[@]}"; do
    [[ -n "${path}" ]] || continue
    path_within "${path}" "${AGENTIC_ROOT}" || continue
    printf '%s\n' "${path}"
  done | awk 'NF && !seen[$0]++'
}

agent_workspace_dir() {
  local tool="$1"
  case "${tool}" in
    claude) printf '%s\n' "${AGENTIC_CLAUDE_WORKSPACES_DIR}" ;;
    codex) printf '%s\n' "${AGENTIC_CODEX_WORKSPACES_DIR}" ;;
    opencode) printf '%s\n' "${AGENTIC_OPENCODE_WORKSPACES_DIR}" ;;
    vibestral) printf '%s\n' "${AGENTIC_VIBESTRAL_WORKSPACES_DIR}" ;;
    openclaw) printf '%s\n' "${AGENTIC_OPENCLAW_WORKSPACES_DIR}" ;;
    pi-mono) printf '%s\n' "${AGENTIC_PI_MONO_WORKSPACES_DIR}" ;;
    goose) printf '%s\n' "${AGENTIC_GOOSE_WORKSPACES_DIR}" ;;
    *) return 1 ;;
  esac
}

target_workspace_dir() {
  local target="$1"
  case "${target}" in
    claude|codex|opencode|vibestral|openclaw|pi-mono|goose)
      agent_workspace_dir "${target}"
      ;;
    openhands)
      printf '%s\n' "${AGENTIC_OPENHANDS_WORKSPACES_DIR}"
      ;;
    *)
      return 1
      ;;
  esac
}

tool_to_service() {
  case "$1" in
    claude) echo "agentic-claude" ;;
    codex) echo "agentic-codex" ;;
    opencode) echo "agentic-opencode" ;;
    vibestral) echo "agentic-vibestral" ;;
    openclaw) echo "openclaw" ;;
    pi-mono) echo "optional-pi-mono" ;;
    goose) echo "optional-goose" ;;
    *) return 1 ;;
  esac
}

tool_session_mode() {
  case "$1" in
    openclaw) echo "openclaw-shell" ;;
    goose) echo "goose-direct" ;;
    *) echo "tmux" ;;
  esac
}

target_session_mode() {
  case "$1" in
    claude|codex|opencode|vibestral|pi-mono) echo "tmux" ;;
    openclaw|goose|openwebui|openhands|comfyui) echo "n/a" ;;
    *) return 1 ;;
  esac
}

service_start_hint() {
  case "$1" in
    openclaw|openclaw-gateway) echo "agent up core" ;;
    optional-pi-mono) echo "AGENTIC_OPTIONAL_MODULES=pi-mono agent up optional" ;;
    optional-goose) echo "AGENTIC_OPTIONAL_MODULES=goose agent up optional" ;;
    *) echo "agent up agents" ;;
  esac
}

target_to_compose_file() {
  case "$1" in
    claude|codex|opencode|vibestral) stack_to_compose_file agents ;;
    openclaw) stack_to_compose_file core ;;
    openwebui|openhands|comfyui) stack_to_compose_file ui ;;
    pi-mono|goose) stack_to_compose_file optional ;;
    *) return 1 ;;
  esac
}

target_to_services() {
  case "$1" in
    claude) printf '%s\n' "agentic-claude" ;;
    codex) printf '%s\n' "agentic-codex" ;;
    opencode) printf '%s\n' "agentic-opencode" ;;
    vibestral) printf '%s\n' "agentic-vibestral" ;;
    openclaw)
      printf '%s\n' \
        "openclaw" \
        "openclaw-gateway" \
        "openclaw-provider-bridge" \
        "openclaw-sandbox" \
        "openclaw-relay"
      ;;
    pi-mono) printf '%s\n' "optional-pi-mono" ;;
    goose) printf '%s\n' "optional-goose" ;;
    openwebui) printf '%s\n' "openwebui" ;;
    openhands) printf '%s\n' "openhands" ;;
    comfyui)
      printf '%s\n' \
        "comfyui" \
        "comfyui-loopback"
      ;;
    *) return 1 ;;
  esac
}

stack_to_compose_file() {
  case "$1" in
    core) echo "${AGENTIC_COMPOSE_DIR}/compose.core.yml" ;;
    agents) echo "${AGENTIC_COMPOSE_DIR}/compose.agents.yml" ;;
    ui) echo "${AGENTIC_COMPOSE_DIR}/compose.ui.yml" ;;
    obs) echo "${AGENTIC_COMPOSE_DIR}/compose.obs.yml" ;;
    rag) echo "${AGENTIC_COMPOSE_DIR}/compose.rag.yml" ;;
    optional) echo "${AGENTIC_COMPOSE_DIR}/compose.optional.yml" ;;
    *) die "Unknown target stack: $1" ;;
  esac
}

parse_targets() {
  local raw="$1"
  if [[ "$raw" == "all" ]]; then
    echo "core agents ui obs rag optional"
    return 0
  fi

  raw="${raw//,/ }"
  echo "$raw"
}

stack_all_targets() {
  local raw="${AGENTIC_STACK_ALL_TARGETS:-core,agents,ui,obs,rag,optional}"
  raw="${raw//,/ }"
  printf '%s\n' "${raw}"
}

join_targets_csv() {
  local -a parts=("$@")
  local out=""
  local item
  for item in "${parts[@]}"; do
    if [[ -z "${out}" ]]; then
      out="${item}"
    else
      out="${out},${item}"
    fi
  done
  printf '%s\n' "${out}"
}

targets_include() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

optional_module_profile() {
  case "$1" in
    mcp) echo "optional-mcp" ;;
    git-forge) echo "optional-git-forge" ;;
    pi-mono) echo "optional-pi-mono" ;;
    goose) echo "optional-goose" ;;
    portainer) echo "optional-portainer" ;;
    *) return 1 ;;
  esac
}

optional_module_secret_files() {
  case "$1" in
    mcp) printf '%s\n' "${AGENTIC_ROOT}/secrets/runtime/mcp.token" ;;
    git-forge)
      printf '%s\n' \
        "${AGENTIC_ROOT}/secrets/runtime/git-forge/${GIT_FORGE_ADMIN_USER}.password" \
        "${AGENTIC_ROOT}/secrets/runtime/git-forge/openclaw.password" \
        "${AGENTIC_ROOT}/secrets/runtime/git-forge/openhands.password" \
        "${AGENTIC_ROOT}/secrets/runtime/git-forge/comfyui.password" \
        "${AGENTIC_ROOT}/secrets/runtime/git-forge/claude.password" \
        "${AGENTIC_ROOT}/secrets/runtime/git-forge/codex.password" \
        "${AGENTIC_ROOT}/secrets/runtime/git-forge/opencode.password" \
        "${AGENTIC_ROOT}/secrets/runtime/git-forge/vibestral.password" \
        "${AGENTIC_ROOT}/secrets/runtime/git-forge/pi-mono.password" \
        "${AGENTIC_ROOT}/secrets/runtime/git-forge/goose.password"
      ;;
    pi-mono) printf '%s\n' "${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token" ;;
    goose|portainer) ;;
    *) return 1 ;;
  esac
}

optional_module_config_files() {
  case "$1" in
    mcp|git-forge|pi-mono|goose|portainer) ;;
    *) return 1 ;;
  esac
}

validate_openclaw_profile_file_contract() {
  local profile_file="$1"
  python3 - "${profile_file}" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(payload, dict):
    raise SystemExit("profile must be an object")

runtime = payload.get("runtime")
if not isinstance(runtime, dict):
    raise SystemExit("missing runtime object")
required_env = runtime.get("required_env")
if not isinstance(required_env, dict):
    raise SystemExit("missing runtime.required_env object")

for key in ("openclaw", "openclaw_sandbox"):
    values = required_env.get(key)
    if not isinstance(values, list) or not values:
        raise SystemExit(f"runtime.required_env.{key} must be a non-empty array")

endpoints = runtime.get("endpoints")
if not isinstance(endpoints, dict):
    raise SystemExit("missing runtime.endpoints object")
for key in ("dm", "webhook_dm", "tool_execute", "sandbox_execute", "profile"):
    values = endpoints.get(key)
    if not isinstance(values, list) or not values:
        raise SystemExit(f"runtime.endpoints.{key} must be a non-empty array")
PY
}

validate_openclaw_relay_targets_file_contract() {
  local targets_file="$1"
  python3 - "${targets_file}" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(payload, dict):
    raise SystemExit("relay targets file must be an object")
providers = payload.get("providers")
if not isinstance(providers, dict) or not providers:
    raise SystemExit("relay targets file must define providers object with entries")
for name, entry in providers.items():
    if not isinstance(name, str) or not name.strip():
        raise SystemExit("provider key must be a non-empty string")
    if not isinstance(entry, dict):
        raise SystemExit(f"provider entry must be an object: {name}")
    target = entry.get("target")
    if not isinstance(target, str) or not target.strip():
        raise SystemExit(f"provider entry must define non-empty target: {name}")
PY
}

parse_optional_modules() {
  local raw="${AGENTIC_OPTIONAL_MODULES:-}"
  local module
  local -a parsed=()
  local -A seen=()

  [[ -n "${raw}" ]] || return 0
  raw="${raw//,/ }"

  for module in ${raw}; do
    [[ -n "${module}" ]] || continue
    optional_module_profile "${module}" >/dev/null \
      || die "Unknown optional module '${module}'. Allowed modules: ${OPTIONAL_MODULES[*]}"
    if [[ -z "${seen[${module}]:-}" ]]; then
      parsed+=("${module}")
      seen["${module}"]=1
    fi
  done

  printf '%s\n' "${parsed[@]}"
}

validate_optional_request_file() {
  local module="$1"
  local request_file="${AGENTIC_ROOT}/deployments/optional/${module}.request"

  [[ -f "${request_file}" ]] || die "Optional module '${module}' requires request file: ${request_file}"
  grep -Eq '^need=[^[:space:]].+$' "${request_file}" \
    || die "Optional module '${module}' request is missing a non-empty 'need=' entry: ${request_file}"
  grep -Eq '^success=[^[:space:]].+$' "${request_file}" \
    || die "Optional module '${module}' request is missing a non-empty 'success=' entry: ${request_file}"
}

validate_optional_module_prereqs() {
  local module="$1"
  local secret_file
  local secret_mode
  local config_file
  local -a secret_files=()
  local -a config_files=()

  validate_optional_request_file "${module}"
  mapfile -t secret_files < <(optional_module_secret_files "${module}") || return 1
  for secret_file in "${secret_files[@]}"; do
    [[ -n "${secret_file}" ]] || continue
    [[ -s "${secret_file}" ]] \
      || die "Optional module '${module}' requires a secret file with mode 600: ${secret_file}"
    secret_mode="$(stat -c '%a' "${secret_file}" 2>/dev/null || echo "")"
    if [[ "${secret_mode}" != "600" && "${secret_mode}" != "640" ]]; then
      die "Optional module '${module}' secret must use restrictive permissions (600/640): ${secret_file} (mode=${secret_mode:-unknown})"
    fi
  done

  mapfile -t config_files < <(optional_module_config_files "${module}") || return 1
  for config_file in "${config_files[@]}"; do
    [[ -n "${config_file}" ]] || continue
    [[ -s "${config_file}" ]] \
      || die "Optional module '${module}' requires runtime config file: ${config_file}"
  done
}

log_optional_activation() {
  local module="$1"
  local request_file="${AGENTIC_ROOT}/deployments/optional/${module}.request"
  local actor="${SUDO_USER:-${USER:-unknown}}"

  append_changes_log "optional module enabled module=${module} actor=${actor} request=${request_file}"
}

append_changes_log() {
  local message="$1"
  local changes_log="${AGENTIC_ROOT}/deployments/changes.log"

  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  touch "${changes_log}"
  chmod 0640 "${changes_log}" || true

  printf '%s %s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${message}" \
    >>"${changes_log}"
}

optional_module_build_services() {
  case "$1" in
    mcp) echo "optional-mcp-catalog" ;;
    git-forge) echo "" ;;
    pi-mono) echo "optional-pi-mono" ;;
    goose) echo "" ;;
    portainer) echo "" ;;
    *) return 1 ;;
  esac
}

optional_module_build_stamp_key() {
  case "$1" in
    optional-mcp-catalog) echo "optional-modules-local" ;;
    optional-pi-mono) echo "agent-cli-base-local" ;;
    *) return 1 ;;
  esac
}

optional_module_image_ref() {
  case "$1" in
    optional-mcp-catalog) echo "agentic/optional-modules:local" ;;
    optional-pi-mono) echo "agentic/agent-cli-base:local" ;;
    *) return 1 ;;
  esac
}

optional_module_build_inputs() {
  case "$1" in
    optional-mcp-catalog)
      printf '%s\n' \
        "${AGENTIC_REPO_ROOT}/deployments/optional/Dockerfile" \
        "${AGENTIC_REPO_ROOT}/deployments/optional/optional_service.py" \
        "${AGENTIC_REPO_ROOT}/deployments/optional/tcp_forward.py"
      ;;
    optional-pi-mono)
      printf '%s\n' \
        "${AGENTIC_REPO_ROOT}/deployments/images/agent-cli-base/Dockerfile" \
        "${AGENTIC_REPO_ROOT}/deployments/images/agent-cli-base/entrypoint.sh" \
        "${AGENTIC_REPO_ROOT}/deployments/images/agent-cli-base/install-agent-clis.sh" \
        "${AGENTIC_REPO_ROOT}/deployments/images/agent-cli-base/agent-cli-wrapper.sh" \
        "${AGENTIC_REPO_ROOT}/deployments/images/agent-cli-base/vibe-wrapper.sh"
      ;;
    *)
      return 1
      ;;
  esac
}

optional_module_build_fingerprint() {
  local service="$1"
  local -a files=()
  local file

  while IFS= read -r file; do
    [[ -n "${file}" ]] || continue
    files+=("${file}")
  done < <(optional_module_build_inputs "${service}")

  [[ "${#files[@]}" -gt 0 ]] || return 1

  require_cmd sha256sum
  for file in "${files[@]}"; do
    [[ -f "${file}" ]] || die "optional build input missing for ${service}: ${file}"
  done

  (
    for file in "${files[@]}"; do
      sha256sum "${file}"
    done
  ) | sha256sum | awk '{print $1}'
}

build_optional_module_images() {
  local optional_compose_file="$1"
  shift
  local -a modules=("$@")
  local -a build_services=()
  local -a build_stamp_paths=()
  local -a build_fingerprints=()
  local -A seen_services=()
  local -A seen_stamp_keys=()
  local module
  local service
  local stamp_key
  local image_ref
  local fingerprint
  local stamp_dir
  local stamp_path
  local stamp_value

  [[ "${AGENTIC_SKIP_OPTIONAL_IMAGE_BUILD:-0}" == "1" ]] && {
    warn "skipping optional local image build because AGENTIC_SKIP_OPTIONAL_IMAGE_BUILD=1"
    return 0
  }

  stamp_dir="${AGENTIC_ROOT}/deployments/image-build-stamps"
  install -d -m 0750 "${stamp_dir}"

  require_cmd docker

  for module in "${modules[@]}"; do
    service="$(optional_module_build_services "${module}")" || continue
    [[ -n "${service}" ]] || continue
    if [[ -n "${seen_services[${service}]:-}" ]]; then
      continue
    fi
    seen_services["${service}"]=1

    stamp_key="$(optional_module_build_stamp_key "${service}")" || continue
    if [[ -n "${seen_stamp_keys[${stamp_key}]:-}" ]]; then
      continue
    fi
    seen_stamp_keys["${stamp_key}"]=1

    image_ref="$(optional_module_image_ref "${service}")" || continue
    fingerprint="$(optional_module_build_fingerprint "${service}")" || continue
    stamp_path="${stamp_dir}/${stamp_key}.sha256"
    stamp_value="$(cat "${stamp_path}" 2>/dev/null || true)"

    if ! docker image inspect "${image_ref}" >/dev/null 2>&1 \
      || [[ -z "${stamp_value}" ]] \
      || [[ "${stamp_value}" != "${fingerprint}" ]]; then
      build_services+=("${service}")
      build_stamp_paths+=("${stamp_path}")
      build_fingerprints+=("${fingerprint}")
    fi
  done

  [[ "${#build_services[@]}" -gt 0 ]] || return 0

  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" \
    -f "${optional_compose_file}" build "${build_services[@]}"

  local idx
  for idx in "${!build_services[@]}"; do
    printf '%s\n' "${build_fingerprints[${idx}]}" >"${build_stamp_paths[${idx}]}"
    chmod 0640 "${build_stamp_paths[${idx}]}" || true
  done
}

core_service_build_inputs() {
  case "$1" in
    ollama-gate)
      printf '%s\n' \
        "${AGENTIC_REPO_ROOT}/deployments/gate/Dockerfile" \
        "${AGENTIC_REPO_ROOT}/deployments/gate/requirements.txt" \
        "${AGENTIC_REPO_ROOT}/deployments/gate/app.py"
      ;;
    gate-mcp)
      printf '%s\n' \
        "${AGENTIC_REPO_ROOT}/deployments/gate_mcp/Dockerfile" \
        "${AGENTIC_REPO_ROOT}/deployments/gate_mcp/service.py"
      ;;
    openclaw)
      printf '%s\n' \
        "${AGENTIC_REPO_ROOT}/deployments/optional/Dockerfile" \
        "${AGENTIC_REPO_ROOT}/deployments/optional/optional_service.py" \
        "${AGENTIC_REPO_ROOT}/deployments/optional/openclaw_wrapper.sh" \
        "${AGENTIC_REPO_ROOT}/deployments/optional/openclaw_config_layers.py" \
        "${AGENTIC_REPO_ROOT}/deployments/optional/openclaw_gateway_entrypoint.sh" \
        "${AGENTIC_REPO_ROOT}/deployments/optional/tcp_forward.py"
      ;;
    *)
      return 1
      ;;
  esac
}

core_service_stamp_key() {
  case "$1" in
    ollama-gate) echo "ollama-gate-local" ;;
    gate-mcp) echo "gate-mcp-local" ;;
    openclaw) echo "openclaw-local" ;;
    *) return 1 ;;
  esac
}

core_service_image_ref() {
  case "$1" in
    ollama-gate) echo "agentic/ollama-gate:local" ;;
    gate-mcp) echo "agentic/gate-mcp:local" ;;
    openclaw) echo "agentic/optional-modules:local" ;;
    *) return 1 ;;
  esac
}

core_service_build_fingerprint() {
  local service="$1"
  local -a files=()
  local file

  while IFS= read -r file; do
    [[ -n "${file}" ]] || continue
    files+=("${file}")
  done < <(core_service_build_inputs "${service}")

  [[ "${#files[@]}" -gt 0 ]] || return 1

  require_cmd sha256sum
  for file in "${files[@]}"; do
    [[ -f "${file}" ]] || die "core build input missing for ${service}: ${file}"
  done

  (
    case "${service}" in
      openclaw)
        printf 'openclaw_install_cli_script=%s\n' "${AGENTIC_OPENCLAW_INSTALL_CLI_SCRIPT}"
        printf 'openclaw_install_version=%s\n' "${AGENTIC_OPENCLAW_INSTALL_VERSION}"
        ;;
    esac
    for file in "${files[@]}"; do
      sha256sum "${file}"
    done
  ) | sha256sum | awk '{print $1}'
}

build_core_local_images() {
  local core_compose_file="$1"
  local -a services=(ollama-gate gate-mcp openclaw)
  local -a build_services=()
  local -a build_stamp_paths=()
  local -a build_fingerprints=()
  local service
  local stamp_key
  local image_ref
  local fingerprint
  local stamp_dir
  local stamp_path
  local stamp_value

  [[ "${AGENTIC_SKIP_CORE_IMAGE_BUILD:-0}" == "1" ]] && {
    warn "skipping core local image build because AGENTIC_SKIP_CORE_IMAGE_BUILD=1"
    return 0
  }

  stamp_dir="${AGENTIC_ROOT}/deployments/image-build-stamps"
  install -d -m 0750 "${stamp_dir}"

  require_cmd docker

  for service in "${services[@]}"; do
    stamp_key="$(core_service_stamp_key "${service}")" || continue
    image_ref="$(core_service_image_ref "${service}")" || continue
    fingerprint="$(core_service_build_fingerprint "${service}")" || continue
    stamp_path="${stamp_dir}/${stamp_key}.sha256"
    stamp_value="$(cat "${stamp_path}" 2>/dev/null || true)"

    if ! docker image inspect "${image_ref}" >/dev/null 2>&1 \
      || [[ -z "${stamp_value}" ]] \
      || [[ "${stamp_value}" != "${fingerprint}" ]]; then
      build_services+=("${service}")
      build_stamp_paths+=("${stamp_path}")
      build_fingerprints+=("${fingerprint}")
    fi
  done

  [[ "${#build_services[@]}" -gt 0 ]] || return 0

  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" \
    -f "${core_compose_file}" build "${build_services[@]}"

  local idx
  for idx in "${!build_services[@]}"; do
    printf '%s\n' "${build_fingerprints[${idx}]}" >"${build_stamp_paths[${idx}]}"
    chmod 0640 "${build_stamp_paths[${idx}]}" || true
  done
}

resolve_agent_base_build_services() {
  local agents_compose_file="$1"
  local -a available_services=()
  local -a candidate_services=(agentic-claude agentic-codex agentic-opencode agentic-vibestral)
  local -A available_lookup=()
  local service

  mapfile -t available_services < <(
    docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" \
      -f "${agents_compose_file}" config --services
  )
  for service in "${available_services[@]}"; do
    available_lookup["${service}"]=1
  done

  for service in "${candidate_services[@]}"; do
    if [[ -n "${available_lookup[${service}]:-}" ]]; then
      printf '%s\n' "${service}"
    fi
  done
}

agent_base_build_fingerprint() {
  local context_dir="${AGENTIC_AGENT_BASE_BUILD_CONTEXT}"
  local dockerfile_path="${AGENTIC_AGENT_BASE_DOCKERFILE}"
  local default_dockerfile="${AGENTIC_REPO_ROOT}/deployments/images/agent-cli-base/Dockerfile"
  local default_entrypoint="${AGENTIC_REPO_ROOT}/deployments/images/agent-cli-base/entrypoint.sh"
  local default_install_script="${AGENTIC_REPO_ROOT}/deployments/images/agent-cli-base/install-agent-clis.sh"
  local default_cli_wrapper="${AGENTIC_REPO_ROOT}/deployments/images/agent-cli-base/agent-cli-wrapper.sh"
  local default_vibe_wrapper="${AGENTIC_REPO_ROOT}/deployments/images/agent-cli-base/vibe-wrapper.sh"
  local context_real dockerfile_real default_dockerfile_real

  require_cmd sha256sum

  [[ -d "${context_dir}" ]] || die "agent base build context must exist and be a directory: ${context_dir}"
  [[ -f "${dockerfile_path}" ]] || die "agent base Dockerfile does not exist: ${dockerfile_path}"

  context_real="$(canonicalize_path "${context_dir}")"
  dockerfile_real="$(canonicalize_path "${dockerfile_path}")"
  default_dockerfile_real="$(canonicalize_path "${default_dockerfile}")"

  {
    printf 'image=%s\n' "${AGENTIC_AGENT_BASE_IMAGE}"
    printf 'context=%s\n' "${context_real}"
    printf 'dockerfile=%s\n' "${dockerfile_real}"
    printf 'install_mode=%s\n' "${AGENTIC_AGENT_CLI_INSTALL_MODE}"
    printf 'codex_cli_npm_spec=%s\n' "${AGENTIC_CODEX_CLI_NPM_SPEC}"
    printf 'claude_code_npm_spec=%s\n' "${AGENTIC_CLAUDE_CODE_NPM_SPEC}"
    printf 'opencode_npm_spec=%s\n' "${AGENTIC_OPENCODE_NPM_SPEC}"
    printf 'pi_coding_agent_npm_spec=%s\n' "${AGENTIC_PI_CODING_AGENT_NPM_SPEC}"
    printf 'openhands_install_script=%s\n' "${AGENTIC_OPENHANDS_INSTALL_SCRIPT}"
    printf 'openclaw_install_cli_script=%s\n' "${AGENTIC_OPENCLAW_INSTALL_CLI_SCRIPT}"
    printf 'openclaw_install_version=%s\n' "${AGENTIC_OPENCLAW_INSTALL_VERSION}"
    printf 'vibe_install_script=%s\n' "${AGENTIC_VIBE_INSTALL_SCRIPT}"
    sha256sum "${dockerfile_real}"
    if [[ "${dockerfile_real}" == "${default_dockerfile_real}" ]]; then
      [[ -f "${default_entrypoint}" ]] || die "default agent entrypoint missing: ${default_entrypoint}"
      [[ -f "${default_install_script}" ]] || die "default agent install script missing: ${default_install_script}"
      [[ -f "${default_cli_wrapper}" ]] || die "default agent CLI wrapper missing: ${default_cli_wrapper}"
      [[ -f "${default_vibe_wrapper}" ]] || die "default vibe wrapper missing: ${default_vibe_wrapper}"
      sha256sum "${default_entrypoint}"
      sha256sum "${default_install_script}"
      sha256sum "${default_cli_wrapper}"
      sha256sum "${default_vibe_wrapper}"
    fi
  } | sha256sum | awk '{print $1}'
}

assert_agent_base_image_contract() {
  local image_ref="$1"
  local image_user
  local entrypoint_json

  image_user="$(docker image inspect --format '{{.Config.User}}' "${image_ref}" 2>/dev/null || true)"
  [[ -n "${image_user}" && "${image_user}" != "root" && "${image_user}" != "0" ]] \
    || die "agent base image must use a non-root user: ${image_ref} (user='${image_user:-<empty>}')"

  entrypoint_json="$(docker image inspect --format '{{json .Config.Entrypoint}}' "${image_ref}" 2>/dev/null || true)"
  [[ -n "${entrypoint_json}" && "${entrypoint_json}" != "null" && "${entrypoint_json}" != "[]" ]] \
    || die "agent base image must define an entrypoint compatible with persistent tmux sessions: ${image_ref}"

  timeout 30 docker run --rm --entrypoint sh "${image_ref}" -lc 'command -v bash tmux git curl >/dev/null' \
    || die "agent base image must include bash/tmux/git/curl: ${image_ref}"

  timeout 45 docker run --rm --entrypoint sh "${image_ref}" -lc '
    command -v codex claude opencode pi vibe openhands openclaw >/dev/null
    for cli in codex claude opencode pi vibe openhands openclaw; do
      test -f "/etc/agentic/${cli}-real-path"
    done
  ' || die "agent base image must expose codex/claude/opencode/pi/vibe/openhands/openclaw command contract: ${image_ref}"
}

build_agents_local_images() {
  local agents_compose_file="$1"
  local image_ref="${AGENTIC_AGENT_BASE_IMAGE}"
  local stamp_dir
  local stamp_path
  local stamp_value
  local fingerprint
  local -a build_services=()

  [[ "${AGENTIC_SKIP_AGENT_IMAGE_BUILD:-0}" == "1" ]] && {
    warn "skipping agent base image build because AGENTIC_SKIP_AGENT_IMAGE_BUILD=1"
    return 0
  }

  stamp_dir="${AGENTIC_ROOT}/deployments/image-build-stamps"
  install -d -m 0750 "${stamp_dir}"
  stamp_path="${stamp_dir}/agent-cli-base.sha256"
  stamp_value="$(cat "${stamp_path}" 2>/dev/null || true)"

  require_cmd docker
  fingerprint="$(agent_base_build_fingerprint)"

  if ! docker image inspect "${image_ref}" >/dev/null 2>&1 \
    || [[ -z "${stamp_value}" ]] \
    || [[ "${stamp_value}" != "${fingerprint}" ]]; then
    mapfile -t build_services < <(resolve_agent_base_build_services "${agents_compose_file}")
    [[ "${#build_services[@]}" -gt 0 ]] || return 0

    docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" \
      -f "${agents_compose_file}" build "${build_services[@]}"
    printf '%s\n' "${fingerprint}" >"${stamp_path}"
    chmod 0640 "${stamp_path}" || true
  fi

  assert_agent_base_image_contract "${image_ref}"
}

resolve_update_latest_inputs() {
  local output_dir="$1"
  shift
  local -a compose_files=("$@")

  require_cmd docker
  require_cmd python3
  [[ -f "${AGENT_RELEASE_RESOLVE_LATEST_SCRIPT}" ]] || die "latest resolver script missing: ${AGENT_RELEASE_RESOLVE_LATEST_SCRIPT}"

  local -a cmd=(
    python3 "${AGENT_RELEASE_RESOLVE_LATEST_SCRIPT}"
    --project-name "${AGENTIC_COMPOSE_PROJECT}"
    --output-dir "${output_dir}"
  )
  local compose_file
  for compose_file in "${compose_files[@]}"; do
    cmd+=(-f "${compose_file}")
  done

  "${cmd[@]}"
}

apply_resolved_runtime_env_file() {
  local env_file="$1"
  [[ -f "${env_file}" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    export "${key}=${value}"
  done < "${env_file}"
}

capture_update_resolution_artifacts() {
  local release_id="$1"
  local resolution_dir="$2"
  local release_dir="${AGENTIC_ROOT}/deployments/releases/${release_id}"
  [[ -d "${release_dir}" ]] || die "release directory missing after snapshot: ${release_dir}"

  local artifact
  for artifact in latest-resolution.json runtime.resolved.env compose.resolved.override.yml; do
    [[ -f "${resolution_dir}/${artifact}" ]] || continue
    install -m 0640 "${resolution_dir}/${artifact}" "${release_dir}/${artifact}"
  done
}

service_container_id() {
  local service="$1"
  docker ps \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.ID}}' | head -n 1
}

service_container_any_id() {
  local service="$1"
  docker ps -a \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.ID}}' | head -n 1
}

wait_for_service_ready() {
  local service="$1"
  local timeout_seconds="${2:-90}"
  local elapsed=0
  local container_id=""
  local state="missing"
  local health=""

  require_cmd docker

  while (( elapsed < timeout_seconds )); do
    container_id="$(service_container_any_id "${service}")"
    if [[ -n "${container_id}" ]]; then
      state="$(docker inspect --format '{{.State.Status}}' "${container_id}" 2>/dev/null || echo unknown)"
      health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${container_id}" 2>/dev/null || true)"
      if [[ "${state}" == "running" ]]; then
        if [[ -z "${health}" || "${health}" == "healthy" ]]; then
          return 0
        fi
      fi
    else
      state="missing"
      health=""
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  warn "service '${service}' did not become ready within ${timeout_seconds}s (state=${state}, health=${health:-n/a})"
  return 1
}

target_status_from_services() {
  local target="$1"
  local -a services=()
  local service container_id current_state aggregate_state=""

  mapfile -t services < <(target_to_services "${target}") || return 1
  [[ "${#services[@]}" -gt 0 ]] || return 1

  for service in "${services[@]}"; do
    container_id="$(service_container_any_id "${service}")"
    if [[ -z "${container_id}" ]]; then
      current_state="missing"
    else
      current_state="$(docker inspect --format '{{.State.Status}}' "${container_id}" 2>/dev/null || echo unknown)"
    fi

    if [[ -z "${aggregate_state}" ]]; then
      aggregate_state="${current_state}"
    elif [[ "${aggregate_state}" != "${current_state}" ]]; then
      printf '%s\n' "mixed"
      return 0
    fi
  done

  printf '%s\n' "${aggregate_state:-missing}"
}

existing_compose_files() {
  local -a ordered_targets=(core agents ui obs rag optional)
  local target
  local compose_file
  for target in "${ordered_targets[@]}"; do
    compose_file="$(stack_to_compose_file "$target")"
    if [[ -f "${compose_file}" ]]; then
      printf '%s\n' "${compose_file}"
    fi
  done
}

load_runtime_env() {
  [[ -f "${AGENT_RUNTIME_ENV_FILE}" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" != \#* ]] || continue
    [[ "${line}" == *=* ]] || continue

    key="${line%%=*}"
    value="${line#*=}"
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    case "${key}" in
      OLLAMA_CONTAINER_MODELS_PATH)
        if [[ "${AGENTIC_PROFILE}" != "rootless-dev" ]]; then
          export "${key}=${value}"
        fi
        ;;
      COMPOSE_PROFILES|AGENTIC_LLM_NETWORK|AGENTIC_LLM_MODE|AGENTIC_LLM_BACKEND|AGENTIC_LLM_BACKEND_SWITCH_COOLDOWN_SECONDS|GATE_ENABLE_TEST_MODE|AGENTIC_OPENAI_DAILY_TOKENS|AGENTIC_OPENAI_MONTHLY_TOKENS|AGENTIC_OPENAI_DAILY_REQUESTS|AGENTIC_OPENAI_MONTHLY_REQUESTS|AGENTIC_OPENROUTER_DAILY_TOKENS|AGENTIC_OPENROUTER_MONTHLY_TOKENS|AGENTIC_OPENROUTER_DAILY_REQUESTS|AGENTIC_OPENROUTER_MONTHLY_REQUESTS|GATE_MCP_RATE_LIMIT_RPS|GATE_MCP_RATE_LIMIT_BURST|GATE_MCP_HTTP_TIMEOUT_SEC|AGENTIC_DOCKER_USER_SOURCE_NETWORKS|AGENTIC_OLLAMA_MODELS_LINK|AGENTIC_OLLAMA_MODELS_TARGET_DIR|AGENTIC_AGENT_WORKSPACES_ROOT|AGENTIC_CLAUDE_WORKSPACES_DIR|AGENTIC_CODEX_WORKSPACES_DIR|AGENTIC_OPENCODE_WORKSPACES_DIR|AGENTIC_VIBESTRAL_WORKSPACES_DIR|AGENTIC_OPENHANDS_WORKSPACES_DIR|AGENTIC_OPENCLAW_WORKSPACES_DIR|AGENTIC_PI_MONO_WORKSPACES_DIR|AGENTIC_GOOSE_WORKSPACES_DIR|OLLAMA_MODELS_DIR|OLLAMA_CONTAINER_USER|QDRANT_CONTAINER_USER|GATE_CONTAINER_USER|TRTLLM_CONTAINER_USER|PROMETHEUS_CONTAINER_USER|GRAFANA_CONTAINER_USER|LOKI_CONTAINER_USER|PROMTAIL_CONTAINER_USER|AGENTIC_DEFAULT_MODEL|AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW|AGENTIC_GOOSE_CONTEXT_LIMIT|OLLAMA_CONTEXT_LENGTH|OLLAMA_MODELS_MOUNT_MODE|OLLAMA_PRELOAD_GENERATE_MODEL|OLLAMA_PRELOAD_EMBED_MODEL|OLLAMA_MODEL_STORE_BUDGET_GB|RAG_EMBED_MODEL|TRTLLM_MODELS|TRTLLM_NATIVE_MODEL_POLICY|TRTLLM_NVFP4_LOCAL_MODEL_DIR|TRTLLM_NVFP4_HF_REPO|TRTLLM_NVFP4_HF_REVISION|TRTLLM_NVFP4_PREPARE_ENABLED|AGENTIC_OBS_RETENTION_TIME|AGENTIC_OBS_MAX_DISK|AGENTIC_PROMETHEUS_DISK_BUDGET|AGENTIC_LOKI_DISK_BUDGET|PROMETHEUS_RETENTION_TIME|PROMETHEUS_RETENTION_SIZE|LOKI_RETENTION_PERIOD|LOKI_MAX_QUERY_LOOKBACK|PROMTAIL_DOCKER_CONTAINERS_HOST_PATH|PROMTAIL_HOST_LOG_PATH|NODE_EXPORTER_HOST_ROOT_PATH|CADVISOR_HOST_ROOT_PATH|CADVISOR_DOCKER_LIB_HOST_PATH|CADVISOR_SYS_HOST_PATH|CADVISOR_DEV_DISK_HOST_PATH|AGENTIC_AGENT_BASE_BUILD_CONTEXT|AGENTIC_AGENT_BASE_DOCKERFILE|AGENTIC_AGENT_BASE_IMAGE|AGENTIC_AGENT_CLI_INSTALL_MODE|AGENTIC_AGENT_NO_NEW_PRIVILEGES|AGENTIC_CODEX_CLI_NPM_SPEC|AGENTIC_CLAUDE_CODE_NPM_SPEC|AGENTIC_OPENCODE_NPM_SPEC|AGENTIC_PI_CODING_AGENT_NPM_SPEC|AGENTIC_OPENHANDS_INSTALL_SCRIPT|AGENTIC_OPENCLAW_INSTALL_CLI_SCRIPT|AGENTIC_OPENCLAW_INSTALL_VERSION|AGENTIC_VIBE_INSTALL_SCRIPT|AGENTIC_LIMIT_DEFAULT_CPUS|AGENTIC_LIMIT_DEFAULT_MEM|AGENTIC_LIMIT_CORE_CPUS|AGENTIC_LIMIT_CORE_MEM|AGENTIC_LIMIT_AGENTS_CPUS|AGENTIC_LIMIT_AGENTS_MEM|AGENTIC_LIMIT_UI_CPUS|AGENTIC_LIMIT_UI_MEM|AGENTIC_LIMIT_OBS_CPUS|AGENTIC_LIMIT_OBS_MEM|AGENTIC_LIMIT_RAG_CPUS|AGENTIC_LIMIT_RAG_MEM|AGENTIC_LIMIT_OPTIONAL_CPUS|AGENTIC_LIMIT_OPTIONAL_MEM|AGENTIC_LIMIT_*)
        export "${key}=${value}"
        ;;
      *)
        ;;
    esac
  done < "${AGENT_RUNTIME_ENV_FILE}"

  if [[ "${AGENTIC_AGENT_BASE_BUILD_CONTEXT}" != /* ]]; then
    AGENTIC_AGENT_BASE_BUILD_CONTEXT="${AGENTIC_REPO_ROOT}/${AGENTIC_AGENT_BASE_BUILD_CONTEXT}"
    export AGENTIC_AGENT_BASE_BUILD_CONTEXT
  fi
  if [[ "${AGENTIC_AGENT_BASE_DOCKERFILE}" != /* ]]; then
    AGENTIC_AGENT_BASE_DOCKERFILE="${AGENTIC_REPO_ROOT}/${AGENTIC_AGENT_BASE_DOCKERFILE}"
    export AGENTIC_AGENT_BASE_DOCKERFILE
  fi
  if [[ "${AGENTIC_AGENT_NO_NEW_PRIVILEGES}" != "true" && "${AGENTIC_AGENT_NO_NEW_PRIVILEGES}" != "false" ]]; then
    warn "invalid AGENTIC_AGENT_NO_NEW_PRIVILEGES='${AGENTIC_AGENT_NO_NEW_PRIVILEGES}', defaulting to true"
    AGENTIC_AGENT_NO_NEW_PRIVILEGES="true"
    export AGENTIC_AGENT_NO_NEW_PRIVILEGES
  fi

  local legacy_openclaw_workspaces_dir="${AGENTIC_ROOT}/optional/openclaw/workspaces"
  local canonical_openclaw_workspaces_dir="${AGENTIC_ROOT}/openclaw/workspaces"
  if [[ "${AGENTIC_OPENCLAW_WORKSPACES_DIR}" == "${legacy_openclaw_workspaces_dir}" ]]; then
    warn "migrating legacy AGENTIC_OPENCLAW_WORKSPACES_DIR to ${canonical_openclaw_workspaces_dir}"
    AGENTIC_OPENCLAW_WORKSPACES_DIR="${canonical_openclaw_workspaces_dir}"
    export AGENTIC_OPENCLAW_WORKSPACES_DIR
  fi
}

set_runtime_env_value() {
  local key="$1"
  local value="$2"

  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  touch "${AGENT_RUNTIME_ENV_FILE}"
  chmod 0640 "${AGENT_RUNTIME_ENV_FILE}" || true

  if grep -Eq "^${key}=" "${AGENT_RUNTIME_ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|g" "${AGENT_RUNTIME_ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${AGENT_RUNTIME_ENV_FILE}"
  fi
}

ensure_runtime_env() {
  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  touch "${AGENT_RUNTIME_ENV_FILE}"
  chmod 0640 "${AGENT_RUNTIME_ENV_FILE}"

  local -a keys=(
    "AGENTIC_PROFILE=${AGENTIC_PROFILE}"
    "AGENTIC_ROOT=${AGENTIC_ROOT}"
    "AGENTIC_AGENT_WORKSPACES_ROOT=${AGENTIC_AGENT_WORKSPACES_ROOT}"
    "AGENTIC_CLAUDE_WORKSPACES_DIR=${AGENTIC_CLAUDE_WORKSPACES_DIR}"
    "AGENTIC_CODEX_WORKSPACES_DIR=${AGENTIC_CODEX_WORKSPACES_DIR}"
    "AGENTIC_OPENCODE_WORKSPACES_DIR=${AGENTIC_OPENCODE_WORKSPACES_DIR}"
    "AGENTIC_VIBESTRAL_WORKSPACES_DIR=${AGENTIC_VIBESTRAL_WORKSPACES_DIR}"
    "AGENTIC_OPENHANDS_WORKSPACES_DIR=${AGENTIC_OPENHANDS_WORKSPACES_DIR}"
    "AGENTIC_OPENCLAW_WORKSPACES_DIR=${AGENTIC_OPENCLAW_WORKSPACES_DIR}"
    "AGENTIC_OPENCLAW_INIT_PROJECT=${AGENTIC_OPENCLAW_INIT_PROJECT}"
    "AGENTIC_PI_MONO_WORKSPACES_DIR=${AGENTIC_PI_MONO_WORKSPACES_DIR}"
    "AGENTIC_GOOSE_WORKSPACES_DIR=${AGENTIC_GOOSE_WORKSPACES_DIR}"
    "AGENTIC_COMPOSE_PROJECT=${AGENTIC_COMPOSE_PROJECT}"
    "COMPOSE_PROFILES=${COMPOSE_PROFILES:-}"
    "AGENTIC_NETWORK=${AGENTIC_NETWORK}"
    "AGENTIC_LLM_NETWORK=${AGENTIC_LLM_NETWORK}"
    "AGENTIC_AGENT_BASE_BUILD_CONTEXT=${AGENTIC_AGENT_BASE_BUILD_CONTEXT}"
    "AGENTIC_AGENT_BASE_DOCKERFILE=${AGENTIC_AGENT_BASE_DOCKERFILE}"
    "AGENTIC_AGENT_BASE_IMAGE=${AGENTIC_AGENT_BASE_IMAGE}"
    "AGENTIC_AGENT_CLI_INSTALL_MODE=${AGENTIC_AGENT_CLI_INSTALL_MODE}"
    "AGENTIC_AGENT_NO_NEW_PRIVILEGES=${AGENTIC_AGENT_NO_NEW_PRIVILEGES}"
    "AGENTIC_CODEX_CLI_NPM_SPEC=${AGENTIC_CODEX_CLI_NPM_SPEC}"
    "AGENTIC_CLAUDE_CODE_NPM_SPEC=${AGENTIC_CLAUDE_CODE_NPM_SPEC}"
    "AGENTIC_OPENCODE_NPM_SPEC=${AGENTIC_OPENCODE_NPM_SPEC}"
    "AGENTIC_PI_CODING_AGENT_NPM_SPEC=${AGENTIC_PI_CODING_AGENT_NPM_SPEC}"
    "AGENTIC_OPENHANDS_INSTALL_SCRIPT=${AGENTIC_OPENHANDS_INSTALL_SCRIPT}"
    "AGENTIC_OPENCLAW_INSTALL_CLI_SCRIPT=${AGENTIC_OPENCLAW_INSTALL_CLI_SCRIPT}"
    "AGENTIC_OPENCLAW_INSTALL_VERSION=${AGENTIC_OPENCLAW_INSTALL_VERSION}"
    "AGENTIC_VIBE_INSTALL_SCRIPT=${AGENTIC_VIBE_INSTALL_SCRIPT}"
    "AGENTIC_LLM_MODE=${AGENTIC_LLM_MODE}"
    "AGENTIC_LLM_BACKEND=${AGENTIC_LLM_BACKEND}"
    "AGENTIC_LLM_BACKEND_SWITCH_COOLDOWN_SECONDS=${AGENTIC_LLM_BACKEND_SWITCH_COOLDOWN_SECONDS}"
    "GATE_ENABLE_TEST_MODE=${GATE_ENABLE_TEST_MODE:-0}"
    "AGENTIC_OPENAI_DAILY_TOKENS=${AGENTIC_OPENAI_DAILY_TOKENS}"
    "AGENTIC_OPENAI_MONTHLY_TOKENS=${AGENTIC_OPENAI_MONTHLY_TOKENS}"
    "AGENTIC_OPENAI_DAILY_REQUESTS=${AGENTIC_OPENAI_DAILY_REQUESTS}"
    "AGENTIC_OPENAI_MONTHLY_REQUESTS=${AGENTIC_OPENAI_MONTHLY_REQUESTS}"
    "AGENTIC_OPENROUTER_DAILY_TOKENS=${AGENTIC_OPENROUTER_DAILY_TOKENS}"
    "AGENTIC_OPENROUTER_MONTHLY_TOKENS=${AGENTIC_OPENROUTER_MONTHLY_TOKENS}"
    "AGENTIC_OPENROUTER_DAILY_REQUESTS=${AGENTIC_OPENROUTER_DAILY_REQUESTS}"
    "AGENTIC_OPENROUTER_MONTHLY_REQUESTS=${AGENTIC_OPENROUTER_MONTHLY_REQUESTS}"
    "GATE_MCP_RATE_LIMIT_RPS=${GATE_MCP_RATE_LIMIT_RPS}"
    "GATE_MCP_RATE_LIMIT_BURST=${GATE_MCP_RATE_LIMIT_BURST}"
    "GATE_MCP_HTTP_TIMEOUT_SEC=${GATE_MCP_HTTP_TIMEOUT_SEC}"
    "AGENTIC_EGRESS_NETWORK=${AGENTIC_EGRESS_NETWORK}"
    "AGENTIC_DOCKER_USER_SOURCE_NETWORKS=${AGENTIC_DOCKER_USER_SOURCE_NETWORKS}"
    "AGENTIC_OLLAMA_MODELS_LINK=${AGENTIC_OLLAMA_MODELS_LINK}"
    "AGENTIC_OLLAMA_MODELS_TARGET_DIR=${AGENTIC_OLLAMA_MODELS_TARGET_DIR:-}"
    "OLLAMA_MODELS_DIR=${OLLAMA_MODELS_DIR}"
    "OLLAMA_CONTAINER_MODELS_PATH=${OLLAMA_CONTAINER_MODELS_PATH}"
    "OLLAMA_CONTAINER_USER=${OLLAMA_CONTAINER_USER}"
    "QDRANT_CONTAINER_USER=${QDRANT_CONTAINER_USER}"
    "GATE_CONTAINER_USER=${GATE_CONTAINER_USER}"
    "TRTLLM_CONTAINER_USER=${TRTLLM_CONTAINER_USER}"
    "PROMETHEUS_CONTAINER_USER=${PROMETHEUS_CONTAINER_USER}"
    "GRAFANA_CONTAINER_USER=${GRAFANA_CONTAINER_USER}"
    "LOKI_CONTAINER_USER=${LOKI_CONTAINER_USER}"
    "PROMTAIL_CONTAINER_USER=${PROMTAIL_CONTAINER_USER}"
    "AGENTIC_DEFAULT_MODEL=${AGENTIC_DEFAULT_MODEL}"
    "AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW=${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW}"
    "AGENTIC_GOOSE_CONTEXT_LIMIT=${AGENTIC_GOOSE_CONTEXT_LIMIT}"
    "OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}"
    "OLLAMA_MODELS_MOUNT_MODE=${OLLAMA_MODELS_MOUNT_MODE}"
    "OLLAMA_PRELOAD_GENERATE_MODEL=${OLLAMA_PRELOAD_GENERATE_MODEL}"
    "OLLAMA_PRELOAD_EMBED_MODEL=${OLLAMA_PRELOAD_EMBED_MODEL}"
    "OLLAMA_MODEL_STORE_BUDGET_GB=${OLLAMA_MODEL_STORE_BUDGET_GB}"
    "RAG_EMBED_MODEL=${RAG_EMBED_MODEL}"
    "TRTLLM_MODELS=${TRTLLM_MODELS}"
    "TRTLLM_NATIVE_MODEL_POLICY=${TRTLLM_NATIVE_MODEL_POLICY}"
    "TRTLLM_NVFP4_LOCAL_MODEL_DIR=${TRTLLM_NVFP4_LOCAL_MODEL_DIR}"
    "TRTLLM_NVFP4_HF_REPO=${TRTLLM_NVFP4_HF_REPO}"
    "TRTLLM_NVFP4_HF_REVISION=${TRTLLM_NVFP4_HF_REVISION}"
    "TRTLLM_NVFP4_PREPARE_ENABLED=${TRTLLM_NVFP4_PREPARE_ENABLED}"
    "AGENTIC_OBS_RETENTION_TIME=${AGENTIC_OBS_RETENTION_TIME}"
    "AGENTIC_OBS_MAX_DISK=${AGENTIC_OBS_MAX_DISK}"
    "AGENTIC_PROMETHEUS_DISK_BUDGET=${AGENTIC_PROMETHEUS_DISK_BUDGET}"
    "AGENTIC_LOKI_DISK_BUDGET=${AGENTIC_LOKI_DISK_BUDGET}"
    "PROMETHEUS_RETENTION_TIME=${PROMETHEUS_RETENTION_TIME}"
    "PROMETHEUS_RETENTION_SIZE=${PROMETHEUS_RETENTION_SIZE}"
    "LOKI_RETENTION_PERIOD=${LOKI_RETENTION_PERIOD}"
    "LOKI_MAX_QUERY_LOOKBACK=${LOKI_MAX_QUERY_LOOKBACK}"
    "PROMTAIL_DOCKER_CONTAINERS_HOST_PATH=${PROMTAIL_DOCKER_CONTAINERS_HOST_PATH}"
    "PROMTAIL_HOST_LOG_PATH=${PROMTAIL_HOST_LOG_PATH}"
    "NODE_EXPORTER_HOST_ROOT_PATH=${NODE_EXPORTER_HOST_ROOT_PATH}"
    "CADVISOR_HOST_ROOT_PATH=${CADVISOR_HOST_ROOT_PATH}"
    "CADVISOR_DOCKER_LIB_HOST_PATH=${CADVISOR_DOCKER_LIB_HOST_PATH}"
    "CADVISOR_SYS_HOST_PATH=${CADVISOR_SYS_HOST_PATH}"
    "CADVISOR_DEV_DISK_HOST_PATH=${CADVISOR_DEV_DISK_HOST_PATH}"
    "AGENTIC_LIMIT_DEFAULT_CPUS=${AGENTIC_LIMIT_DEFAULT_CPUS}"
    "AGENTIC_LIMIT_DEFAULT_MEM=${AGENTIC_LIMIT_DEFAULT_MEM}"
    "AGENTIC_LIMIT_CORE_CPUS=${AGENTIC_LIMIT_CORE_CPUS}"
    "AGENTIC_LIMIT_CORE_MEM=${AGENTIC_LIMIT_CORE_MEM}"
    "AGENTIC_LIMIT_OLLAMA_MEM=${AGENTIC_LIMIT_OLLAMA_MEM}"
    "AGENTIC_LIMIT_AGENTS_CPUS=${AGENTIC_LIMIT_AGENTS_CPUS}"
    "AGENTIC_LIMIT_AGENTS_MEM=${AGENTIC_LIMIT_AGENTS_MEM}"
    "AGENTIC_LIMIT_UI_CPUS=${AGENTIC_LIMIT_UI_CPUS}"
    "AGENTIC_LIMIT_UI_MEM=${AGENTIC_LIMIT_UI_MEM}"
    "AGENTIC_LIMIT_OPENHANDS_MEM=${AGENTIC_LIMIT_OPENHANDS_MEM}"
    "AGENTIC_LIMIT_COMFYUI_MEM=${AGENTIC_LIMIT_COMFYUI_MEM}"
    "AGENTIC_LIMIT_OBS_CPUS=${AGENTIC_LIMIT_OBS_CPUS}"
    "AGENTIC_LIMIT_OBS_MEM=${AGENTIC_LIMIT_OBS_MEM}"
    "AGENTIC_LIMIT_RAG_CPUS=${AGENTIC_LIMIT_RAG_CPUS}"
    "AGENTIC_LIMIT_RAG_MEM=${AGENTIC_LIMIT_RAG_MEM}"
    "AGENTIC_LIMIT_OPTIONAL_CPUS=${AGENTIC_LIMIT_OPTIONAL_CPUS}"
    "AGENTIC_LIMIT_OPTIONAL_MEM=${AGENTIC_LIMIT_OPTIONAL_MEM}"
  )

  local kv key
  for kv in "${keys[@]}"; do
    key="${kv%%=*}"
    if grep -Eq "^${key}=" "${AGENT_RUNTIME_ENV_FILE}"; then
      sed -i "s#^${key}=.*#${kv}#g" "${AGENT_RUNTIME_ENV_FILE}"
    else
      printf '%s\n' "${kv}" >>"${AGENT_RUNTIME_ENV_FILE}"
    fi
  done
}

cmd_profile() {
  printf 'profile=%s\n' "${AGENTIC_PROFILE}"
  printf 'root=%s\n' "${AGENTIC_ROOT}"
  printf 'agent_workspaces_root=%s\n' "${AGENTIC_AGENT_WORKSPACES_ROOT}"
  printf 'claude_workspaces_dir=%s\n' "${AGENTIC_CLAUDE_WORKSPACES_DIR}"
  printf 'codex_workspaces_dir=%s\n' "${AGENTIC_CODEX_WORKSPACES_DIR}"
  printf 'opencode_workspaces_dir=%s\n' "${AGENTIC_OPENCODE_WORKSPACES_DIR}"
  printf 'vibestral_workspaces_dir=%s\n' "${AGENTIC_VIBESTRAL_WORKSPACES_DIR}"
  printf 'openhands_workspaces_dir=%s\n' "${AGENTIC_OPENHANDS_WORKSPACES_DIR}"
  printf 'openclaw_workspaces_dir=%s\n' "${AGENTIC_OPENCLAW_WORKSPACES_DIR}"
  printf 'pi_mono_workspaces_dir=%s\n' "${AGENTIC_PI_MONO_WORKSPACES_DIR}"
  printf 'goose_workspaces_dir=%s\n' "${AGENTIC_GOOSE_WORKSPACES_DIR}"
  printf 'compose_project=%s\n' "${AGENTIC_COMPOSE_PROJECT}"
  printf 'network=%s\n' "${AGENTIC_NETWORK}"
  printf 'llm_network=%s\n' "${AGENTIC_LLM_NETWORK}"
  printf 'agent_base_build_context=%s\n' "${AGENTIC_AGENT_BASE_BUILD_CONTEXT}"
  printf 'agent_base_dockerfile=%s\n' "${AGENTIC_AGENT_BASE_DOCKERFILE}"
  printf 'agent_base_image=%s\n' "${AGENTIC_AGENT_BASE_IMAGE}"
  printf 'agent_cli_install_mode=%s\n' "${AGENTIC_AGENT_CLI_INSTALL_MODE}"
  printf 'agent_no_new_privileges=%s\n' "${AGENTIC_AGENT_NO_NEW_PRIVILEGES}"
  printf 'codex_cli_npm_spec=%s\n' "${AGENTIC_CODEX_CLI_NPM_SPEC}"
  printf 'claude_code_npm_spec=%s\n' "${AGENTIC_CLAUDE_CODE_NPM_SPEC}"
  printf 'opencode_npm_spec=%s\n' "${AGENTIC_OPENCODE_NPM_SPEC}"
  printf 'pi_coding_agent_npm_spec=%s\n' "${AGENTIC_PI_CODING_AGENT_NPM_SPEC}"
  printf 'openhands_install_script=%s\n' "${AGENTIC_OPENHANDS_INSTALL_SCRIPT}"
  printf 'openclaw_install_cli_script=%s\n' "${AGENTIC_OPENCLAW_INSTALL_CLI_SCRIPT}"
  printf 'openclaw_install_version=%s\n' "${AGENTIC_OPENCLAW_INSTALL_VERSION}"
  printf 'vibe_install_script=%s\n' "${AGENTIC_VIBE_INSTALL_SCRIPT}"
  printf 'llm_mode=%s\n' "${AGENTIC_LLM_MODE}"
  printf 'llm_backend=%s\n' "${AGENTIC_LLM_BACKEND}"
  printf 'llm_backend_switch_cooldown_seconds=%s\n' "${AGENTIC_LLM_BACKEND_SWITCH_COOLDOWN_SECONDS}"
  printf 'gate_test_mode=%s\n' "${GATE_ENABLE_TEST_MODE:-0}"
  printf 'egress_network=%s\n' "${AGENTIC_EGRESS_NETWORK}"
  printf 'openai_daily_tokens=%s\n' "${AGENTIC_OPENAI_DAILY_TOKENS}"
  printf 'openai_monthly_tokens=%s\n' "${AGENTIC_OPENAI_MONTHLY_TOKENS}"
  printf 'openai_daily_requests=%s\n' "${AGENTIC_OPENAI_DAILY_REQUESTS}"
  printf 'openai_monthly_requests=%s\n' "${AGENTIC_OPENAI_MONTHLY_REQUESTS}"
  printf 'openrouter_daily_tokens=%s\n' "${AGENTIC_OPENROUTER_DAILY_TOKENS}"
  printf 'openrouter_monthly_tokens=%s\n' "${AGENTIC_OPENROUTER_MONTHLY_TOKENS}"
  printf 'openrouter_daily_requests=%s\n' "${AGENTIC_OPENROUTER_DAILY_REQUESTS}"
  printf 'openrouter_monthly_requests=%s\n' "${AGENTIC_OPENROUTER_MONTHLY_REQUESTS}"
  printf 'gate_mcp_rate_limit_rps=%s\n' "${GATE_MCP_RATE_LIMIT_RPS}"
  printf 'gate_mcp_rate_limit_burst=%s\n' "${GATE_MCP_RATE_LIMIT_BURST}"
  printf 'gate_mcp_http_timeout_sec=%s\n' "${GATE_MCP_HTTP_TIMEOUT_SEC}"
  printf 'docker_user_source_networks=%s\n' "${AGENTIC_DOCKER_USER_SOURCE_NETWORKS}"
  printf 'ollama_models_dir=%s\n' "${OLLAMA_MODELS_DIR}"
  printf 'ollama_models_link=%s\n' "${AGENTIC_OLLAMA_MODELS_LINK}"
  printf 'ollama_models_target_dir=%s\n' "${AGENTIC_OLLAMA_MODELS_TARGET_DIR:-}"
  printf 'ollama_container_models_path=%s\n' "${OLLAMA_CONTAINER_MODELS_PATH}"
  printf 'ollama_container_user=%s\n' "${OLLAMA_CONTAINER_USER}"
  printf 'qdrant_container_user=%s\n' "${QDRANT_CONTAINER_USER}"
  printf 'gate_container_user=%s\n' "${GATE_CONTAINER_USER}"
  printf 'trtllm_container_user=%s\n' "${TRTLLM_CONTAINER_USER}"
  printf 'prometheus_container_user=%s\n' "${PROMETHEUS_CONTAINER_USER}"
  printf 'grafana_container_user=%s\n' "${GRAFANA_CONTAINER_USER}"
  printf 'loki_container_user=%s\n' "${LOKI_CONTAINER_USER}"
  printf 'promtail_container_user=%s\n' "${PROMTAIL_CONTAINER_USER}"
  printf 'default_model=%s\n' "${AGENTIC_DEFAULT_MODEL}"
  printf 'default_model_context_window=%s\n' "${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW}"
  printf 'goose_context_limit=%s\n' "${AGENTIC_GOOSE_CONTEXT_LIMIT}"
  printf 'ollama_context_length=%s\n' "${OLLAMA_CONTEXT_LENGTH}"
  printf 'ollama_models_mount_mode=%s\n' "${OLLAMA_MODELS_MOUNT_MODE}"
  printf 'ollama_preload_generate_model=%s\n' "${OLLAMA_PRELOAD_GENERATE_MODEL}"
  printf 'ollama_preload_embed_model=%s\n' "${OLLAMA_PRELOAD_EMBED_MODEL}"
  printf 'ollama_model_store_budget_gb=%s\n' "${OLLAMA_MODEL_STORE_BUDGET_GB}"
  printf 'rag_embed_model=%s\n' "${RAG_EMBED_MODEL}"
  printf 'obs_retention_time=%s\n' "${AGENTIC_OBS_RETENTION_TIME}"
  printf 'obs_max_disk=%s\n' "${AGENTIC_OBS_MAX_DISK}"
  printf 'prometheus_disk_budget=%s\n' "${AGENTIC_PROMETHEUS_DISK_BUDGET}"
  printf 'loki_disk_budget=%s\n' "${AGENTIC_LOKI_DISK_BUDGET}"
  printf 'prometheus_retention_time=%s\n' "${PROMETHEUS_RETENTION_TIME}"
  printf 'prometheus_retention_size=%s\n' "${PROMETHEUS_RETENTION_SIZE}"
  printf 'loki_retention_period=%s\n' "${LOKI_RETENTION_PERIOD}"
  printf 'loki_max_query_lookback=%s\n' "${LOKI_MAX_QUERY_LOOKBACK}"
  printf 'promtail_docker_containers_host_path=%s\n' "${PROMTAIL_DOCKER_CONTAINERS_HOST_PATH}"
  printf 'promtail_host_log_path=%s\n' "${PROMTAIL_HOST_LOG_PATH}"
  printf 'node_exporter_host_root_path=%s\n' "${NODE_EXPORTER_HOST_ROOT_PATH}"
  printf 'cadvisor_host_root_path=%s\n' "${CADVISOR_HOST_ROOT_PATH}"
  printf 'cadvisor_docker_lib_host_path=%s\n' "${CADVISOR_DOCKER_LIB_HOST_PATH}"
  printf 'cadvisor_sys_host_path=%s\n' "${CADVISOR_SYS_HOST_PATH}"
  printf 'cadvisor_dev_disk_host_path=%s\n' "${CADVISOR_DEV_DISK_HOST_PATH}"
  printf 'limit_default_cpus=%s\n' "${AGENTIC_LIMIT_DEFAULT_CPUS}"
  printf 'limit_default_mem=%s\n' "${AGENTIC_LIMIT_DEFAULT_MEM}"
  printf 'limit_core_cpus=%s\n' "${AGENTIC_LIMIT_CORE_CPUS}"
  printf 'limit_core_mem=%s\n' "${AGENTIC_LIMIT_CORE_MEM}"
  printf 'limit_ollama_mem=%s\n' "${AGENTIC_LIMIT_OLLAMA_MEM}"
  printf 'limit_agents_cpus=%s\n' "${AGENTIC_LIMIT_AGENTS_CPUS}"
  printf 'limit_agents_mem=%s\n' "${AGENTIC_LIMIT_AGENTS_MEM}"
  printf 'limit_ui_cpus=%s\n' "${AGENTIC_LIMIT_UI_CPUS}"
  printf 'limit_ui_mem=%s\n' "${AGENTIC_LIMIT_UI_MEM}"
  printf 'limit_openhands_mem=%s\n' "${AGENTIC_LIMIT_OPENHANDS_MEM}"
  printf 'limit_comfyui_mem=%s\n' "${AGENTIC_LIMIT_COMFYUI_MEM}"
  printf 'limit_obs_cpus=%s\n' "${AGENTIC_LIMIT_OBS_CPUS}"
  printf 'limit_obs_mem=%s\n' "${AGENTIC_LIMIT_OBS_MEM}"
  printf 'limit_rag_cpus=%s\n' "${AGENTIC_LIMIT_RAG_CPUS}"
  printf 'limit_rag_mem=%s\n' "${AGENTIC_LIMIT_RAG_MEM}"
  printf 'limit_optional_cpus=%s\n' "${AGENTIC_LIMIT_OPTIONAL_CPUS}"
  printf 'limit_optional_mem=%s\n' "${AGENTIC_LIMIT_OPTIONAL_MEM}"
  printf 'skip_docker_user_apply=%s\n' "${AGENTIC_SKIP_DOCKER_USER_APPLY:-0}"
  printf 'skip_docker_user_check=%s\n' "${AGENTIC_SKIP_DOCKER_USER_CHECK:-0}"
  printf 'skip_doctor_proxy_check=%s\n' "${AGENTIC_SKIP_DOCTOR_PROXY_CHECK:-0}"
}

run_compose_on_targets() {
  local action="$1"
  local target_arg="$2"
  shift 2
  local -a compose_args=()
  local -a profile_args=()
  local -a selected_targets=()
  local compose_file

  local target
  for target in $(parse_targets "$target_arg"); do
    selected_targets+=("${target}")
    compose_file="$(stack_to_compose_file "$target")"
    [[ -f "$compose_file" ]] || die "Compose file not found for target '$target': $compose_file"
    compose_args+=("-f" "$compose_file")
  done

  if targets_include optional "${selected_targets[@]}"; then
    profile_args+=("--profile" "optional")
  fi

  require_cmd docker
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" "${profile_args[@]}" "${compose_args[@]}" "$action" "$@"
}

down_rag_compose_with_profiles() {
  local rag_compose_file
  rag_compose_file="$(stack_to_compose_file rag)"
  [[ -f "${rag_compose_file}" ]] || die "Compose file not found for rag stack: ${rag_compose_file}"

  require_cmd docker
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" \
    --profile rag-lexical \
    -f "${rag_compose_file}" down
}

ensure_core_runtime() {
  if [[ "${AGENTIC_PROFILE}" == "rootless-dev" ]]; then
    [[ -x "${AGENT_OLLAMA_LINK_SCRIPT}" ]] || die "missing script: ${AGENT_OLLAMA_LINK_SCRIPT}"
    if ! "${AGENT_OLLAMA_LINK_SCRIPT}" --quiet >/tmp/agent-ollama-link.out 2>&1; then
      cat /tmp/agent-ollama-link.out >&2
      die "failed to initialize rootless ollama models symlink"
    fi
    OLLAMA_MODELS_DIR="$(sed -n 's/^OLLAMA_MODELS_DIR=//p' /tmp/agent-ollama-link.out | tail -n 1)"
    [[ -n "${OLLAMA_MODELS_DIR}" ]] || die "rootless ollama models link script did not return OLLAMA_MODELS_DIR"
    export OLLAMA_MODELS_DIR
  fi

  if ! "${AGENTIC_REPO_ROOT}/deployments/core/init_runtime.sh"; then
    die "failed to initialize core runtime in ${AGENTIC_ROOT}; re-run with sudo or set AGENTIC_ROOT to a writable path"
  fi
}

ensure_agents_runtime() {
  if ! "${AGENTIC_REPO_ROOT}/deployments/agents/init_runtime.sh"; then
    die "failed to initialize agents runtime in ${AGENTIC_ROOT}; re-run with sudo or set AGENTIC_ROOT to a writable path"
  fi
}

ensure_obs_runtime() {
  if ! "${AGENTIC_REPO_ROOT}/deployments/obs/init_runtime.sh"; then
    die "failed to initialize obs runtime in ${AGENTIC_ROOT}; re-run with sudo or set AGENTIC_ROOT to a writable path"
  fi
}

ensure_ui_runtime() {
  if ! "${AGENTIC_REPO_ROOT}/deployments/ui/init_runtime.sh"; then
    die "failed to initialize ui runtime in ${AGENTIC_ROOT}; re-run with sudo or set AGENTIC_ROOT to a writable path"
  fi
}

ensure_rag_runtime() {
  if ! "${AGENTIC_REPO_ROOT}/deployments/rag/init_runtime.sh"; then
    die "failed to initialize rag runtime in ${AGENTIC_ROOT}; re-run with sudo or set AGENTIC_ROOT to a writable path"
  fi
}

ensure_optional_runtime() {
  if ! "${AGENTIC_REPO_ROOT}/deployments/optional/init_runtime.sh"; then
    die "failed to initialize optional runtime in ${AGENTIC_ROOT}; re-run with sudo or set AGENTIC_ROOT to a writable path"
  fi
}

apply_core_network_policy() {
  if [[ "${AGENTIC_SKIP_DOCKER_USER_APPLY:-0}" == "1" ]]; then
    warn "skipping DOCKER-USER policy apply because AGENTIC_SKIP_DOCKER_USER_APPLY=1"
    return 0
  fi
  if ! "${AGENTIC_REPO_ROOT}/deployments/net/apply_docker_user.sh"; then
    die "failed to apply DOCKER-USER policy; re-run with sudo or set AGENTIC_SKIP_DOCKER_USER_APPLY=1 for local dry-runs"
  fi
}

detect_project_name() {
  local project
  if [[ -n "${AGENT_PROJECT_NAME:-}" ]]; then
    project="${AGENT_PROJECT_NAME}"
  elif project_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    project="$(basename "${project_root}")"
  else
    project="$(basename "${PWD}")"
  fi

  project="${project// /-}"
  project="${project//[^a-zA-Z0-9._-]/-}"
  printf '%s\n' "${project}"
}

bootstrap_container_bash_home() {
  local container_id="$1"
  local home_dir="$2"

  docker exec "${container_id}" sh -lc "
    home_dir='${home_dir}'
    mkdir -p \"\${home_dir}\" \"\${home_dir}/.config\" \"\${home_dir}/.cache\" \"\${home_dir}/.local/bin\"
    if [ ! -f \"\${home_dir}/.bash_profile\" ]; then
      printf '%s\n' \
        'if [ -f \"\${HOME}/.bashrc\" ]; then' \
        '  . \"\${HOME}/.bashrc\"' \
        'fi' >\"\${home_dir}/.bash_profile\"
    fi
    if [ ! -f \"\${home_dir}/.bashrc\" ]; then
      printf '%s\n' 'export PATH=\"\${HOME}/.local/bin:\${PATH}\"' >\"\${home_dir}/.bashrc\"
    elif ! grep -Eq '/\\.local/bin' \"\${home_dir}/.bashrc\"; then
      printf '%s\n' 'export PATH=\"\${HOME}/.local/bin:\${PATH}\"' >>\"\${home_dir}/.bashrc\"
    fi
    chmod 0700 \"\${home_dir}\" \"\${home_dir}/.config\" \"\${home_dir}/.cache\" 2>/dev/null || true
    chmod 0755 \"\${home_dir}/.local\" \"\${home_dir}/.local/bin\" 2>/dev/null || true
    chmod 0600 \"\${home_dir}/.bash_profile\" \"\${home_dir}/.bashrc\" 2>/dev/null || true
  "
}

prepare_tool_session() {
  local tool="$1"
  local project="$2"
  local service container_id workspace defaults_file session_mode

  service="$(tool_to_service "${tool}")" || die "Unknown tool '${tool}'"
  container_id="$(service_container_id "${service}")"
  [[ -n "${container_id}" ]] || die "Service '${service}' is not running. Start it with: $(service_start_hint "${service}")"

  workspace=""
  defaults_file="/state/bootstrap/ollama-gate-defaults.env"
  session_mode="$(tool_session_mode "${tool}")"

  case "${session_mode}" in
    tmux|goose-direct)
      workspace="/workspace/${project}"
      docker exec "${container_id}" sh -lc "mkdir -p '${workspace}'"
      ;;
    openclaw-shell)
      workspace="/workspace/${project}"
      docker exec "${container_id}" sh -lc "mkdir -p '${workspace}'"
      ;;
    *)
      die "Unknown session mode '${session_mode}' for tool '${tool}'"
      ;;
  esac

  case "${session_mode}" in
    tmux)
      if ! docker exec "${container_id}" tmux has-session -t "${tool}" >/dev/null 2>&1; then
        docker exec "${container_id}" tmux new-session -d -s "${tool}" -c "${workspace}" \
          "bash -lc 'if [ -f \"${defaults_file}\" ]; then source \"${defaults_file}\"; fi; exec bash -l'"
      fi
      docker exec "${container_id}" sh -lc "tmux send-keys -t '${tool}' C-c"
      docker exec "${container_id}" sh -lc "tmux send-keys -t '${tool}' 'cd \"${workspace}\"' C-m"
      ;;
    goose-direct)
      ;;
    openclaw-shell)
      docker exec "${container_id}" sh -lc "command -v openclaw >/dev/null" \
        || die "openclaw CLI is missing in openclaw container"
      bootstrap_container_bash_home "${container_id}" "/state/cli/openclaw-home"
      ;;
    *)
      die "Unknown session mode '${session_mode}' for tool '${tool}'"
      ;;
  esac
}

cmd_tool_attach() {
  local tool="$1"
  local project="${2:-$(detect_project_name)}"
  local service container_id session_mode workspace

  prepare_tool_session "${tool}" "${project}"
  service="$(tool_to_service "${tool}")"
  container_id="$(service_container_id "${service}")"
  session_mode="$(tool_session_mode "${tool}")"
  workspace=""
  if [[ "${session_mode}" == "tmux" || "${session_mode}" == "goose-direct" ]]; then
    workspace="/workspace/${project}"
  elif [[ "${session_mode}" == "openclaw-shell" ]]; then
    workspace="/workspace/${project}"
  fi

  case "${session_mode}" in
    tmux)
      printf 'INFO: %s uses a persistent tmux session. Detach with Ctrl-b d (session keeps running).\n' "${tool}"
      printf 'INFO: you are attaching to an existing shell in-container (not auto-running %s).\n' "${tool}"
      printf 'INFO: attach reset sends Ctrl-c, then cd to /workspace/%s; a running foreground command in that pane will be interrupted.\n' "${project}"
      printf 'INFO: use "exit" to close the pane/session; entrypoint will recreate an empty shell session automatically.\n'
      ;;
    goose-direct)
      printf 'INFO: goose uses a direct Goose CLI session (no tmux in optional-goose image).\n'
      printf 'INFO: launching goose in %s; stop with Ctrl-c.\n' "${workspace}"
      ;;
    openclaw-shell)
      printf 'INFO: openclaw uses the core OpenClaw service shell (project workspace mounted).\n'
      printf 'INFO: session workspace is %s.\n' "${workspace}"
      printf 'INFO: OpenClaw API is reachable via host loopback on http://127.0.0.1:%s.\n' "${OPENCLAW_WEBHOOK_HOST_PORT:-18111}"
      printf 'INFO: internal docker-network endpoint is http://openclaw:8111.\n'
      printf 'INFO: OpenClaw dashboard is available at http://127.0.0.1:%s/dashboard.\n' "${OPENCLAW_WEBHOOK_HOST_PORT:-18111}"
      printf 'INFO: OpenClaw upstream Web UI is available at http://127.0.0.1:%s/.\n' "${OPENCLAW_GATEWAY_HOST_PORT:-18789}"
      printf 'INFO: OpenClaw upstream Gateway WS is ws://127.0.0.1:%s.\n' "${OPENCLAW_GATEWAY_HOST_PORT:-18789}"
      printf 'INFO: provider relay ingress is available at http://127.0.0.1:%s/v1/providers/<provider>/webhook.\n' "${OPENCLAW_RELAY_HOST_PORT:-18112}"
      printf 'INFO: OpenClaw onboarding SecretRef expects OPENCLAW_GATEWAY_TOKEN to be set in this shell.\n'
      printf 'INFO: run: export OPENCLAW_GATEWAY_TOKEN="$(tr -d '\\''\\n'\\'' </run/secrets/openclaw.token)"\n'
      ;;
    *)
      die "Unknown session mode '${session_mode}' for tool '${tool}'"
      ;;
  esac

  if [[ "${AGENT_NO_ATTACH:-0}" == "1" ]]; then
    printf 'prepared tool=%s project=%s container=%s\n' "${tool}" "${project}" "${container_id}"
    return 0
  fi

  case "${session_mode}" in
    tmux)
      exec docker exec -it "${container_id}" tmux attach-session -t "${tool}"
      ;;
    goose-direct)
      exec docker exec -it "${container_id}" sh -lc "cd '${workspace}' && exec goose"
      ;;
    openclaw-shell)
      exec docker exec -it "${container_id}" sh -lc "export HOME='/state/cli/openclaw-home'; cd '${workspace}' && exec bash -l"
      ;;
    *)
      die "Unknown session mode '${session_mode}' for tool '${tool}'"
      ;;
  esac
}

sticky_model_for_session() {
  local session_name="$1"
  local sticky_file="${AGENTIC_ROOT}/gate/state/sticky_sessions.json"

  if [[ ! -f "${sticky_file}" ]]; then
    printf '%s\n' "-"
    return 0
  fi

  python3 - "${sticky_file}" "${session_name}" <<'PY'
import json
import sys

path = sys.argv[1]
session = sys.argv[2]

try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print("-")
    raise SystemExit(0)

value = data.get(session)
if isinstance(value, str) and value:
    print(value)
else:
    print("-")
PY
}

openclaw_runtime_summary() {
  local registry_file="${AGENTIC_ROOT}/openclaw/sandbox/state/session-sandboxes.json"
  local operator_registry_file="${AGENTIC_ROOT}/openclaw/sandbox/state/openclaw-state-registry.v1.json"

  if [[ -s "${operator_registry_file}" ]]; then
    python3 - "${operator_registry_file}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("invalid-registry")
    raise SystemExit(0)

if not isinstance(payload, dict):
    print("invalid-registry")
    raise SystemExit(0)

sandboxes = payload.get("sandboxes")
sessions = payload.get("sessions")
if not isinstance(sandboxes, dict) or not isinstance(sessions, dict):
    print("invalid-registry")
    raise SystemExit(0)

active_sessions = [
    record
    for record in sessions.values()
    if isinstance(record, dict) and bool(record.get("active"))
]
current_session = str(payload.get("current_session_id", "")).strip() or "-"
default_session = str(payload.get("default_session_id", "")).strip() or "-"
default_model = str(payload.get("default_model", "")).strip() or "-"
provider = str(payload.get("provider", "")).strip() or "-"

print(
    ";".join(
        [
            f"sandboxes={len(sandboxes)}",
            f"sessions={len(active_sessions)}",
            f"current={current_session}",
            f"default_session={default_session}",
            f"default_model={default_model}",
            f"provider={provider}",
        ]
    )
)
PY
    return 0
  fi

  if [[ ! -s "${registry_file}" ]]; then
    printf '%s\n' "-"
    return 0
  fi

  python3 - "${registry_file}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("invalid-registry")
    raise SystemExit(0)

sandboxes = payload.get("sandboxes")
if not isinstance(sandboxes, dict):
    print("invalid-registry")
    raise SystemExit(0)

print(f"sandboxes={len(sandboxes)}")
PY
}

cmd_ls() {
  require_cmd docker

  printf 'tool\tservice\tstatus\ttmux\tworkspace\tsticky_model\truntime\n'

  local target service container_id status tmux_status workspace_size sticky runtime session_mode
  for target in "${AGENT_STATUS_TARGETS[@]}"; do
    service="$(target_to_services "${target}" | head -n 1)"
    container_id="$(service_container_any_id "${service}")"
    session_mode="$(target_session_mode "${target}" 2>/dev/null || printf '%s\n' "n/a")"

    status="$(target_status_from_services "${target}" 2>/dev/null || printf '%s\n' "missing")"
    if [[ "${session_mode}" == "tmux" ]]; then
      tmux_status="-"
    else
      tmux_status="n/a"
    fi
    if [[ -n "${container_id}" && "${session_mode}" == "tmux" && "${status}" == "running" ]]; then
      if docker exec "${container_id}" tmux has-session -t "${target}" >/dev/null 2>&1; then
        tmux_status="up"
      else
        tmux_status="missing"
      fi
    fi

    local workspace_host_dir
    workspace_host_dir="$(target_workspace_dir "${target}" 2>/dev/null || true)"
    if [[ -d "${workspace_host_dir}" ]]; then
      workspace_size="$(du -sh "${workspace_host_dir}" 2>/dev/null | awk '{print $1}')"
      workspace_size="${workspace_size:-0B}"
    else
      workspace_size="n/a"
    fi

    sticky="-"
    case "${target}" in
      claude|codex|opencode|vibestral|openclaw|pi-mono|goose)
        sticky="$(sticky_model_for_session "${target}")"
        ;;
    esac
    runtime="-"
    if [[ "${target}" == "openclaw" ]]; then
      runtime="$(openclaw_runtime_summary)"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${target}" "${service}" "${status}" "${tmux_status}" "${workspace_size}" "${sticky}" "${runtime}"
  done
}

cmd_status() {
  require_cmd docker

  printf 'service\tcontainer\tstate\thealth\timage\n'

  docker ps -a \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --format '{{.Label "com.docker.compose.service"}}\t{{.Names}}\t{{.State}}\t{{.Status}}\t{{.Image}}' \
    | sort
}

cmd_stop_target() {
  local target="${1:-}"
  local compose_file
  local -a services_to_stop=()
  [[ -n "${target}" ]] || die "Usage: agent stop <target>"

  mapfile -t services_to_stop < <(target_to_services "${target}") \
    || die "Unknown stop/start target '${target}'. Expected one of: ${STOP_START_TARGETS[*]}"
  compose_file="$(target_to_compose_file "${target}")" \
    || die "Unknown stop/start target '${target}'. Expected one of: ${STOP_START_TARGETS[*]}"
  [[ -f "${compose_file}" ]] || die "Compose file not found for tool stack: ${compose_file}"

  require_cmd docker
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" -f "${compose_file}" stop "${services_to_stop[@]}"
}

cmd_start_target() {
  local target="${1:-}"
  local compose_file
  local -a services_to_start=()
  [[ -n "${target}" ]] || die "Usage: agent start <target>"

  mapfile -t services_to_start < <(target_to_services "${target}") \
    || die "Unknown stop/start target '${target}'. Expected one of: ${STOP_START_TARGETS[*]}"
  compose_file="$(target_to_compose_file "${target}")" \
    || die "Unknown stop/start target '${target}'. Expected one of: ${STOP_START_TARGETS[*]}"
  [[ -f "${compose_file}" ]] || die "Compose file not found for tool stack: ${compose_file}"

  require_cmd docker
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" -f "${compose_file}" up -d --no-deps "${services_to_start[@]}"
}

cmd_service_action() {
  local action="$1"
  shift
  local -a services=("$@")
  local service
  local -a container_ids=()
  local container_id

  [[ "${#services[@]}" -gt 0 ]] || die "Usage: agent ${action} service <service...>"

  require_cmd docker
  for service in "${services[@]}"; do
    mapfile -t container_ids < <(
      docker ps -a \
        --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
        --filter "label=com.docker.compose.service=${service}" \
        --format '{{.ID}}'
    )
    [[ "${#container_ids[@]}" -gt 0 ]] || die "Service '${service}' is not present in compose project '${AGENTIC_COMPOSE_PROJECT}'"

    for container_id in "${container_ids[@]}"; do
      docker "${action}" "${container_id}" >/dev/null
      printf '%s service=%s container=%s\n' "${action}" "${service}" "${container_id}"
    done
  done
}

resolve_project_container() {
  local identifier="$1"
  local container_id label_project

  require_cmd docker

  if docker inspect "${identifier}" >/dev/null 2>&1; then
    label_project="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "${identifier}" 2>/dev/null || true)"
    [[ "${label_project}" == "${AGENTIC_COMPOSE_PROJECT}" ]] \
      || die "Container '${identifier}' is not part of compose project '${AGENTIC_COMPOSE_PROJECT}'"
    docker inspect --format '{{.Id}}' "${identifier}"
    return 0
  fi

  container_id="$(docker ps -a \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --filter "name=^/${identifier}$" \
    --format '{{.ID}}' | head -n 1)"
  [[ -n "${container_id}" ]] || die "Container '${identifier}' not found in compose project '${AGENTIC_COMPOSE_PROJECT}'"
  printf '%s\n' "${container_id}"
}

cmd_container_action() {
  local action="$1"
  shift
  local -a containers=("$@")
  local item resolved_id

  [[ "${#containers[@]}" -gt 0 ]] || die "Usage: agent ${action} container <container...>"

  for item in "${containers[@]}"; do
    resolved_id="$(resolve_project_container "${item}")"
    docker "${action}" "${resolved_id}" >/dev/null
    printf '%s container=%s\n' "${action}" "${resolved_id}"
  done
}

cmd_stack() {
  local action="${1:-}"
  local target_arg="${2:-all}"
  local selected_raw
  local -a selected_targets=()
  local -a order=()
  local target

  case "${action}" in
    start|stop) ;;
    *)
      die "Usage: agent stack <start|stop> <core|agents|ui|obs|rag|optional|all>"
      ;;
  esac

  if [[ "${target_arg}" == "all" ]]; then
    selected_raw="$(stack_all_targets)"
  else
    selected_raw="$(parse_targets "${target_arg}")"
  fi
  read -r -a selected_targets <<<"${selected_raw}"
  [[ "${#selected_targets[@]}" -gt 0 ]] || die "No stack targets selected"

  for target in "${selected_targets[@]}"; do
    stack_to_compose_file "${target}" >/dev/null
  done

  if [[ "${action}" == "start" ]]; then
    order=("${STACK_START_ORDER[@]}")
  else
    order=("${STACK_STOP_ORDER[@]}")
  fi

  for target in "${order[@]}"; do
    if ! targets_include "${target}" "${selected_targets[@]}"; then
      continue
    fi

    printf 'stack step=%s target=%s\n' "${action}" "${target}"
    if [[ "${action}" == "start" ]]; then
      "${0}" up "${target}"
    else
      "${0}" down "${target}"
    fi
  done
}

forget_target_paths() {
  local target="$1"
  case "${target}" in
    ollama)
      printf '%s\n' "${AGENTIC_ROOT}/ollama"
      ;;
    claude|codex|opencode|vibestral)
      printf '%s\n' \
        "${AGENTIC_ROOT}/${target}/state" \
        "${AGENTIC_ROOT}/${target}/logs" \
        "$(agent_workspace_dir "${target}")"
      ;;
    comfyui)
      printf '%s\n' "${AGENTIC_ROOT}/comfyui"
      ;;
    openclaw)
      printf '%s\n' \
        "${AGENTIC_ROOT}/openclaw/config" \
        "${AGENTIC_ROOT}/openclaw/state" \
        "${AGENTIC_OPENCLAW_WORKSPACES_DIR}" \
        "${AGENTIC_ROOT}/openclaw/relay" \
        "${AGENTIC_ROOT}/openclaw/logs" \
        "${AGENTIC_ROOT}/openclaw/sandbox/state"
      ;;
    openhands)
      printf '%s\n' \
        "${AGENTIC_ROOT}/openhands/state" \
        "${AGENTIC_ROOT}/openhands/logs" \
        "${AGENTIC_OPENHANDS_WORKSPACES_DIR}"
      ;;
    openwebui)
      printf '%s\n' "${AGENTIC_ROOT}/openwebui/data"
      ;;
    qdrant)
      printf '%s\n' \
        "${AGENTIC_ROOT}/rag/qdrant" \
        "${AGENTIC_ROOT}/rag/qdrant-snapshots"
      ;;
    obs)
      printf '%s\n' \
        "${AGENTIC_ROOT}/monitoring/prometheus" \
        "${AGENTIC_ROOT}/monitoring/grafana" \
        "${AGENTIC_ROOT}/monitoring/loki" \
        "${AGENTIC_ROOT}/monitoring/promtail/positions"
      ;;
    all)
      printf '%s\n' \
        "${AGENTIC_ROOT}/ollama" \
        "${AGENTIC_ROOT}/claude" \
        "${AGENTIC_ROOT}/codex" \
        "${AGENTIC_ROOT}/opencode" \
        "${AGENTIC_ROOT}/vibestral" \
        "$(agent_workspace_dir "claude")" \
        "$(agent_workspace_dir "codex")" \
        "$(agent_workspace_dir "opencode")" \
        "$(agent_workspace_dir "vibestral")" \
        "${AGENTIC_ROOT}/comfyui" \
        "${AGENTIC_ROOT}/openclaw" \
        "${AGENTIC_OPENCLAW_WORKSPACES_DIR}" \
        "${AGENTIC_PI_MONO_WORKSPACES_DIR}" \
        "${AGENTIC_GOOSE_WORKSPACES_DIR}" \
        "${AGENTIC_ROOT}/openhands" \
        "${AGENTIC_OPENHANDS_WORKSPACES_DIR}" \
        "${AGENTIC_ROOT}/openwebui" \
        "${AGENTIC_ROOT}/rag/qdrant" \
        "${AGENTIC_ROOT}/rag/qdrant-snapshots" \
        "${AGENTIC_ROOT}/monitoring/prometheus" \
        "${AGENTIC_ROOT}/monitoring/grafana" \
        "${AGENTIC_ROOT}/monitoring/loki" \
        "${AGENTIC_ROOT}/monitoring/promtail/positions"
      ;;
    *)
      return 1
      ;;
  esac
}

forget_target_services() {
  local target="$1"
  case "${target}" in
    ollama) printf '%s\n' ollama ollama-gate gate-mcp trtllm ;;
    claude) printf '%s\n' agentic-claude ;;
    codex) printf '%s\n' agentic-codex ;;
    opencode) printf '%s\n' agentic-opencode ;;
    vibestral) printf '%s\n' agentic-vibestral ;;
    comfyui) printf '%s\n' comfyui comfyui-loopback ;;
    openclaw) printf '%s\n' openclaw openclaw-gateway openclaw-provider-bridge openclaw-sandbox openclaw-relay ;;
    openhands) printf '%s\n' openhands ;;
    openwebui) printf '%s\n' openwebui ;;
    qdrant) printf '%s\n' qdrant rag-retriever rag-worker opensearch ;;
    obs) printf '%s\n' prometheus grafana loki promtail node-exporter cadvisor dcgm-exporter ;;
    all)
      printf '%s\n' \
        openclaw openclaw-gateway openclaw-provider-bridge openclaw-sandbox \
        openclaw-relay \
        qdrant rag-retriever rag-worker opensearch \
        prometheus grafana loki promtail node-exporter cadvisor dcgm-exporter \
        openwebui openhands comfyui comfyui-loopback \
        agentic-claude agentic-codex agentic-opencode agentic-vibestral \
        ollama ollama-gate gate-mcp trtllm
      ;;
    *)
      return 1
      ;;
  esac
}

forget_target_init_scripts() {
  local target="$1"
  case "${target}" in
    ollama)
      printf '%s\n' "${AGENTIC_REPO_ROOT}/deployments/core/init_runtime.sh"
      ;;
    claude|codex|opencode|vibestral)
      printf '%s\n' "${AGENTIC_REPO_ROOT}/deployments/agents/init_runtime.sh"
      ;;
    comfyui|openhands|openwebui)
      printf '%s\n' "${AGENTIC_REPO_ROOT}/deployments/ui/init_runtime.sh"
      ;;
    openclaw)
      printf '%s\n' "${AGENTIC_REPO_ROOT}/deployments/optional/init_runtime.sh"
      ;;
    qdrant)
      printf '%s\n' "${AGENTIC_REPO_ROOT}/deployments/rag/init_runtime.sh"
      ;;
    obs)
      printf '%s\n' "${AGENTIC_REPO_ROOT}/deployments/obs/init_runtime.sh"
      ;;
    all)
      printf '%s\n' \
        "${AGENTIC_REPO_ROOT}/deployments/bootstrap/init_fs.sh" \
        "${AGENTIC_REPO_ROOT}/deployments/core/init_runtime.sh" \
        "${AGENTIC_REPO_ROOT}/deployments/agents/init_runtime.sh" \
        "${AGENTIC_REPO_ROOT}/deployments/ui/init_runtime.sh" \
        "${AGENTIC_REPO_ROOT}/deployments/rag/init_runtime.sh" \
        "${AGENTIC_REPO_ROOT}/deployments/obs/init_runtime.sh" \
        "${AGENTIC_REPO_ROOT}/deployments/optional/init_runtime.sh"
      ;;
    *)
      return 1
      ;;
  esac
}

stop_forget_services_best_effort() {
  local -a services=("$@")
  local service
  local container_id

  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0

  for service in "${services[@]}"; do
    container_id="$(docker ps \
      --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
      --filter "label=com.docker.compose.service=${service}" \
      --format '{{.ID}}' | head -n 1)"
    [[ -n "${container_id}" ]] || continue
    if ! docker stop "${container_id}" >/dev/null 2>&1; then
      warn "forget: unable to stop service '${service}' (container=${container_id}); continuing"
    fi
  done
}

purge_directory_contents() {
  local path="$1"
  [[ -n "${path}" ]] || return 0
  path_allowed_for_purge "${path}" \
    || die "refusing to purge path outside allowed runtime workspace roots: ${path}"

  if [[ -L "${path}" ]]; then
    rm -f -- "${path}"
    install -d -m 0750 "${path}"
    return 0
  fi

  if [[ -d "${path}" ]]; then
    find -P "${path}" -mindepth 1 -maxdepth 1 -exec rm -rf --one-file-system -- {} +
  else
    install -d -m 0750 "${path}"
  fi
}

purge_directory_contents_preserving() {
  local path="$1"
  shift || true
  local -a preserved_paths=("$@")
  local child
  local preserve
  local matched=0
  local -a child_preserves=()

  [[ -d "${path}" ]] || {
    install -d -m 0750 "${path}"
    return 0
  }
  path_allowed_for_purge "${path}" \
    || die "refusing to purge path outside allowed runtime workspace roots: ${path}"

  for preserve in "${preserved_paths[@]}"; do
    if [[ "${preserve}" == "${path}" ]]; then
      return 0
    fi
  done

  while IFS= read -r -d '' child; do
    matched=0
    child_preserves=()
    for preserve in "${preserved_paths[@]}"; do
      if [[ "${preserve}" == "${child}" || "${preserve}" == "${child}"/* ]]; then
        matched=1
        child_preserves+=("${preserve}")
      fi
    done

    if [[ "${matched}" -eq 0 ]]; then
      rm -rf --one-file-system -- "${child}"
      continue
    fi

    if [[ -d "${child}" && ! -L "${child}" ]]; then
      purge_directory_contents_preserving "${child}" "${child_preserves[@]}"
    fi
  done < <(find -P "${path}" -mindepth 1 -maxdepth 1 -print0)
}

purge_runtime_root_with_preserved_paths() {
  local root="$1"
  shift || true
  local -a preserved_paths=("$@")

  if [[ "${#preserved_paths[@]}" -eq 0 ]]; then
    purge_runtime_root_symlink_safe "${root}"
    return 0
  fi

  [[ -n "${root}" && "${root}" != "/" ]] || die "Refusing cleanup: invalid runtime root '${root}'"
  [[ -e "${root}" ]] || return 0
  [[ -L "${root}" ]] && die "Refusing cleanup: AGENTIC_ROOT is a symlink: ${root}"
  [[ -d "${root}" ]] || die "Refusing cleanup: AGENTIC_ROOT is not a directory: ${root}"

  if purge_directory_contents_preserving "${root}" "${preserved_paths[@]}"; then
    return 0
  fi

  if [[ "${AGENTIC_PROFILE}" != "rootless-dev" ]]; then
    die "cleanup failed to purge ${root}; rerun with sufficient privileges or repair ownership first"
  fi

  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    die "cleanup failed to purge ${root}; docker helper fallback is unavailable and permission repair is required"
  fi

  warn "cleanup: direct purge failed under rootless-dev, attempting docker helper fallback (ownership/permission drift)"
  local preserve_rel_csv=""
  local preserve
  local rel
  for preserve in "${preserved_paths[@]}"; do
    rel="${preserve#${root}/}"
    if [[ "${rel}" == "${preserve}" ]]; then
      continue
    fi
    if [[ -n "${preserve_rel_csv}" ]]; then
      preserve_rel_csv="${preserve_rel_csv},${rel}"
    else
      preserve_rel_csv="${rel}"
    fi
  done

  if ! docker run --rm --network none \
    -e AGENTIC_CLEANUP_PRESERVE_REL="${preserve_rel_csv}" \
    -v "${root}:/cleanup" \
    "${AGENTIC_CLEANUP_HELPER_IMAGE:-busybox:1.36.1}" \
    sh -lc '
      set -eu
      preserve_csv="${AGENTIC_CLEANUP_PRESERVE_REL:-}"
      preserve_match() {
        target="$1"
        [ -n "${preserve_csv}" ] || return 1
        old_ifs="${IFS}"
        IFS=","
        set -- ${preserve_csv}
        IFS="${old_ifs}"
        for rel in "$@"; do
          [ -n "${rel}" ] || continue
          if [ "${rel}" = "${target}" ] || [ "${rel#${target}/}" != "${rel}" ]; then
            return 0
          fi
        done
        return 1
      }
      purge_dir() {
        dir="$1"
        rel_dir="$2"
        find -P "${dir}" -mindepth 1 -maxdepth 1 -print | while IFS= read -r child; do
          [ -n "${child}" ] || continue
          name="${child##*/}"
          child_rel="${name}"
          if [ -n "${rel_dir}" ]; then
            child_rel="${rel_dir}/${name}"
          fi
          if preserve_match "${child_rel}"; then
            if [ -d "${child}" ] && [ ! -L "${child}" ]; then
              purge_dir "${child}" "${child_rel}"
            fi
          else
            chmod -R u+rwx -- "${child}" >/dev/null 2>&1 || true
            rm -rf -- "${child}"
          fi
        done
      }
      purge_dir /cleanup ""
      chown "'"${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}"'" /cleanup >/dev/null 2>&1 || true
      chmod 0750 /cleanup >/dev/null 2>&1 || true
    '; then
    die "cleanup failed to purge ${root} (helper fallback failed). Try: sudo chown -R $(id -u):$(id -g) '${root}'"
  fi
}

purge_runtime_root_symlink_safe() {
  local root="$1"
  [[ -n "${root}" && "${root}" != "/" ]] || die "Refusing cleanup: invalid runtime root '${root}'"
  [[ -e "${root}" ]] || return 0
  [[ -L "${root}" ]] && die "Refusing cleanup: AGENTIC_ROOT is a symlink: ${root}"
  [[ -d "${root}" ]] || die "Refusing cleanup: AGENTIC_ROOT is not a directory: ${root}"

  if find -P "${root}" -mindepth 1 -maxdepth 1 -exec rm -rf --one-file-system -- {} +; then
    return 0
  fi

  if [[ "${AGENTIC_PROFILE}" != "rootless-dev" ]]; then
    die "cleanup failed to purge ${root}; rerun with sufficient privileges or repair ownership first"
  fi

  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    die "cleanup failed to purge ${root}; docker helper fallback is unavailable and permission repair is required"
  fi

  warn "cleanup: direct purge failed under rootless-dev, attempting docker helper fallback (ownership/permission drift)"
  if ! docker run --rm --network none \
    -v "${root}:/cleanup" \
    "${AGENTIC_CLEANUP_HELPER_IMAGE:-busybox:1.36.1}" \
    sh -lc "set -eu; find -P /cleanup -xdev -mindepth 1 -maxdepth 1 -exec chmod -R u+rwx -- {} + >/dev/null 2>&1 || true; find -P /cleanup -xdev -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; chown '${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}' /cleanup || true; chmod 0750 /cleanup || true"; then
    die "cleanup failed to purge ${root} (helper fallback failed). Try: sudo chown -R $(id -u):$(id -g) '${root}'"
  fi

  if find -P "${root}" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    die "cleanup failed: residual files remain under ${root} after helper fallback"
  fi
}

cleanup_rootless_ollama_models_link() {
  [[ "${AGENTIC_PROFILE}" == "rootless-dev" ]] || return 0

  if [[ -L "${AGENTIC_OLLAMA_MODELS_LINK}" ]]; then
    rm -f -- "${AGENTIC_OLLAMA_MODELS_LINK}"
    printf 'cleanup removed_ollama_models_link=%s\n' "${AGENTIC_OLLAMA_MODELS_LINK}"
    return 0
  fi

  if [[ -e "${AGENTIC_OLLAMA_MODELS_LINK}" ]]; then
    warn "cleanup: expected symlink at AGENTIC_OLLAMA_MODELS_LINK but found non-symlink path '${AGENTIC_OLLAMA_MODELS_LINK}'"
  fi
}

collect_cleanup_image_refs() {
  local -a compose_files=()
  local -a compose_args=()
  local compose_file

  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0

  mapfile -t compose_files < <(existing_compose_files)
  if [[ "${#compose_files[@]}" -gt 0 ]]; then
    for compose_file in "${compose_files[@]}"; do
      compose_args+=("-f" "${compose_file}")
    done
    docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" \
      --profile rag-lexical \
      --profile optional \
      --profile optional-mcp \
      --profile optional-git-forge \
      --profile optional-pi-mono \
      --profile optional-goose \
      --profile optional-portainer \
      "${compose_args[@]}" config --images 2>/dev/null || true
  fi

  docker ps -a \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --format '{{.Image}}' 2>/dev/null || true

  printf '%s\n' \
    "${AGENTIC_AGENT_BASE_IMAGE}" \
    "agentic/ollama-gate:local" \
    "agentic/gate-mcp:local" \
    "agentic/optional-modules:local" \
    "agentic/trtllm-runtime:local" \
    "agentic/comfyui:local" \
    "agentic/openhands:local"
}

remove_cleanup_images_best_effort() {
  local -a image_refs=("$@")
  local image_ref

  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0

  for image_ref in "${image_refs[@]}"; do
    [[ -n "${image_ref}" ]] || continue
    if ! docker image inspect "${image_ref}" >/dev/null 2>&1; then
      continue
    fi
    if docker image rm -f "${image_ref}" >/dev/null 2>&1; then
      printf 'cleanup image removed=%s\n' "${image_ref}"
    else
      warn "cleanup: unable to remove image '${image_ref}' (still in use or protected)"
    fi
  done
}

create_forget_backup() {
  local target="$1"
  shift
  local -a candidate_paths=("$@")
  local -a rel_paths=()
  local path rel
  local ts backup_dir backup_path

  ts="$(date -u +"%Y%m%dT%H%M%SZ")"
  backup_dir="${AGENTIC_ROOT}/deployments/forget-backups"
  backup_path="${backup_dir}/${ts}-${target}.tar.gz"
  install -d -m 0750 "${backup_dir}"

  for path in "${candidate_paths[@]}"; do
    [[ -d "${path}" ]] || continue
    rel="${path#${AGENTIC_ROOT}/}"
    if [[ "${rel}" == "${path}" ]]; then
      continue
    fi
    rel_paths+=("${rel}")
  done

  if [[ "${#rel_paths[@]}" -eq 0 ]]; then
    tar -czf "${backup_path}" --files-from /dev/null
  else
    tar -C "${AGENTIC_ROOT}" -czf "${backup_path}" "${rel_paths[@]}"
  fi

  printf '%s\n' "${backup_path}"
}

cmd_forget() {
  local target="${1:-}"
  local force=0
  local backup_enabled=1
  local answer confirmation
  local actor="${SUDO_USER:-${USER:-unknown}}"
  local changes_log="${AGENTIC_ROOT}/deployments/changes.log"
  local -a paths=()
  local -a services=()
  local -a init_scripts=()
  local path
  local script_path
  local backup_path=""

  [[ -n "${target}" ]] || die "Usage: agent forget <target> [--yes] [--no-backup]"
  shift || true

  case "${target}" in
    ollama|claude|codex|opencode|vibestral|comfyui|openclaw|openhands|openwebui|qdrant|obs|all)
      ;;
    *)
      die "Unknown forget target '${target}'. Expected one of: ${FORGET_TARGETS[*]}"
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes)
        force=1
        shift
        ;;
      --no-backup)
        backup_enabled=0
        shift
        ;;
      -h|--help|help)
        cat <<USAGE
Usage:
  agent forget <target> [--yes] [--no-backup]

Targets:
  ${FORGET_TARGETS[*]}
USAGE
        return 0
        ;;
      *)
        die "Unknown forget argument: $1"
        ;;
    esac
  done

  if [[ "${force}" != "1" ]]; then
    printf "Forget target '%s' will delete persistent data. Continue? [y/N]: " "${target}"
    IFS= read -r answer || die "forget aborted: unable to read confirmation"
    case "${answer}" in
      y|Y|yes|YES) ;;
      *) die "forget aborted: confirmation denied" ;;
    esac

    printf "Type 'yes' to confirm forget target '%s' (default: No): " "${target}"
    IFS= read -r confirmation || die "forget aborted: unable to read final confirmation"
    [[ "${confirmation}" == "yes" ]] || die "forget aborted: final confirmation denied"
  fi

  mapfile -t paths < <(forget_target_paths "${target}")
  mapfile -t services < <(forget_target_services "${target}")
  mapfile -t init_scripts < <(forget_target_init_scripts "${target}")

  if [[ "${backup_enabled}" == "1" ]]; then
    backup_path="$(create_forget_backup "${target}" "${paths[@]}")"
  fi

  stop_forget_services_best_effort "${services[@]}"

  for path in "${paths[@]}"; do
    purge_directory_contents "${path}"
  done

  for script_path in "${init_scripts[@]}"; do
    [[ -x "${script_path}" ]] || die "forget init script missing or not executable: ${script_path}"
    "${script_path}"
  done

  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  touch "${changes_log}"
  chmod 0640 "${changes_log}" || true
  printf '%s forget actor=%s target=%s backup=%s result=ok\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${actor}" "${target}" "${backup_path:-none}" \
    >>"${changes_log}"

  printf 'forget completed target=%s backup=%s\n' "${target}" "${backup_path:-none}"
}

cmd_cleanup() {
  local force="${AGENTIC_CLEANUP_FORCE:-0}"
  local backup_mode="ask"
  local backup_enabled=0
  local purge_models=0
  local answer confirmation confirmation_remove
  local export_dir="${AGENTIC_CLEANUP_EXPORT_DIR:-${AGENTIC_REPO_ROOT}/.runtime/cleanup-exports}"
  local backup_path=""
  local ts target
  local -a selected_targets=()
  local -a cleanup_images=()
  local -a preserved_model_paths=()
  local tmp_log

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes)
        force=1
        shift
        ;;
      --backup)
        backup_mode="yes"
        shift
        ;;
      --no-backup)
        backup_mode="no"
        shift
        ;;
      --purge-models)
        purge_models=1
        shift
        ;;
      -h|--help|help)
        cat <<USAGE
Usage:
  agent cleanup [--yes] [--backup|--no-backup] [--purge-models]
  agent strict-prod cleanup [--yes] [--backup|--no-backup] [--purge-models]
  agent rootless-dev cleanup [--yes] [--backup|--no-backup] [--purge-models]

Description:
  Stop the stack stepwise, optionally export a backup archive, then purge AGENTIC_ROOT
  to bring runtime state back to a fresh/brand-new state. By default cleanup preserves
  local model directories; pass --purge-models to remove them explicitly. Cleanup also
  removes local docker images associated with the stack.
USAGE
        return 0
        ;;
      *)
        die "Unknown cleanup argument: $1"
        ;;
    esac
  done

  [[ -n "${AGENTIC_ROOT}" && "${AGENTIC_ROOT}" != "/" ]] || die "Refusing cleanup: invalid AGENTIC_ROOT='${AGENTIC_ROOT}'"
  if [[ -L "${AGENTIC_ROOT}" ]]; then
    die "Refusing cleanup: AGENTIC_ROOT is a symlink: ${AGENTIC_ROOT}"
  fi

  mapfile -t cleanup_images < <(collect_cleanup_image_refs | awk 'NF {print $0}' | sort -u)

  if [[ "${backup_mode}" == "yes" ]]; then
    backup_enabled=1
  elif [[ "${backup_mode}" == "no" ]]; then
    backup_enabled=0
  else
    printf 'Create backup/export before cleanup? [Y/n]: '
    IFS= read -r answer || die "cleanup aborted: unable to read backup choice"
    case "${answer}" in
      ""|Y|y|yes|YES) backup_enabled=1 ;;
      N|n|no|NO) backup_enabled=0 ;;
      *) die "cleanup aborted: invalid backup choice '${answer}'" ;;
    esac
  fi

  if [[ "${purge_models}" != "1" ]]; then
    mapfile -t preserved_model_paths < <(cleanup_model_paths)
  fi

  if [[ "${force}" != "1" ]]; then
    printf 'Cleanup will remove all runtime files under %s . Type CLEAN to continue: ' "${AGENTIC_ROOT}"
    IFS= read -r confirmation || die "cleanup aborted: confirmation not provided"
    [[ "${confirmation}" == "CLEAN" ]] || die "cleanup aborted: confirmation token mismatch"

    printf "Type remove-every-thing to confirm permanent cleanup of %s: " "${AGENTIC_ROOT}"
    IFS= read -r confirmation_remove || die "cleanup aborted: second confirmation not provided"
    [[ "${confirmation_remove}" == "remove-every-thing" ]] || die "cleanup aborted: second confirmation token mismatch"
  fi

  read -r -a selected_targets <<<"$(stack_all_targets)"
  for target in "${STACK_STOP_ORDER[@]}"; do
    if ! targets_include "${target}" "${selected_targets[@]}"; then
      continue
    fi
    tmp_log="$(mktemp)"
    if ! "${0}" down "${target}" >"${tmp_log}" 2>&1; then
      warn "cleanup: unable to stop target '${target}' cleanly; continuing"
      cat "${tmp_log}" >&2
    fi
    rm -f "${tmp_log}"
  done

  if [[ "${backup_enabled}" == "1" ]]; then
    ts="$(date -u +"%Y%m%dT%H%M%SZ")"
    install -d -m 0750 "${export_dir}"
    backup_path="${export_dir}/agentic-cleanup-${AGENTIC_PROFILE}-${ts}.tar.gz"
    if [[ -d "${AGENTIC_ROOT}" ]]; then
      tar -C "${AGENTIC_ROOT}" -czf "${backup_path}" .
      printf 'cleanup backup=%s\n' "${backup_path}"
    else
      warn "cleanup: runtime root does not exist yet, backup skipped"
    fi
  fi

  purge_runtime_root_with_preserved_paths "${AGENTIC_ROOT}" "${preserved_model_paths[@]}"
  cleanup_rootless_ollama_models_link
  remove_cleanup_images_best_effort "${cleanup_images[@]}"
  install -d -m 0750 "${AGENTIC_ROOT}"

  if [[ "${purge_models}" == "1" ]]; then
    printf 'cleanup completed root=%s models=purged\n' "${AGENTIC_ROOT}"
  else
    printf 'cleanup completed root=%s models=preserved\n' "${AGENTIC_ROOT}"
  fi
}

cmd_ollama_models_status() {
  local configured_mode="${OLLAMA_MODELS_MOUNT_MODE:-rw}"
  local configured_source
  local configured_dest="${OLLAMA_CONTAINER_MODELS_PATH:-/root/.ollama/models}"
  local runtime_dest="${configured_dest}"
  local runtime_mode="unknown"
  local runtime_source=""
  local ollama_cid=""
  local service_state="not-running"
  local mount_entry=""
  local mount_rw=""

  configured_source="$(canonicalize_path "${OLLAMA_MODELS_DIR}")"

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ollama_cid="$(service_container_id "ollama" || true)"
    if [[ -n "${ollama_cid}" ]]; then
      service_state="$(docker inspect --format '{{.State.Status}}' "${ollama_cid}" 2>/dev/null || echo unknown)"
      runtime_dest="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${ollama_cid}" 2>/dev/null | sed -n 's/^OLLAMA_MODELS=//p' | head -n 1)"
      runtime_dest="${runtime_dest:-${configured_dest}}"
      mount_entry="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "'"${runtime_dest}"'"}}{{printf "%s|%v" .Source .RW}}{{end}}{{end}}' "${ollama_cid}" 2>/dev/null || true)"
      if [[ -n "${mount_entry}" ]]; then
        runtime_source="${mount_entry%%|*}"
        mount_rw="${mount_entry##*|}"
        runtime_source="$(canonicalize_path "${runtime_source}")"
        if [[ "${mount_rw}" == "true" ]]; then
          runtime_mode="rw"
        else
          runtime_mode="ro"
        fi
      else
        runtime_mode="missing"
      fi
    fi
  fi

  printf 'ollama_models_mount_mode=%s\n' "${configured_mode}"
  printf 'ollama_models_dir=%s\n' "${configured_source}"
  printf 'ollama_container_models_path=%s\n' "${configured_dest}"
  printf 'ollama_service_state=%s\n' "${service_state}"
  printf 'ollama_models_mount_mode_runtime=%s\n' "${runtime_mode}"

  if [[ -n "${ollama_cid}" ]]; then
    printf 'ollama_container_models_path_runtime=%s\n' "${runtime_dest}"
    if [[ -n "${runtime_source}" ]]; then
      printf 'ollama_models_mount_source_runtime=%s\n' "${runtime_source}"
    fi
    if [[ "${runtime_mode}" != "missing" && "${runtime_mode}" != "${configured_mode}" ]]; then
      warn "ollama models runtime mode (${runtime_mode}) differs from configured mode (${configured_mode}); run: agent ollama-models ${configured_mode}"
    fi
  fi
}

ollama_loaded_models() {
  local ollama_cid="$1"
  local ps_output

  ps_output="$(docker exec "${ollama_cid}" ollama ps 2>&1)" || {
    printf '%s\n' "${ps_output}" >&2
    return 1
  }

  printf '%s\n' "${ps_output}" | awk '
    NR == 1 && $1 == "NAME" { next }
    NF >= 1 { print $1 }
  '
}

cmd_ollama_unload() {
  local model="${1:-}"
  local actor="${SUDO_USER:-${USER:-unknown}}"
  local ollama_cid=""
  local -a loaded_models=()
  local loaded_models_output=""
  local loaded=0
  local loaded_model
  local stop_output=""

  [[ -n "${model}" ]] || die "Usage: agent ollama unload <model>"
  shift || true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help|help)
        cat <<USAGE
Usage:
  agent ollama unload <model>

Description:
  Explicitly unload a local model from the Ollama backend memory.
  Initial backend scope is Ollama only. This command is idempotent:
  if the model is not currently loaded, it returns success with
  result=already-unloaded.
USAGE
        return 0
        ;;
      *)
        die "Unknown ollama unload argument: $1"
        ;;
    esac
  done

  require_cmd docker
  ollama_cid="$(service_container_id "ollama" || true)"
  [[ -n "${ollama_cid}" ]] || die "Ollama backend is not running. Start it with: agent up core"

  loaded_models_output="$(ollama_loaded_models "${ollama_cid}")" \
    || die "Failed to query loaded Ollama models from backend container '${ollama_cid}'"
  if [[ -n "${loaded_models_output}" ]]; then
    mapfile -t loaded_models < <(printf '%s\n' "${loaded_models_output}")
  fi

  for loaded_model in "${loaded_models[@]}"; do
    if [[ "${loaded_model}" == "${model}" ]]; then
      loaded=1
      break
    fi
  done

  if [[ "${loaded}" != "1" ]]; then
    append_changes_log "ollama unload actor=${actor} backend=ollama model=${model} container=${ollama_cid} result=already-unloaded"
    printf 'ollama unload backend=ollama model=%s result=already-unloaded\n' "${model}"
    return 0
  fi

  stop_output="$(docker exec "${ollama_cid}" ollama stop "${model}" 2>&1)" || {
    printf '%s\n' "${stop_output}" >&2
    die "Failed to unload Ollama model '${model}' from backend container '${ollama_cid}'"
  }

  append_changes_log "ollama unload actor=${actor} backend=ollama model=${model} container=${ollama_cid} result=unloaded"
  printf 'ollama unload backend=ollama model=%s result=unloaded\n' "${model}"
}

cmd_ollama() {
  local action="${1:-}"
  shift || true

  case "${action}" in
    unload)
      cmd_ollama_unload "$@"
      ;;
    help|-h|--help)
      printf '%s\n' "Usage: agent ollama unload <model>"
      ;;
    "")
      die "Usage: agent ollama unload <model>"
      ;;
    *)
      die "Usage: agent ollama unload <model>"
      ;;
  esac
}

trtllm_model_prepared() {
  local host_dir

  host_dir="$(agentic_trtllm_nvfp4_host_dir "${TRTLLM_NVFP4_LOCAL_MODEL_DIR}")" || return 1
  [[ -f "${host_dir}/model.safetensors.index.json" ]]
}

run_trtllm_prepare_script() {
  [[ -x "${AGENT_TRTLLM_PREPARE_SCRIPT}" ]] || die "missing script: ${AGENT_TRTLLM_PREPARE_SCRIPT}"
  TRTLLM_NVFP4_PREPARE_ENABLED=true "${AGENT_TRTLLM_PREPARE_SCRIPT}"
}

read_json_field_or_default() {
  local file="$1"
  local key="$2"
  local fallback="$3"

  [[ -f "${file}" ]] || {
    printf '%s\n' "${fallback}"
    return 0
  }

  python3 - "${file}" "${key}" "${fallback}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
fallback = sys.argv[3]

try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print(fallback)
    raise SystemExit(0)

value = payload.get(key, fallback)
if isinstance(value, bool):
    print("true" if value else "false")
elif value in (None, ""):
    print(fallback)
else:
    print(value)
PY
}

cmd_trtllm_status() {
  local runtime_state_file="${AGENTIC_ROOT}/trtllm/state/runtime-state.json"
  local active_url active_local_dir prepared status health runtime_mode native_ready
  local trt_cid=""

  active_url="${TRTLLM_MODELS}"
  active_local_dir="${TRTLLM_NVFP4_LOCAL_MODEL_DIR}"
  if trtllm_model_prepared; then
    prepared="yes"
  else
    prepared="no"
  fi

  status="missing"
  health="-"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    trt_cid="$(service_container_any_id "trtllm" || true)"
    if [[ -n "${trt_cid}" ]]; then
      status="$(docker inspect --format '{{.State.Status}}' "${trt_cid}" 2>/dev/null || printf '%s\n' "unknown")"
      health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "${trt_cid}" 2>/dev/null || printf '%s\n' "-")"
    fi
  fi

  runtime_mode="$(read_json_field_or_default "${runtime_state_file}" "runtime_mode_effective" "-")"
  native_ready="$(read_json_field_or_default "${runtime_state_file}" "native_ready" "-")"

  printf 'trtllm prepared=%s service_state=%s health=%s runtime_mode=%s native_ready=%s\n' \
    "${prepared}" "${status}" "${health}" "${runtime_mode}" "${native_ready}"
  printf 'trtllm model=%s local_dir=%s state=%s\n' "${active_url}" "${active_local_dir}" "${runtime_state_file}"
}

cmd_trtllm_prepare() {
  [[ $# -eq 0 ]] || die "Usage: agent trtllm prepare"
  run_trtllm_prepare_script
  printf 'trtllm prepared=%s local_dir=%s log=%s\n' "${TRTLLM_NVFP4_HF_REPO}" "${TRTLLM_NVFP4_LOCAL_MODEL_DIR}" "${AGENTIC_ROOT}/trtllm/logs/nvfp4-model-prepare.log"
}

cmd_trtllm_start() {
  local compose_file

  [[ $# -eq 0 ]] || die "Usage: agent trtllm start"
  compose_file="$(stack_to_compose_file core)"
  [[ -f "${compose_file}" ]] || die "Compose file not found for core stack: ${compose_file}"

  require_cmd docker
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" -f "${compose_file}" up -d trtllm
  wait_for_service_ready "trtllm" 120 || die "trtllm did not become ready after start"
  cmd_trtllm_status
}

cmd_trtllm_stop() {
  local compose_file

  [[ $# -eq 0 ]] || die "Usage: agent trtllm stop"

  if [[ -z "$(service_container_any_id "trtllm" || true)" ]]; then
    cmd_trtllm_status
    return 0
  fi

  compose_file="$(stack_to_compose_file core)"
  [[ -f "${compose_file}" ]] || die "Compose file not found for core stack: ${compose_file}"

  require_cmd docker
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" -f "${compose_file}" stop trtllm
  cmd_trtllm_status
}

cmd_trtllm() {
  local action="${1:-status}"
  shift || true

  case "${action}" in
    status)
      cmd_trtllm_status "$@"
      ;;
    prepare)
      cmd_trtllm_prepare "$@"
      ;;
    start)
      cmd_trtllm_start "$@"
      ;;
    stop)
      cmd_trtllm_stop "$@"
      ;;
    help|-h|--help)
      cat <<USAGE
Usage:
  agent trtllm status
  agent trtllm prepare
  agent trtllm start
  agent trtllm stop
USAGE
      ;;
    *)
      die "Usage: agent trtllm [status|prepare|start|stop]"
      ;;
  esac
}

cmd_ollama_models() {
  local action="${1:-status}"

  case "${action}" in
    status)
      cmd_ollama_models_status
      ;;
    rw|ro)
      ensure_runtime_env
      ensure_core_runtime
      set_runtime_env_value "OLLAMA_MODELS_MOUNT_MODE" "${action}"
      export OLLAMA_MODELS_MOUNT_MODE="${action}"

      local core_compose_file
      core_compose_file="$(stack_to_compose_file core)"
      [[ -f "${core_compose_file}" ]] || die "Compose file not found for core stack: ${core_compose_file}"

      require_cmd docker
      docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" -f "${core_compose_file}" up -d --force-recreate ollama
      printf 'ollama models mount mode updated to %s\n' "${action}"
      ;;
    *)
      die "Usage: agent ollama-models [status|rw|ro]"
      ;;
  esac
}

cmd_ollama_preload() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "help" ]]; then
    [[ -x "${AGENT_OLLAMA_PRELOAD_SCRIPT}" ]] || die "preload script missing: ${AGENT_OLLAMA_PRELOAD_SCRIPT}"
    exec "${AGENT_OLLAMA_PRELOAD_SCRIPT}" --help
  fi

  ensure_runtime_env
  ensure_core_runtime
  [[ -x "${AGENT_OLLAMA_PRELOAD_SCRIPT}" ]] || die "preload script missing: ${AGENT_OLLAMA_PRELOAD_SCRIPT}"

  "${AGENT_OLLAMA_PRELOAD_SCRIPT}" "$@"
}

cmd_ollama_link() {
  [[ -x "${AGENT_OLLAMA_LINK_SCRIPT}" ]] || die "missing script: ${AGENT_OLLAMA_LINK_SCRIPT}"
  ensure_runtime_env
  "${AGENT_OLLAMA_LINK_SCRIPT}"
}

cmd_ollama_drift() {
  local action="${1:-watch}"
  shift || true

  case "${action}" in
    watch)
      [[ -x "${AGENT_OLLAMA_DRIFT_WATCH_SCRIPT}" ]] || die "missing script: ${AGENT_OLLAMA_DRIFT_WATCH_SCRIPT}"
      ensure_runtime_env
      "${AGENT_OLLAMA_DRIFT_WATCH_SCRIPT}" "$@"
      ;;
    schedule)
      [[ -x "${AGENT_OLLAMA_DRIFT_SCHEDULE_SCRIPT}" ]] || die "missing script: ${AGENT_OLLAMA_DRIFT_SCHEDULE_SCRIPT}"
      ensure_runtime_env
      "${AGENT_OLLAMA_DRIFT_SCHEDULE_SCRIPT}" "$@"
      ;;
    *)
      die "Usage: agent ollama-drift watch [--ack-baseline] [--no-beads] [--issue-id <id>] [--state-dir <path>] [--sources-dir <path>] [--sources <csv>] [--timeout-sec <int>] [--quiet] | agent ollama-drift schedule [--disable] [--dry-run] [--on-calendar <expr>] [--cron <expr>] [--force-cron]"
      ;;
  esac
}

run_first_up_step() {
  local step_name="$1"
  local dry_run="$2"
  shift 2
  local -a cmd=("$@")
  local rendered=""
  local token

  for token in "${cmd[@]}"; do
    if [[ -z "${rendered}" ]]; then
      rendered="$(printf '%q' "${token}")"
    else
      rendered="${rendered} $(printf '%q' "${token}")"
    fi
  done

  printf 'first-up step=%s cmd=%s\n' "${step_name}" "${rendered}"
  if [[ "${dry_run}" == "1" ]]; then
    return 0
  fi

  "${cmd[@]}"
}

cmd_first_up() {
  local env_file="${AGENTIC_ONBOARD_OUTPUT:-${AGENTIC_REPO_ROOT}/.runtime/env.generated.sh}"
  local use_env=1
  local dry_run=0
  local failed=0
  local step=""
  local -a profile_cmd=()
  local -a init_fs_cmd=()
  local -a up_core_cmd=()
  local -a up_baseline_cmd=()
  local -a doctor_cmd=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file)
        [[ $# -ge 2 ]] || die "missing value for --env-file"
        env_file="$2"
        shift 2
        ;;
      --no-env)
        use_env=0
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help|help)
        cat <<USAGE
Usage:
  agent first-up [--env-file <path>] [--no-env] [--dry-run]

Description:
  Run first-start sequence in one command:
  1) load onboarding env file (unless --no-env)
  2) agent profile
  3) deployments/bootstrap/init_fs.sh
  4) agent up core
  5) agent up agents,ui,obs,rag
  6) agent doctor
USAGE
        return 0
        ;;
      *)
        die "Unknown first-up argument: $1"
        ;;
    esac
  done

  if [[ "${env_file}" != /* ]]; then
    env_file="${PWD}/${env_file}"
  fi

  if [[ "${use_env}" == "1" ]]; then
    if [[ -f "${env_file}" ]]; then
      # shellcheck disable=SC1090
      source "${env_file}"
      printf 'first-up loaded_env=%s\n' "${env_file}"
    else
      warn "first-up: env file not found, continuing with current shell context: ${env_file}"
    fi
  fi

  profile_cmd=("${AGENTIC_REPO_ROOT}/agent" profile)
  init_fs_cmd=("${AGENTIC_REPO_ROOT}/deployments/bootstrap/init_fs.sh")
  up_core_cmd=("${AGENTIC_REPO_ROOT}/agent" up core)
  up_baseline_cmd=("${AGENTIC_REPO_ROOT}/agent" up agents,ui,obs,rag)
  doctor_cmd=("${AGENTIC_REPO_ROOT}/agent" doctor)

  step="profile"
  run_first_up_step "${step}" "${dry_run}" "${profile_cmd[@]}" || failed=1
  if [[ "${failed}" == "0" ]]; then
    step="init-fs"
    run_first_up_step "${step}" "${dry_run}" "${init_fs_cmd[@]}" || failed=1
  fi
  if [[ "${failed}" == "0" ]]; then
    step="up-core"
    run_first_up_step "${step}" "${dry_run}" "${up_core_cmd[@]}" || failed=1
  fi
  if [[ "${failed}" == "0" ]]; then
    step="up-baseline"
    run_first_up_step "${step}" "${dry_run}" "${up_baseline_cmd[@]}" || failed=1
  fi
  if [[ "${failed}" == "0" ]]; then
    step="doctor"
    run_first_up_step "${step}" "${dry_run}" "${doctor_cmd[@]}" || failed=1
  fi

  if [[ "${failed}" == "1" ]]; then
    if [[ "${AGENTIC_PROFILE}" == "strict-prod" && "${EUID}" -ne 0 ]]; then
      warn "first-up failed in strict-prod without root privileges; retry with sudo if failure is permission-related."
      printf 'hint: sudo -E %q first-up --env-file %q\n' "${AGENTIC_REPO_ROOT}/agent" "${env_file}" >&2
    fi
    die "first-up failed at step '${step}'"
  fi

  if [[ "${dry_run}" == "1" ]]; then
    printf 'first-up completed (dry-run)\n'
  else
    printf 'first-up completed\n'
  fi
}

cmd_onboard() {
  [[ -x "${AGENT_ONBOARD_SCRIPT}" ]] || die "onboarding wizard script missing or not executable: ${AGENT_ONBOARD_SCRIPT}"
  "${AGENT_ONBOARD_SCRIPT}" "$@"
}

cmd_prereqs() {
  [[ -x "${AGENT_PREREQS_SCRIPT}" ]] || die "prereqs script missing or not executable: ${AGENT_PREREQS_SCRIPT}"
  "${AGENT_PREREQS_SCRIPT}" "$@"
}

cmd_vm() {
  local action="${1:-}"
  shift || true

  case "${action}" in
    create)
      [[ -x "${AGENT_VM_CREATE_SCRIPT}" ]] || die "VM create script missing or not executable: ${AGENT_VM_CREATE_SCRIPT}"
      "${AGENT_VM_CREATE_SCRIPT}" "$@"
      ;;
    test)
      [[ -x "${AGENT_VM_TEST_SCRIPT}" ]] || die "VM test script missing or not executable: ${AGENT_VM_TEST_SCRIPT}"
      "${AGENT_VM_TEST_SCRIPT}" "$@"
      ;;
    cleanup)
      [[ -x "${AGENT_VM_CLEANUP_SCRIPT}" ]] || die "VM cleanup script missing or not executable: ${AGENT_VM_CLEANUP_SCRIPT}"
      "${AGENT_VM_CLEANUP_SCRIPT}" "$@"
      ;;
    *)
      die "Usage: agent vm create [--name ... --cpus ... --memory ... --disk ... --image ... --workspace-path ... --reuse-existing --mount-repo|--no-mount-repo --require-gpu --skip-bootstrap --dry-run] | agent vm test [--name ... --workspace-path ... --test-selectors ... --require-gpu|--allow-no-gpu --skip-d5-tests --dry-run] | agent vm cleanup [--name ... --yes --dry-run]"
      ;;
  esac
}

normalize_gate_test_mode_value() {
  local raw="${1:-0}"
  case "${raw}" in
    1|true|TRUE|yes|YES|on|ON) printf '1\n' ;;
    0|false|FALSE|no|NO|off|OFF|"") printf '0\n' ;;
    *)
      warn "invalid GATE_ENABLE_TEST_MODE='${raw}', treating as disabled"
      printf '0\n'
      ;;
  esac
}

normalize_llm_mode_value() {
  local raw="${1:-hybrid}"
  case "${raw}" in
    local|hybrid|remote)
      printf '%s\n' "${raw}"
      ;;
    mixed)
      printf 'hybrid\n'
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_llm_backend_value() {
  local raw="${1:-both}"
  case "${raw}" in
    ollama|trtllm|both|remote)
      printf '%s\n' "${raw}"
      ;;
    *)
      return 1
      ;;
  esac
}

read_gate_state_value() {
  local file_path="$1"
  local field_name="$2"
  local default_value="$3"

  python3 - "${file_path}" "${field_name}" "${default_value}" <<'PY'
import json
import sys

path, field_name, default_value = sys.argv[1:4]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print(default_value)
    raise SystemExit(0)

if isinstance(data, dict):
    value = data.get(field_name)
else:
    value = data
if isinstance(value, str) and value.strip():
    print(value.strip().lower())
else:
    print(default_value)
PY
}

set_gate_test_mode_value() {
  local enabled="$1"
  local restart_if_running="${2:-1}"
  local gate_cid=""

  case "${enabled}" in
    0|1) ;;
    *) die "internal error: unsupported gate test mode value '${enabled}'" ;;
  esac

  ensure_runtime_env
  set_runtime_env_value "GATE_ENABLE_TEST_MODE" "${enabled}"
  export GATE_ENABLE_TEST_MODE="${enabled}"

  if [[ "${restart_if_running}" == "1" ]]; then
    gate_cid="$(service_container_id "ollama-gate" || true)"
    if [[ -n "${gate_cid}" ]]; then
      # Refresh runtime ownership before gate recreation to avoid non-root
      # read failures on bind-mounted state/config files.
      ensure_core_runtime
      run_compose_on_targets up core -d --no-deps --force-recreate ollama-gate >/dev/null
    fi
  fi
}

cmd_llm() {
  local action="${1:-}"
  shift || true

  case "${action}" in
    mode)
      local mode_input="${1:-}"
      local mode_file="${AGENTIC_ROOT}/gate/state/llm_mode.json"
      local actor="${SUDO_USER:-${USER:-unknown}}"
      local current_mode
      local mode

      if [[ -z "${mode_input}" ]]; then
        if [[ -f "${mode_file}" ]]; then
          current_mode="$(read_gate_state_value "${mode_file}" "mode" "hybrid")"
          printf 'llm mode=%s\n' "${current_mode}"
        else
          printf 'llm mode=%s\n' "${AGENTIC_LLM_MODE:-hybrid}"
        fi
        return 0
      fi

      mode="$(normalize_llm_mode_value "${mode_input}" 2>/dev/null)" \
        || die "Usage: agent llm mode [local|hybrid|mixed|remote]"

      ensure_runtime_env
      set_runtime_env_value "AGENTIC_LLM_MODE" "${mode}"
      export AGENTIC_LLM_MODE="${mode}"

      install -d -m 0770 "${AGENTIC_ROOT}/gate/state"
      if [[ "${EUID}" -eq 0 ]]; then
        chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${AGENTIC_ROOT}/gate/state" || true
      fi
      cat >"${mode_file}" <<JSON
{"mode":"${mode}","updated_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","updated_by":"${actor}"}
JSON
      chmod 0640 "${mode_file}" || true
      chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${mode_file}" || true

      printf 'llm mode set to %s (state=%s)\n' "${mode}" "${mode_file}"
      if [[ "${mode}" == "remote" ]]; then
        printf 'tip: to free local GPU/RAM, run: agent stop service ollama trtllm\n'
      fi
      ;;
    backend)
      local backend_input="${1:-}"
      local backend_file="${AGENTIC_ROOT}/gate/state/llm_backend.json"
      local backend_runtime_file="${AGENTIC_ROOT}/gate/state/llm_backend_runtime.json"
      local actor="${SUDO_USER:-${USER:-unknown}}"
      local current_backend
      local current_effective_backend
      local backend

      if [[ -z "${backend_input}" ]]; then
        if [[ -f "${backend_file}" ]]; then
          current_backend="$(read_gate_state_value "${backend_file}" "backend" "both")"
          printf 'llm backend=%s\n' "${current_backend}"
        else
          printf 'llm backend=%s\n' "${AGENTIC_LLM_BACKEND:-both}"
        fi
        if [[ -f "${backend_runtime_file}" ]]; then
          current_effective_backend="$(read_gate_state_value "${backend_runtime_file}" "effective_backend" "")"
          if [[ -n "${current_effective_backend}" ]]; then
            printf 'llm backend effective=%s\n' "${current_effective_backend}"
          fi
        fi
        return 0
      fi

      backend="$(normalize_llm_backend_value "${backend_input}" 2>/dev/null)" \
        || die "Usage: agent llm backend [ollama|trtllm|both|remote]"

      ensure_runtime_env
      set_runtime_env_value "AGENTIC_LLM_BACKEND" "${backend}"
      export AGENTIC_LLM_BACKEND="${backend}"

      install -d -m 0770 "${AGENTIC_ROOT}/gate/state"
      if [[ "${EUID}" -eq 0 ]]; then
        chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${AGENTIC_ROOT}/gate/state" || true
      fi
      cat >"${backend_file}" <<JSON
{"backend":"${backend}","updated_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","updated_by":"${actor}"}
JSON
      chmod 0640 "${backend_file}" || true
      chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${backend_file}" || true

      current_effective_backend=""
      if [[ -f "${backend_runtime_file}" ]]; then
        current_effective_backend="$(read_gate_state_value "${backend_runtime_file}" "effective_backend" "")"
      fi
      if [[ "${backend}" != "both" ]]; then
        current_effective_backend="${backend}"
      elif [[ "${current_effective_backend}" != "ollama" && "${current_effective_backend}" != "trtllm" && "${current_effective_backend}" != "remote" ]]; then
        current_effective_backend="ollama"
      fi
      cat >"${backend_runtime_file}" <<JSON
{"desired_backend":"${backend}","effective_backend":"${current_effective_backend}","last_switch_reason":"agent_cli_set_backend","last_route_backend":"","last_route_model":"","switch_count":0,"cooldown_until_epoch":0,"cooldown_until":"","updated_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","updated_by":"${actor}"}
JSON
      chmod 0640 "${backend_runtime_file}" || true
      chown "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" "${backend_runtime_file}" || true

      printf 'llm backend set to %s (state=%s)\n' "${backend}" "${backend_file}"
      if [[ "${backend}" == "both" ]]; then
        printf 'tip: model routes can now switch dynamically between ollama and trtllm\n'
      elif [[ "${backend}" == "remote" ]]; then
        printf 'tip: if AGENTIC_LLM_MODE=local, remote backend policy will still block external providers; use agent llm mode hybrid|remote\n'
      fi
      ;;
    test-mode)
      local test_mode="${1:-}"
      local normalized
      local gate_cid

      if [[ -z "${test_mode}" ]]; then
        normalized="$(normalize_gate_test_mode_value "${GATE_ENABLE_TEST_MODE:-0}")"
        if [[ "${normalized}" == "1" ]]; then
          printf 'llm test-mode=on\n'
        else
          printf 'llm test-mode=off\n'
        fi
        return 0
      fi

      case "${test_mode}" in
        on)
          normalized="1"
          ;;
        off)
          normalized="0"
          ;;
        *)
          die "Usage: agent llm test-mode [on|off]"
          ;;
      esac

      gate_cid="$(service_container_id "ollama-gate" || true)"
      set_gate_test_mode_value "${normalized}" "1"

      if [[ -n "${gate_cid}" ]]; then
        printf 'llm test-mode=%s (restarted ollama-gate)\n' "${test_mode}"
      else
        printf 'llm test-mode=%s (persisted; restart applies when core is started)\n' "${test_mode}"
      fi
      ;;
    *)
      die "Usage: agent llm mode [local|hybrid|mixed|remote] | agent llm backend [ollama|trtllm|both|remote] | agent llm test-mode [on|off]"
      ;;
  esac
}

cmd_comfyui() {
  local action="${1:-}"
  shift || true

  case "${action}" in
    flux-1-dev|flux1-dev|flux-dev)
      [[ -x "${AGENT_COMFYUI_FLUX_SETUP_SCRIPT}" ]] \
        || die "comfyui flux setup script missing or not executable: ${AGENT_COMFYUI_FLUX_SETUP_SCRIPT}"
      "${AGENT_COMFYUI_FLUX_SETUP_SCRIPT}" "$@"
      ;;
    *)
      die "Usage: agent comfyui flux-1-dev [--download] [--hf-token-file <path>] [--no-egress-check] [--dry-run]"
      ;;
  esac
}

cmd_openclaw_init() {
  local project="${1:-}"
  local raw_project=""
  local workspace=""
  local workspace_host_dir=""
  local telegram_bot_token=""
  local telegram_bot_token_file=""
  local telegram_secret_file="${AGENTIC_ROOT}/secrets/runtime/telegram.bot_token"
  local telegram_secret_value=""
  local overlay_file="${AGENTIC_ROOT}/openclaw/config/overlay/openclaw.operator-overlay.json"
  local overlay_template_file="${AGENTIC_REPO_ROOT}/examples/optional/openclaw.operator-overlay.v1.json"
  local state_file="${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/openclaw.state.json"
  local token_file="${AGENTIC_ROOT}/secrets/runtime/openclaw.token"
  local bridge_status_file="${AGENTIC_ROOT}/openclaw/state/provider-bridge-status.json"
  local init_repair_json=""
  local configured_workspace=""
  local agents_json=""
  local agent_count=""
  local bridge_summary=""
  local bridge_warnings=""
  local openclaw_cid=""
  local service=""
  local need_up=0

  if [[ "${project}" == "help" || "${project}" == "-h" || "${project}" == "--help" ]]; then
    cat <<USAGE
Usage:
  agent openclaw init [project] [--telegram-bot-token <token> | --telegram-bot-token-file <path>]

Description:
  Apply the stack-managed OpenClaw onboarding/repair flow.
  - repairs the layered OpenClaw host config if the default workspace drifted,
  - starts the core OpenClaw services if needed,
  - seeds the stack-safe local provider/gateway defaults,
  - optionally writes the Telegram bot token into the stack-managed secret file,
  - prints the next file-backed provider/channel steps.

Notes:
  - default project comes from AGENTIC_OPENCLAW_INIT_PROJECT (fallback: 'openclaw-default')
  - this command is safe to rerun as a repair path
  - upstream 'openclaw onboard' and 'openclaw configure --section channels' remain expert fallbacks only
USAGE
    return 0
  fi

  if [[ -n "${project}" && "${project}" != --* ]]; then
    shift
    raw_project="${project}"
  else
    raw_project="${AGENTIC_OPENCLAW_INIT_PROJECT:-openclaw-default}"
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help|help)
        cat <<USAGE
Usage:
  agent openclaw init [project] [--telegram-bot-token <token> | --telegram-bot-token-file <path>]
USAGE
    return 0
        ;;
      --telegram-bot-token)
        [[ $# -ge 2 ]] || die "missing value for --telegram-bot-token"
        telegram_bot_token="$2"
        shift 2
        ;;
      --telegram-bot-token-file)
        [[ $# -ge 2 ]] || die "missing value for --telegram-bot-token-file"
        telegram_bot_token_file="$2"
        shift 2
        ;;
      *)
        die "Usage: agent openclaw init [project] [--telegram-bot-token <token> | --telegram-bot-token-file <path>]"
        ;;
    esac
  done

  raw_project="${raw_project// /-}"
  project="$(printf '%s' "${raw_project}" | sed -e 's#[^A-Za-z0-9._-]#-#g' -e 's#^-*##' -e 's#-*$##')"
  [[ -n "${project}" ]] || die "OpenClaw init project name resolved to empty value from '${raw_project}'"

  workspace="/workspace/${project}"
  workspace_host_dir="${AGENTIC_OPENCLAW_WORKSPACES_DIR}/${project}"

  ensure_runtime_env

  telegram_secret_value="$(read_secret_value "${telegram_bot_token}" "${telegram_bot_token_file}")"
  if [[ -n "${telegram_secret_value}" ]]; then
    write_runtime_secret_file "${telegram_secret_file}" "${telegram_secret_value}"
  fi

  if [[ "${AGENTIC_PROFILE}" == "rootless-dev" ]]; then
    [[ -x "${AGENT_OLLAMA_LINK_SCRIPT}" ]] || die "missing script: ${AGENT_OLLAMA_LINK_SCRIPT}"
    if ! "${AGENT_OLLAMA_LINK_SCRIPT}" --quiet >/tmp/agent-openclaw-init-ollama-link.out 2>&1; then
      cat /tmp/agent-openclaw-init-ollama-link.out >&2
      die "failed to initialize rootless ollama models symlink before openclaw init"
    fi
  fi

  [[ -f "${AGENT_OPENCLAW_MANAGED_INIT_SCRIPT}" ]] \
    || die "openclaw managed init helper is missing: ${AGENT_OPENCLAW_MANAGED_INIT_SCRIPT}"
  [[ -f "${overlay_template_file}" ]] || die "openclaw overlay template is missing: ${overlay_template_file}"

  if ! init_repair_json="$(
    python3 "${AGENT_OPENCLAW_MANAGED_INIT_SCRIPT}" \
      --overlay-file "${overlay_file}" \
      --overlay-template-file "${overlay_template_file}" \
      --state-file "${state_file}" \
      --workspace "${workspace}" \
      --workspace-host-dir "${workspace_host_dir}"
  )"; then
    die "failed to prepare stack-managed openclaw init inputs"
  fi

  if ! ensure_core_runtime >/tmp/agent-openclaw-init-runtime.out 2>&1; then
    cat /tmp/agent-openclaw-init-runtime.out >&2
    die "failed to initialize core runtime for openclaw init"
  fi

  for service in openclaw openclaw-gateway openclaw-provider-bridge openclaw-sandbox openclaw-relay; do
    if [[ -z "$(service_container_id "${service}")" ]]; then
      need_up=1
      break
    fi
  done

  if [[ "${need_up}" == "1" ]]; then
    if ! "${AGENTIC_REPO_ROOT}/agent" up core >/tmp/agent-openclaw-init-up.out 2>&1; then
      cat /tmp/agent-openclaw-init-up.out >&2
      die "failed to start core services for openclaw init"
    fi
  fi

  for service in openclaw openclaw-gateway openclaw-provider-bridge openclaw-sandbox openclaw-relay; do
    wait_for_service_ready "${service}" 120 || die "service '${service}' is not ready for openclaw init"
  done

  openclaw_cid="$(service_container_id openclaw)"
  [[ -n "${openclaw_cid}" ]] || die "Service 'openclaw' is not running after core startup"
  [[ -s "${token_file}" ]] || die "managed OpenClaw token file is missing or empty: ${token_file}"

  if ! docker exec \
    -e "OPENCLAW_GATEWAY_TOKEN=$(tr -d '\r\n' <"${token_file}")" \
    "${openclaw_cid}" \
    sh -lc "mkdir -p '${workspace}' && cd '${workspace}' && openclaw onboard \
      --workspace '${workspace}' \
      --mode local \
      --non-interactive \
      --accept-risk \
      --auth-choice custom-api-key \
      --custom-provider-id custom-ollama-gate-11435 \
      --custom-base-url http://ollama-gate:11435/v1 \
      --custom-compatibility openai \
      --custom-model-id '${AGENTIC_DEFAULT_MODEL}' \
      --custom-api-key local-gate \
      --gateway-auth token \
      --gateway-bind loopback \
      --gateway-port '${OPENCLAW_GATEWAY_HOST_PORT:-18789}' \
      --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
      --secret-input-mode plaintext \
      --tailscale off \
      --skip-health \
      --skip-daemon \
      --skip-skills \
      --skip-ui \
      --skip-channels \
      --skip-search" >/tmp/agent-openclaw-init-onboard.out 2>&1; then
    cat /tmp/agent-openclaw-init-onboard.out >&2
    die "managed OpenClaw bootstrap failed; use './agent openclaw' only for expert/manual fallback after fixing the error above"
  fi

  if ! docker exec "${openclaw_cid}" sh -lc "openclaw config set agents.defaults.workspace '${workspace}'" \
    >/tmp/agent-openclaw-init-config-set.out 2>&1; then
    cat /tmp/agent-openclaw-init-config-set.out >&2
    die "failed to persist the stack-managed OpenClaw workspace"
  fi

  if ! docker exec "${openclaw_cid}" sh -lc "openclaw config validate" \
    >/tmp/agent-openclaw-init-config-validate.out 2>&1; then
    cat /tmp/agent-openclaw-init-config-validate.out >&2
    die "OpenClaw config validation failed after managed init"
  fi

  cmd_openclaw_operator model set "${AGENTIC_DEFAULT_MODEL}" --json >/tmp/agent-openclaw-init-model-set.out 2>&1 \
    || die "failed to reconcile OpenClaw operator default model"

  agents_json="$(docker exec "${openclaw_cid}" sh -lc "openclaw agents list --json" 2>/tmp/agent-openclaw-init-agents.err)" \
    || die "failed to read OpenClaw agents after managed init"
  agent_count="$(python3 - "${agents_json}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
if not isinstance(payload, list):
    raise SystemExit(1)
print(len(payload))
PY
)" || die "failed to parse OpenClaw agent list after managed init"

  if [[ "${agent_count}" == "0" ]]; then
    if ! docker exec "${openclaw_cid}" sh -lc "openclaw agents add operator --workspace '${workspace}' --model '${AGENTIC_DEFAULT_MODEL}' --non-interactive --json" \
      >/tmp/agent-openclaw-init-agent-add.out 2>&1; then
      cat /tmp/agent-openclaw-init-agent-add.out >&2
      die "managed OpenClaw init could not seed a default operator agent"
    fi
    agents_json="$(docker exec "${openclaw_cid}" sh -lc "openclaw agents list --json" 2>/tmp/agent-openclaw-init-agents.err)" \
      || die "failed to read OpenClaw agents after managed agent seeding"
  fi

  configured_workspace="$(docker exec "${openclaw_cid}" sh -lc "openclaw config get agents.defaults.workspace" 2>/tmp/agent-openclaw-init-workspace.err || true)"
  [[ "${configured_workspace}" == "${workspace}" ]] \
    || die "OpenClaw default workspace drift persists after init (expected=${workspace}, actual=${configured_workspace:-unset})"

  python3 - "${agents_json}" "${workspace}" <<'PY' >/dev/null
import json
import sys

payload = json.loads(sys.argv[1])
expected = sys.argv[2]
if not isinstance(payload, list) or not payload:
    raise SystemExit(1)
if not any(isinstance(item, dict) and item.get("workspace") == expected for item in payload):
    raise SystemExit(1)
PY
  [[ $? -eq 0 ]] || die "OpenClaw agents were not reconciled onto the stack-managed workspace ${workspace}"

  bridge_summary="$(python3 - "${bridge_status_file}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    print("providers=none")
    print("warnings=")
    raise SystemExit(0)

payload = json.loads(path.read_text(encoding="utf-8"))
providers = payload.get("providers") or {}
configured = []
for name in ("telegram", "discord", "slack", "whatsapp"):
    item = providers.get(name) or {}
    if item.get("configured") is True or item.get("enabled") is True:
        configured.append(name)
print("providers=" + (",".join(configured) if configured else "none"))
warnings = payload.get("warnings") or []
print("warnings=" + " | ".join(str(item) for item in warnings if str(item).strip()))
PY
)"
  bridge_warnings="$(printf '%s\n' "${bridge_summary}" | sed -n 's/^warnings=//p')"

  printf 'OpenClaw managed init complete.\n'
  printf 'workspace=%s\n' "${workspace}"
  printf 'workspace_host_dir=%s\n' "${workspace_host_dir}"
  printf 'default_model=%s\n' "${AGENTIC_DEFAULT_MODEL}"
  if [[ -s "${telegram_secret_file}" ]]; then
    printf 'telegram_secret_file=%s\n' "${telegram_secret_file}"
  fi
  printf 'providers=%s\n' "$(printf '%s\n' "${bridge_summary}" | sed -n 's/^providers=//p')"
  printf 'repair=%s\n' "${init_repair_json}"
  if [[ -n "${bridge_warnings}" ]]; then
    printf 'provider_warnings=%s\n' "${bridge_warnings}"
  fi
  printf 'Next steps:\n'
  printf '1. File-backed provider bridge status lives in %s.\n' "${bridge_status_file}"
  printf '2. Telegram/Discord/Slack are stack-managed from secret files under %s; populate those files instead of using the upstream channel wizard when possible.\n' "${AGENTIC_ROOT}/secrets/runtime"
  printf '3. Map provider webhook targets in %s.\n' "${AGENTIC_ROOT}/openclaw/config/relay_targets.json"
  printf '4. Extend policy allowlists with ./agent openclaw policy add dm-target <target> and ./agent openclaw policy add tool <tool>.\n'
  printf '5. Use ./agent openclaw then openclaw channels login --channel whatsapp only for QR/manual providers that cannot be expressed through the file-backed bridge.\n'
  printf '6. Advanced fallback only: ./agent openclaw then openclaw configure --section channels. Do not use openclaw gateway run for normal stack operation.\n'
}

openclaw_operator_args() {
  printf '%s\n' \
    --operator-registry-file "${AGENTIC_ROOT}/openclaw/sandbox/state/openclaw-state-registry.v1.json" \
    --operator-runtime-file "${AGENTIC_ROOT}/openclaw/config/operator-runtime.v1.json" \
    --manifest-file "${AGENTIC_ROOT}/openclaw/config/module/openclaw.module-manifest.v1.json" \
    --dm-allowlist-file "${AGENTIC_ROOT}/openclaw/config/dm_allowlist.txt" \
    --tool-allowlist-file "${AGENTIC_ROOT}/openclaw/config/tool_allowlist.txt"
}

openclaw_operator_sandbox_field() {
  local registry_file="$1"
  local sandbox_id="$2"
  local field="$3"
  python3 - "${registry_file}" "${sandbox_id}" "${field}" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
sandbox_id = sys.argv[2]
field = sys.argv[3]
record = (payload.get("sandboxes") or {}).get(sandbox_id)
if not isinstance(record, dict):
    raise SystemExit(1)
value = record.get(field)
if not isinstance(value, str) or not value:
    raise SystemExit(1)
print(value)
PY
}

cmd_openclaw_operator() {
  local action="${1:-status}"
  shift || true

  [[ -f "${AGENT_OPENCLAW_OPERATOR_SCRIPT}" ]] \
    || die "openclaw operator helper is missing: ${AGENT_OPENCLAW_OPERATOR_SCRIPT}"
  [[ -f "${AGENT_OPENCLAW_MODULE_MANIFEST_SCRIPT}" ]] \
    || die "openclaw module manifest helper is missing: ${AGENT_OPENCLAW_MODULE_MANIFEST_SCRIPT}"

  ensure_runtime_env
  ensure_core_runtime >/dev/null

  local operator_registry_file="${AGENTIC_ROOT}/openclaw/sandbox/state/openclaw-state-registry.v1.json"
  local operator_runtime_file="${AGENTIC_ROOT}/openclaw/config/operator-runtime.v1.json"
  local manifest_file="${AGENTIC_ROOT}/openclaw/config/module/openclaw.module-manifest.v1.json"
  local actor="${SUDO_USER:-${USER:-unknown}}"
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  python3 "${AGENT_OPENCLAW_MODULE_MANIFEST_SCRIPT}" validate --manifest-file "${manifest_file}" >/dev/null

  case "${action}" in
    status)
      python3 "${AGENT_OPENCLAW_OPERATOR_SCRIPT}" \
        $(openclaw_operator_args) \
        status "$@"
      ;;
    policy)
      local policy_action="${1:-list}"
      shift || true
      case "${policy_action}" in
        list)
          python3 "${AGENT_OPENCLAW_OPERATOR_SCRIPT}" \
            $(openclaw_operator_args) \
            policy list "$@"
          ;;
        add)
          [[ $# -ge 2 ]] || die "Usage: agent openclaw policy add <dm-target|tool> <value> [--json]"
          python3 "${AGENT_OPENCLAW_OPERATOR_SCRIPT}" \
            $(openclaw_operator_args) \
            policy add "$@"
          ;;
        *)
          die "Usage: agent openclaw policy [list [--json] | add <dm-target|tool> <value> [--json]]"
          ;;
      esac
      ;;
    model)
      [[ "${1:-}" == "set" ]] || die "Usage: agent openclaw model set <id> [--json]"
      shift
      [[ $# -ge 1 ]] || die "Usage: agent openclaw model set <id> [--json]"
      local model_id="$1"
      shift
      python3 "${AGENT_OPENCLAW_OPERATOR_SCRIPT}" \
        $(openclaw_operator_args) \
        model set "${model_id}" \
        --updated-at "${timestamp}" \
        --updated-by "${actor}" \
        "$@"
      ;;
    sandbox)
      local sandbox_action="${1:-ls}"
      shift || true
      case "${sandbox_action}" in
        ls)
          python3 "${AGENT_OPENCLAW_OPERATOR_SCRIPT}" \
            $(openclaw_operator_args) \
            sandbox ls "$@"
          ;;
        destroy)
          [[ $# -ge 1 ]] || die "Usage: agent openclaw sandbox destroy <sandbox_id> [--json]"
          local sandbox_id="$1"
          shift
          local sandbox_cid
          sandbox_cid="$(service_container_id openclaw-sandbox)"
          [[ -n "${sandbox_cid}" ]] || die "Service 'openclaw-sandbox' is not running. Start it with: agent up core"
          python3 "${AGENT_OPENCLAW_OPERATOR_SCRIPT}" \
            $(openclaw_operator_args) \
            sandbox destroy "${sandbox_id}" \
            --sandbox-container "${sandbox_cid}" \
            --token-file /run/secrets/openclaw.token \
            "$@"
          ;;
        attach)
          [[ $# -ge 1 ]] || die "Usage: agent openclaw sandbox attach <sandbox_id>"
          local sandbox_id="$1"
          local sandbox_cid
          local workspace_dir
          sandbox_cid="$(service_container_id openclaw-sandbox)"
          [[ -n "${sandbox_cid}" ]] || die "Service 'openclaw-sandbox' is not running. Start it with: agent up core"
          workspace_dir="$(openclaw_operator_sandbox_field "${operator_registry_file}" "${sandbox_id}" "workspace_dir")" \
            || die "sandbox '${sandbox_id}' not found in operator registry ${operator_registry_file}"
          printf 'INFO: openclaw sandbox attach targets sandbox_id=%s.\n' "${sandbox_id}"
          printf 'INFO: sandbox workspace is %s.\n' "${workspace_dir}"
          printf 'INFO: runtime registry is %s.\n' "${operator_registry_file}"
          if [[ "${AGENT_NO_ATTACH:-0}" == "1" ]]; then
            printf 'prepared sandbox=%s container=%s workspace=%s\n' "${sandbox_id}" "${sandbox_cid}" "${workspace_dir}"
            return 0
          fi
          bootstrap_container_bash_home "${sandbox_cid}" "/state/shell-home"
          exec docker exec -it "${sandbox_cid}" sh -lc "export HOME='/state/shell-home'; cd '${workspace_dir}' && exec bash -l"
          ;;
        *)
          die "Usage: agent openclaw sandbox [ls [--json] | attach <sandbox_id> | destroy <sandbox_id> [--json]]"
          ;;
      esac
      ;;
    *)
      die "Usage: agent openclaw [status [--json] | policy [list [--json] | add <dm-target|tool> <value> [--json]] | model set <id> [--json] | sandbox [ls [--json] | attach <sandbox_id> | destroy <sandbox_id> [--json]] | approvals ...]"
      ;;
  esac
}

cmd_openclaw_approvals() {
  local action="${1:-list}"
  shift || true

  [[ -f "${AGENT_OPENCLAW_APPROVALS_SCRIPT}" ]] \
    || die "openclaw approvals helper is missing: ${AGENT_OPENCLAW_APPROVALS_SCRIPT}"

  ensure_runtime_env
  ensure_core_runtime >/dev/null

  local state_dir="${AGENTIC_ROOT}/openclaw/state/approvals"
  local audit_log="${AGENTIC_ROOT}/openclaw/logs/audit.jsonl"
  local actor="${SUDO_USER:-${USER:-unknown}}"
  local dm_allowlist_file="${AGENTIC_ROOT}/openclaw/config/dm_allowlist.txt"
  local tool_allowlist_file="${AGENTIC_ROOT}/openclaw/config/tool_allowlist.txt"

  case "${action}" in
    list)
      python3 "${AGENT_OPENCLAW_APPROVALS_SCRIPT}" \
        --state-dir "${state_dir}" \
        --audit-log "${audit_log}" \
        --actor "${actor}" \
        list "$@"
      ;;
    approve)
      [[ $# -ge 1 ]] || die "Usage: agent openclaw approvals approve <id> --scope <session|global> [--session-id <id>] [--ttl-sec <sec>]"
      python3 "${AGENT_OPENCLAW_APPROVALS_SCRIPT}" \
        --state-dir "${state_dir}" \
        --audit-log "${audit_log}" \
        --actor "${actor}" \
        approve "$@"
      ;;
    deny)
      [[ $# -ge 1 ]] || die "Usage: agent openclaw approvals deny <id> --scope <session|global> [--session-id <id>] [--ttl-sec <sec>] [--reason <text>]"
      python3 "${AGENT_OPENCLAW_APPROVALS_SCRIPT}" \
        --state-dir "${state_dir}" \
        --audit-log "${audit_log}" \
        --actor "${actor}" \
        deny "$@"
      ;;
    promote)
      [[ $# -ge 1 ]] || die "Usage: agent openclaw approvals promote <id>"
      python3 "${AGENT_OPENCLAW_APPROVALS_SCRIPT}" \
        --state-dir "${state_dir}" \
        --audit-log "${audit_log}" \
        --actor "${actor}" \
        promote "$@" \
        --dm-allowlist-file "${dm_allowlist_file}" \
        --tool-allowlist-file "${tool_allowlist_file}"
      ;;
    *)
      die "Usage: agent openclaw approvals [list [--status <pending|approved|denied|expired|all>] [--json] | approve <id> --scope <session|global> [--session-id <id>] [--ttl-sec <sec>] | deny <id> --scope <session|global> [--session-id <id>] [--ttl-sec <sec>] [--reason <text>] | promote <id>]"
      ;;
  esac
}

cmd_backup() {
  [[ -x "${AGENT_BACKUP_SCRIPT}" ]] || die "backup script missing or not executable: ${AGENT_BACKUP_SCRIPT}"

  local action="${1:-}"
  shift || true

  case "${action}" in
    run|list)
      "${AGENT_BACKUP_SCRIPT}" "${action}" "$@"
      ;;
    restore)
      [[ $# -ge 1 ]] || die "Usage: agent backup restore <snapshot_id> [--yes]"
      "${AGENT_BACKUP_SCRIPT}" restore "$@"
      ;;
    *)
      die "Usage: agent backup <run|list|restore <snapshot_id> [--yes]>"
      ;;
  esac
}

cmd_net() {
  local action="${1:-}"
  case "${action}" in
    apply)
      ensure_runtime_env
      apply_core_network_policy
      ;;
    *)
      die "Usage: agent net apply"
      ;;
  esac
}

print_sudo_mode() {
  if [[ "${AGENTIC_AGENT_NO_NEW_PRIVILEGES}" == "false" ]]; then
    printf 'sudo-mode=on (agent services run with no-new-privileges=false)\n'
  else
    printf 'sudo-mode=off (agent services run with no-new-privileges=true)\n'
  fi
}

cmd_sudo_mode() {
  local action="${1:-status}"
  local desired_nnp=""

  case "${action}" in
    status)
      print_sudo_mode
      ;;
    on)
      desired_nnp="false"
      ;;
    off)
      desired_nnp="true"
      ;;
    *)
      die "Usage: agent sudo-mode [status|on|off]"
      ;;
  esac

  [[ -n "${desired_nnp}" ]] || return 0

  ensure_runtime_env
  set_runtime_env_value "AGENTIC_AGENT_NO_NEW_PRIVILEGES" "${desired_nnp}"
  AGENTIC_AGENT_NO_NEW_PRIVILEGES="${desired_nnp}"
  export AGENTIC_AGENT_NO_NEW_PRIVILEGES

  if [[ "${action}" == "on" ]]; then
    warn "sudo-mode=on relaxes hardening for agent services (no-new-privileges=false)"
  fi

  ensure_agents_runtime
  run_compose_on_targets up agents -d
  print_sudo_mode
}

cmd_ensure_release_manifest() {
  local -a selected_targets=("$@")
  local -a compose_files=()
  local -A seen_compose=()
  local target compose_file
  local current_release_dir="${AGENTIC_ROOT}/deployments/current"
  local current_release_images="${current_release_dir}/images.json"
  local release_id

  if [[ "${AGENTIC_DISABLE_AUTO_SNAPSHOT:-0}" == "1" ]]; then
    return 0
  fi

  [[ ! -s "${current_release_images}" ]] || return 0

  if ! docker ps --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" --format '{{.ID}}' | grep -q .; then
    return 0
  fi

  [[ -x "${AGENT_RELEASE_SNAPSHOT_SCRIPT}" ]] || return 0

  if [[ "${#selected_targets[@]}" -gt 0 ]]; then
    for target in "${selected_targets[@]}"; do
      compose_file="$(stack_to_compose_file "${target}")" || continue
      [[ -f "${compose_file}" ]] || continue
      if [[ -z "${seen_compose[${compose_file}]:-}" ]]; then
        compose_files+=("${compose_file}")
        seen_compose["${compose_file}"]=1
      fi
    done
  fi

  if [[ "${#compose_files[@]}" -eq 0 ]]; then
    mapfile -t compose_files < <(existing_compose_files)
  fi

  set +e
  release_id="$("${AGENT_RELEASE_SNAPSHOT_SCRIPT}" --reason up-auto-bootstrap "${compose_files[@]}" 2>/tmp/agent-auto-snapshot.out)"
  rc=$?
  set -e

  if [[ "${rc}" -eq 0 && -n "${release_id}" ]]; then
    printf 'auto snapshot created release=%s\n' "${release_id}"
  else
    warn "unable to create automatic release snapshot after up"
    if [[ -s /tmp/agent-auto-snapshot.out ]]; then
      cat /tmp/agent-auto-snapshot.out >&2
    fi
  fi
}

cmd_update() {
  ensure_runtime_env
  require_cmd docker
  [[ -x "${AGENT_RELEASE_SNAPSHOT_SCRIPT}" ]] || die "snapshot script missing: ${AGENT_RELEASE_SNAPSHOT_SCRIPT}"

  local -a compose_files=()
  mapfile -t compose_files < <(existing_compose_files)
  [[ "${#compose_files[@]}" -gt 0 ]] || die "No compose files available to update"

  local resolution_dir
  resolution_dir="$(mktemp -d)"
  cleanup_cmd_update_resolution() {
    rm -rf "${resolution_dir}"
  }
  trap cleanup_cmd_update_resolution RETURN

  resolve_update_latest_inputs "${resolution_dir}" "${compose_files[@]}"
  apply_resolved_runtime_env_file "${resolution_dir}/runtime.resolved.env"

  local -a compose_args=()
  local compose_file
  for compose_file in "${compose_files[@]}"; do
    compose_args+=("-f" "${compose_file}")
  done
  compose_args+=("-f" "${resolution_dir}/compose.resolved.override.yml")

  if [[ -f "$(stack_to_compose_file core)" ]]; then
    build_core_local_images "$(stack_to_compose_file core)"
  fi
  if [[ -f "$(stack_to_compose_file agents)" ]]; then
    build_agents_local_images "$(stack_to_compose_file agents)"
  fi

  local -a pull_cmd=(
    docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" "${compose_args[@]}" pull --ignore-pull-failures
  )
  if docker compose pull --help 2>/dev/null | grep -q -- "--ignore-buildable"; then
    pull_cmd+=(--ignore-buildable)
  fi

  "${pull_cmd[@]}"
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" "${compose_args[@]}" up -d --remove-orphans
  apply_core_network_policy

  local release_id
  release_id="$("${AGENT_RELEASE_SNAPSHOT_SCRIPT}" --reason update --compose-override "${resolution_dir}/compose.resolved.override.yml" "${compose_files[@]}")"
  capture_update_resolution_artifacts "${release_id}" "${resolution_dir}"
  printf 'update completed, release=%s\n' "${release_id}"
}

cmd_rollback() {
  local scope="${1:-}"
  local target_id="${2:-}"
  ensure_runtime_env

  case "${scope}" in
    all)
      [[ -n "${target_id}" ]] || die "Usage: agent rollback all <release_id>"
      [[ -x "${AGENT_RELEASE_ROLLBACK_SCRIPT}" ]] || die "rollback script missing: ${AGENT_RELEASE_ROLLBACK_SCRIPT}"
      "${AGENT_RELEASE_ROLLBACK_SCRIPT}" "${target_id}"
      apply_core_network_policy
      ;;
    host-net)
      [[ -n "${target_id}" ]] || die "Usage: agent rollback host-net <backup_id>"
      [[ -x "${AGENT_DOCKER_USER_ROLLBACK_SCRIPT}" ]] || die "host-net rollback script missing: ${AGENT_DOCKER_USER_ROLLBACK_SCRIPT}"
      "${AGENT_DOCKER_USER_ROLLBACK_SCRIPT}" "${target_id}"
      ;;
    ollama-link)
      [[ -n "${target_id}" ]] || die "Usage: agent rollback ollama-link <backup_id|latest>"
      [[ -x "${AGENT_OLLAMA_LINK_ROLLBACK_SCRIPT}" ]] || die "ollama-link rollback script missing: ${AGENT_OLLAMA_LINK_ROLLBACK_SCRIPT}"
      "${AGENT_OLLAMA_LINK_ROLLBACK_SCRIPT}" "${target_id}"
      ;;
    *)
      die "Usage: agent rollback all <release_id> | agent rollback host-net <backup_id> | agent rollback ollama-link <backup_id|latest>"
      ;;
  esac
}

normalize_logs_target() {
  local target="$1"
  case "${target}" in
    claude|codex|opencode|vibestral|openclaw|pi-mono|goose) tool_to_service "${target}" ;;
    *) printf '%s\n' "${target}" ;;
  esac
}

resolve_logs_container() {
  local normalized_target="$1"
  local cid
  cid="$(service_container_id "${normalized_target}" 2>/dev/null || true)"
  if [[ -n "${cid}" ]]; then
    printf '%s\n' "${cid}"
    return 0
  fi
  printf '%s\n' "${normalized_target}"
}

run_tests() {
  local selector="$1"
  local previous_test_mode
  local restore_test_mode=0
  local gate_cid=""
  local rag_retriever_cid=""
  local rag_worker_cid=""
  local -a tests=()

  if [[ "$selector" == "all" ]]; then
    mapfile -t tests < <(
      find "${AGENTIC_TEST_DIR}" -maxdepth 1 -type f -regextype posix-extended \
        -regex '.*/([0-9]+|[A-Z]([0-9]+[a-z]?)?)_.*\.sh' | sort
    )
  elif [[ "$selector" =~ ^[A-LV]$ ]]; then
    mapfile -t tests < <(
      find "${AGENTIC_TEST_DIR}" -maxdepth 1 -type f -regextype posix-extended \
        -regex ".*/${selector}([0-9]+[a-z]?)?_.*\\.sh" | sort
    )
  else
    die "Invalid test selector '$selector'. Expected one of A..L, V, or all."
  fi

  [[ "${#tests[@]}" -gt 0 ]] || die "No test scripts found for selector '$selector'."

  gate_cid="$(service_container_id "ollama-gate" || true)"
  if [[ -n "${gate_cid}" ]]; then
    # Keep gate bind-mounted state/config readable for non-root gate before any selector.
    ensure_core_runtime
  fi
  rag_retriever_cid="$(service_container_id "rag-retriever" || true)"
  rag_worker_cid="$(service_container_id "rag-worker" || true)"
  if [[ -n "${rag_retriever_cid}" || -n "${rag_worker_cid}" ]]; then
    # Keep rag runtime dirs traversable for non-root retriever/worker containers.
    ensure_rag_runtime
  fi
  previous_test_mode="$(normalize_gate_test_mode_value "${GATE_ENABLE_TEST_MODE:-0}")"
  if [[ -n "${gate_cid}" && "${previous_test_mode}" != "1" ]]; then
    printf 'INFO: enabling llm test-mode=on for agent test run\n'
    set_gate_test_mode_value "1" "1"
    restore_test_mode=1
  fi

  local test_script
  local rc=0
  set +e
  for test_script in "${tests[@]}"; do
    echo "RUN ${test_script}"
    bash "${test_script}"
    rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      break
    fi
  done
  set -e

  if [[ "${restore_test_mode}" == "1" ]]; then
    printf 'INFO: restoring llm test-mode=off after agent test run\n'
    set_gate_test_mode_value "${previous_test_mode}" "1"
  fi

  [[ "${rc}" -eq 0 ]] || return "${rc}"
}

load_runtime_env

cmd="${1:-}"
[[ -n "$cmd" ]] || {
  usage
  exit 1
}

case "$cmd" in
  profile)
    cmd_profile
    ;;
  first-up)
    shift
    cmd_first_up "$@"
    ;;
  up)
    [[ $# -ge 2 ]] || die "Usage: agent up <core|agents|ui|obs|rag|optional>"
    target_arg="$2"
    if [[ "${target_arg}" == "all" ]]; then
      target_arg="core,agents,ui,obs,rag"
    fi
    read -r -a targets <<<"$(parse_targets "$target_arg")"
    ensure_runtime_env

    if targets_include "core" "${targets[@]}"; then
      ensure_core_runtime
      build_core_local_images "$(stack_to_compose_file core)"
    fi
    if targets_include "agents" "${targets[@]}"; then
      ensure_agents_runtime
      build_agents_local_images "$(stack_to_compose_file agents)"
    fi
    if targets_include "obs" "${targets[@]}"; then
      ensure_obs_runtime
    fi
    if targets_include "ui" "${targets[@]}"; then
      ensure_ui_runtime
    fi
    if targets_include "rag" "${targets[@]}"; then
      ensure_rag_runtime
    fi
    if targets_include "optional" "${targets[@]}"; then
      non_optional_targets=()
      optional_profiles=(--profile optional)
      optional_compose_file="$(stack_to_compose_file optional)"
      optional_modules=()
      for target in "${targets[@]}"; do
        [[ "${target}" == "optional" ]] && continue
        non_optional_targets+=("${target}")
      done

      if [[ "${#non_optional_targets[@]}" -gt 0 ]]; then
        run_compose_on_targets up "$(join_targets_csv "${non_optional_targets[@]}")" -d
      fi

      if [[ "${AGENTIC_SKIP_OPTIONAL_GATING:-0}" != "1" ]]; then
        if ! "${AGENT_DOCTOR_SCRIPT}" >/tmp/agent-optional-gate.out 2>&1; then
          cat /tmp/agent-optional-gate.out >&2
          die "optional stack gating refused because 'agent doctor' is not green (set AGENTIC_SKIP_OPTIONAL_GATING=1 to bypass intentionally)"
        fi
      else
        warn "skipping optional stack doctor gating because AGENTIC_SKIP_OPTIONAL_GATING=1"
      fi

      ensure_optional_runtime
      mapfile -t optional_modules < <(parse_optional_modules)
      if [[ "${#optional_modules[@]}" -gt 0 ]]; then
        for optional_module in "${optional_modules[@]}"; do
          validate_optional_module_prereqs "${optional_module}"
          optional_profiles+=(--profile "$(optional_module_profile "${optional_module}")")
          log_optional_activation "${optional_module}"
        done
        build_optional_module_images "${optional_compose_file}" "${optional_modules[@]}"
      fi

      require_cmd docker
      docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" \
        "${optional_profiles[@]}" \
        -f "${optional_compose_file}" up -d

      if targets_include "git-forge" "${optional_modules[@]}"; then
        [[ -x "${AGENT_GIT_FORGE_BOOTSTRAP_SCRIPT}" ]] || die "git-forge bootstrap script missing or not executable: ${AGENT_GIT_FORGE_BOOTSTRAP_SCRIPT}"
        if ! "${AGENT_GIT_FORGE_BOOTSTRAP_SCRIPT}"; then
          die "git-forge bootstrap failed; inspect optional-forgejo logs and runtime secrets under ${AGENTIC_ROOT}/secrets/runtime/git-forge"
        fi
      fi
    else
      run_compose_on_targets up "$target_arg" -d
    fi

    if targets_include "core" "${targets[@]}"; then
      apply_core_network_policy
    fi
    cmd_ensure_release_manifest "${targets[@]}"
    ;;
  down)
    [[ $# -ge 2 ]] || die "Usage: agent down <core|agents|ui|obs|rag|optional>"
    target_arg="$2"
    read -r -a targets <<<"$(parse_targets "$target_arg")"
    if targets_include "optional" "${targets[@]}"; then
      non_optional_targets=()
      rag_requested=0
      for target in "${targets[@]}"; do
        [[ "${target}" == "optional" ]] && continue
        if [[ "${target}" == "rag" ]]; then
          rag_requested=1
          continue
        fi
        non_optional_targets+=("${target}")
      done

      if [[ "${#non_optional_targets[@]}" -gt 0 ]]; then
        run_compose_on_targets down "$(join_targets_csv "${non_optional_targets[@]}")"
      fi
      if [[ "${rag_requested}" -eq 1 ]]; then
        down_rag_compose_with_profiles
      fi

      require_cmd docker
      docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" \
        --profile optional \
        --profile optional-mcp \
        --profile optional-pi-mono \
        --profile optional-goose \
        --profile optional-portainer \
        -f "$(stack_to_compose_file optional)" down
    else
      if targets_include "rag" "${targets[@]}"; then
        non_rag_targets=()
        for target in "${targets[@]}"; do
          [[ "${target}" == "rag" ]] && continue
          non_rag_targets+=("${target}")
        done
        if [[ "${#non_rag_targets[@]}" -gt 0 ]]; then
          run_compose_on_targets down "$(join_targets_csv "${non_rag_targets[@]}")"
        fi
        down_rag_compose_with_profiles
      else
        run_compose_on_targets down "$target_arg"
      fi
    fi
    ;;
  stack)
    [[ $# -ge 2 ]] || die "Usage: agent stack <start|stop> <core|agents|ui|obs|rag|optional|all>"
    cmd_stack "$2" "${3:-all}"
    ;;
  openclaw)
    case "${2:-}" in
      init)
        shift 2
        cmd_openclaw_init "$@"
        ;;
      status|policy|model|sandbox)
        openclaw_action="${2:-}"
        shift 2
        cmd_openclaw_operator "${openclaw_action}" "$@"
        ;;
      approvals)
        shift 2
        cmd_openclaw_approvals "$@"
        ;;
      *)
        shift
        cmd_tool_attach "${cmd}" "${1:-}"
        ;;
    esac
    ;;
  claude|codex|opencode|vibestral|pi-mono|goose)
    shift
    cmd_tool_attach "${cmd}" "${1:-}"
    ;;
  ls)
    cmd_ls
    ;;
  status)
    cmd_status
    ;;
  ps)
    require_cmd docker
    docker ps \
      --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
    ;;
  llm)
    shift
    cmd_llm "$@"
    ;;
  comfyui)
    shift
    cmd_comfyui "$@"
    ;;
  logs)
    [[ $# -ge 2 ]] || die "Usage: agent logs <service>"
    require_cmd docker
    normalized_logs_target="$(normalize_logs_target "$2")"
    docker logs --tail "${AGENT_LOG_TAIL:-200}" -f "$(resolve_logs_container "${normalized_logs_target}")"
    ;;
  stop)
    [[ $# -ge 2 ]] || die "Usage: agent stop <target> | agent stop service <service...> | agent stop container <container...>"
    case "${2}" in
      service)
        shift 2
        [[ $# -gt 0 ]] || die "Usage: agent stop service <service...>"
        cmd_service_action stop "$@"
        ;;
      container)
        shift 2
        [[ $# -gt 0 ]] || die "Usage: agent stop container <container...>"
        cmd_container_action stop "$@"
        ;;
      *)
        cmd_stop_target "$2"
        ;;
    esac
    ;;
  start)
    [[ $# -ge 2 ]] || die "Usage: agent start <target> | agent start service <service...> | agent start container <container...>"
    case "${2}" in
      service)
        shift 2
        [[ $# -gt 0 ]] || die "Usage: agent start service <service...>"
        cmd_service_action start "$@"
        ;;
      container)
        shift 2
        [[ $# -gt 0 ]] || die "Usage: agent start container <container...>"
        cmd_container_action start "$@"
        ;;
      *)
        cmd_start_target "$2"
        ;;
    esac
    ;;
  backup)
    shift
    cmd_backup "$@"
    ;;
  forget)
    shift
    cmd_forget "$@"
    ;;
  net)
    shift
    cmd_net "${1:-}"
    ;;
  ollama)
    shift
    cmd_ollama "$@"
    ;;
  trtllm)
    shift
    cmd_trtllm "$@"
    ;;
  sudo-mode)
    shift
    cmd_sudo_mode "${1:-status}"
    ;;
  ollama-link)
    cmd_ollama_link
    ;;
  ollama-drift)
    shift
    cmd_ollama_drift "${1:-watch}" "${@:2}"
    ;;
  ollama-models)
    [[ $# -le 2 ]] || die "Usage: agent ollama-models [status|rw|ro]"
    cmd_ollama_models "${2:-status}"
    ;;
  ollama-preload)
    shift
    cmd_ollama_preload "$@"
    ;;
  update)
    cmd_update
    ;;
  rollback)
    [[ $# -ge 3 ]] || die "Usage: agent rollback all <release_id> | agent rollback host-net <backup_id> | agent rollback ollama-link <backup_id|latest>"
    cmd_rollback "$2" "$3"
    ;;
  onboard)
    shift
    cmd_onboard "$@"
    ;;
  prereqs)
    shift
    cmd_prereqs "$@"
    ;;
  vm)
    shift
    cmd_vm "$@"
    ;;
  test)
    [[ $# -ge 2 ]] || die "Usage: agent test <A|B|...|L|V|all> [--skip-d5-tests]"
    selector="$2"
    shift 2
    skip_d5_tests="${AGENTIC_SKIP_D5_TESTS:-0}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --skip-d5-tests)
          skip_d5_tests=1
          shift
          ;;
        *)
          die "Usage: agent test <A|B|...|L|V|all> [--skip-d5-tests]"
          ;;
      esac
    done
    AGENTIC_SKIP_D5_TESTS="${skip_d5_tests}" run_tests "${selector}"
    ;;
  cleanup)
    shift
    cmd_cleanup "$@"
    ;;
  doctor)
    shift
    exec "${SCRIPT_DIR}/doctor.sh" "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    die "Unknown command: $cmd"
    ;;
esac
