#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"

AGENT_RUNTIME_ENV_FILE="${AGENTIC_ROOT}/deployments/runtime.env"
AGENT_RELEASE_SNAPSHOT_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/releases/snapshot.sh"
AGENT_RELEASE_ROLLBACK_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/releases/rollback.sh"
AGENT_BACKUP_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/backups/time_machine.sh"
AGENT_DOCKER_USER_ROLLBACK_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/net/rollback_docker_user.sh"
AGENT_DOCTOR_SCRIPT="${SCRIPT_DIR}/doctor.sh"
AGENT_PREREQS_SCRIPT="${AGENTIC_REPO_ROOT}/scripts/check_prereqs.sh"
AGENT_ONBOARD_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/bootstrap/onboarding_env.sh"
AGENT_OLLAMA_PRELOAD_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/ollama/preload_and_lock.sh"
AGENT_OLLAMA_LINK_SCRIPT="${AGENTIC_REPO_ROOT}/scripts/setup-ollama-models-link.sh"
AGENT_OLLAMA_LINK_ROLLBACK_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/ollama/rollback_models_link.sh"
AGENT_OLLAMA_DRIFT_WATCH_SCRIPT="${AGENTIC_REPO_ROOT}/scripts/ollama_drift_watch.sh"
AGENT_OLLAMA_DRIFT_SCHEDULE_SCRIPT="${AGENTIC_REPO_ROOT}/scripts/install_ollama_drift_watch_schedule.sh"
AGENT_VM_CREATE_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/vm/create_strict_prod_vm.sh"
AGENT_VM_TEST_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/vm/test_strict_prod_vm.sh"
AGENT_VM_CLEANUP_SCRIPT="${AGENTIC_REPO_ROOT}/deployments/vm/cleanup_strict_prod_vm.sh"
AGENT_TOOLS=(claude codex opencode vibestral)
OPTIONAL_MODULES=(openclaw mcp pi-mono goose portainer)
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
  agent <claude|codex|opencode|vibestral> [project]
  agent ls
  agent ps
  agent llm mode [local|hybrid|remote]
  agent llm test-mode [on|off]
  agent logs <service>
  agent stop <tool>
  agent stop service <service...>
  agent stop container <container...>
  agent start service <service...>
  agent start container <container...>
  agent backup <run|list|restore <snapshot_id> [--yes]>
  agent forget <target> [--yes] [--no-backup]
  agent cleanup [--yes] [--backup|--no-backup]
  agent net apply
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
  agent onboard [runtime flags...] [--openwebui-admin-email ... --openwebui-admin-password ... --default-model ... --default-model-context-window ... --grafana-admin-user ... --grafana-admin-password ... --openhands-llm-model ... --allowlist-domains ... --optional-modules ... --output ... --non-interactive --require-complete]
  agent vm create [--name ... --cpus ... --memory ... --disk ... --image ... --workspace-path ... --reuse-existing --mount-repo|--no-mount-repo --require-gpu --skip-bootstrap --dry-run]
  agent vm test [--name ... --workspace-path ... --test-selectors ... --require-gpu|--allow-no-gpu --skip-d5-tests --dry-run]
  agent vm cleanup [--name ... --yes --dry-run]
  agent test <A|B|C|D|E|F|G|H|I|J|K|L|V|all> [--skip-d5-tests]
  agent doctor [--fix-net]

Optional modules (disabled by default):
  AGENTIC_OPTIONAL_MODULES=openclaw,mcp,pi-mono,goose,portainer agent up optional
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
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
  return 1
}

agent_workspace_dir() {
  local tool="$1"
  case "${tool}" in
    claude) printf '%s\n' "${AGENTIC_CLAUDE_WORKSPACES_DIR}" ;;
    codex) printf '%s\n' "${AGENTIC_CODEX_WORKSPACES_DIR}" ;;
    opencode) printf '%s\n' "${AGENTIC_OPENCODE_WORKSPACES_DIR}" ;;
    vibestral) printf '%s\n' "${AGENTIC_VIBESTRAL_WORKSPACES_DIR}" ;;
    *) return 1 ;;
  esac
}

tool_to_service() {
  case "$1" in
    claude) echo "agentic-claude" ;;
    codex) echo "agentic-codex" ;;
    opencode) echo "agentic-opencode" ;;
    vibestral) echo "agentic-vibestral" ;;
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
    openclaw) echo "optional-openclaw" ;;
    mcp) echo "optional-mcp" ;;
    pi-mono) echo "optional-pi-mono" ;;
    goose) echo "optional-goose" ;;
    portainer) echo "optional-portainer" ;;
    *) return 1 ;;
  esac
}

optional_module_secret_files() {
  case "$1" in
    openclaw)
      printf '%s\n' \
        "${AGENTIC_ROOT}/secrets/runtime/openclaw.token" \
        "${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret"
      ;;
    mcp) printf '%s\n' "${AGENTIC_ROOT}/secrets/runtime/mcp.token" ;;
    pi-mono|goose|portainer) ;;
    *) return 1 ;;
  esac
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
  local -a secret_files=()

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
}

log_optional_activation() {
  local module="$1"
  local request_file="${AGENTIC_ROOT}/deployments/optional/${module}.request"
  local changes_log="${AGENTIC_ROOT}/deployments/changes.log"
  local actor="${SUDO_USER:-${USER:-unknown}}"

  install -d -m 0750 "${AGENTIC_ROOT}/deployments"
  touch "${changes_log}"
  chmod 0640 "${changes_log}" || true

  printf '%s optional module enabled module=%s actor=%s request=%s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${module}" "${actor}" "${request_file}" \
    >>"${changes_log}"
}

optional_module_build_services() {
  case "$1" in
    openclaw) echo "optional-openclaw" ;;
    mcp) echo "optional-mcp-catalog" ;;
    pi-mono) echo "optional-pi-mono" ;;
    goose) echo "" ;;
    portainer) echo "" ;;
    *) return 1 ;;
  esac
}

optional_module_build_stamp_key() {
  case "$1" in
    optional-openclaw|optional-mcp-catalog) echo "optional-modules-local" ;;
    optional-pi-mono) echo "agent-cli-base-local" ;;
    *) return 1 ;;
  esac
}

optional_module_image_ref() {
  case "$1" in
    optional-openclaw|optional-mcp-catalog) echo "agentic/optional-modules:local" ;;
    optional-pi-mono) echo "agentic/agent-cli-base:local" ;;
    *) return 1 ;;
  esac
}

optional_module_build_inputs() {
  case "$1" in
    optional-openclaw|optional-mcp-catalog)
      printf '%s\n' \
        "${AGENTIC_REPO_ROOT}/deployments/optional/Dockerfile" \
        "${AGENTIC_REPO_ROOT}/deployments/optional/optional_service.py"
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
    *)
      return 1
      ;;
  esac
}

core_service_stamp_key() {
  case "$1" in
    ollama-gate) echo "ollama-gate-local" ;;
    gate-mcp) echo "gate-mcp-local" ;;
    *) return 1 ;;
  esac
}

core_service_image_ref() {
  case "$1" in
    ollama-gate) echo "agentic/ollama-gate:local" ;;
    gate-mcp) echo "agentic/gate-mcp:local" ;;
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
    for file in "${files[@]}"; do
      sha256sum "${file}"
    done
  ) | sha256sum | awk '{print $1}'
}

build_core_local_images() {
  local core_compose_file="$1"
  local -a services=(ollama-gate gate-mcp)
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
    command -v codex claude opencode vibe openhands openclaw >/dev/null
    for cli in codex claude opencode vibe openhands openclaw; do
      test -f "/etc/agentic/${cli}-real-path"
    done
  ' || die "agent base image must expose codex/claude/opencode/vibe/openhands/openclaw command contract: ${image_ref}"
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

service_container_id() {
  local service="$1"
  docker ps \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.ID}}' | head -n 1
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
      AGENTIC_LLM_NETWORK|AGENTIC_LLM_MODE|GATE_ENABLE_TEST_MODE|AGENTIC_OPENAI_DAILY_TOKENS|AGENTIC_OPENAI_MONTHLY_TOKENS|AGENTIC_OPENAI_DAILY_REQUESTS|AGENTIC_OPENAI_MONTHLY_REQUESTS|AGENTIC_OPENROUTER_DAILY_TOKENS|AGENTIC_OPENROUTER_MONTHLY_TOKENS|AGENTIC_OPENROUTER_DAILY_REQUESTS|AGENTIC_OPENROUTER_MONTHLY_REQUESTS|GATE_MCP_RATE_LIMIT_RPS|GATE_MCP_RATE_LIMIT_BURST|GATE_MCP_HTTP_TIMEOUT_SEC|AGENTIC_DOCKER_USER_SOURCE_NETWORKS|AGENTIC_OLLAMA_MODELS_LINK|AGENTIC_OLLAMA_MODELS_TARGET_DIR|AGENTIC_AGENT_WORKSPACES_ROOT|AGENTIC_CLAUDE_WORKSPACES_DIR|AGENTIC_CODEX_WORKSPACES_DIR|AGENTIC_OPENCODE_WORKSPACES_DIR|AGENTIC_VIBESTRAL_WORKSPACES_DIR|AGENTIC_OPENHANDS_WORKSPACES_DIR|OLLAMA_MODELS_DIR|OLLAMA_CONTAINER_USER|QDRANT_CONTAINER_USER|GATE_CONTAINER_USER|TRTLLM_CONTAINER_USER|PROMETHEUS_CONTAINER_USER|GRAFANA_CONTAINER_USER|LOKI_CONTAINER_USER|PROMTAIL_CONTAINER_USER|AGENTIC_DEFAULT_MODEL|AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW|OLLAMA_CONTEXT_LENGTH|OLLAMA_MODELS_MOUNT_MODE|OLLAMA_PRELOAD_GENERATE_MODEL|OLLAMA_PRELOAD_EMBED_MODEL|OLLAMA_MODEL_STORE_BUDGET_GB|RAG_EMBED_MODEL|PROMTAIL_DOCKER_CONTAINERS_HOST_PATH|PROMTAIL_HOST_LOG_PATH|NODE_EXPORTER_HOST_ROOT_PATH|CADVISOR_HOST_ROOT_PATH|CADVISOR_DOCKER_LIB_HOST_PATH|CADVISOR_SYS_HOST_PATH|CADVISOR_DEV_DISK_HOST_PATH|AGENTIC_AGENT_BASE_BUILD_CONTEXT|AGENTIC_AGENT_BASE_DOCKERFILE|AGENTIC_AGENT_BASE_IMAGE|AGENTIC_AGENT_CLI_INSTALL_MODE|AGENTIC_AGENT_NO_NEW_PRIVILEGES|AGENTIC_CODEX_CLI_NPM_SPEC|AGENTIC_CLAUDE_CODE_NPM_SPEC|AGENTIC_OPENCODE_NPM_SPEC|AGENTIC_OPENHANDS_INSTALL_SCRIPT|AGENTIC_OPENCLAW_INSTALL_CLI_SCRIPT|AGENTIC_OPENCLAW_INSTALL_VERSION|AGENTIC_VIBE_INSTALL_SCRIPT|AGENTIC_LIMIT_DEFAULT_CPUS|AGENTIC_LIMIT_DEFAULT_MEM|AGENTIC_LIMIT_CORE_CPUS|AGENTIC_LIMIT_CORE_MEM|AGENTIC_LIMIT_AGENTS_CPUS|AGENTIC_LIMIT_AGENTS_MEM|AGENTIC_LIMIT_UI_CPUS|AGENTIC_LIMIT_UI_MEM|AGENTIC_LIMIT_OBS_CPUS|AGENTIC_LIMIT_OBS_MEM|AGENTIC_LIMIT_RAG_CPUS|AGENTIC_LIMIT_RAG_MEM|AGENTIC_LIMIT_OPTIONAL_CPUS|AGENTIC_LIMIT_OPTIONAL_MEM|AGENTIC_LIMIT_*)
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
    "AGENTIC_COMPOSE_PROJECT=${AGENTIC_COMPOSE_PROJECT}"
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
    "AGENTIC_OPENHANDS_INSTALL_SCRIPT=${AGENTIC_OPENHANDS_INSTALL_SCRIPT}"
    "AGENTIC_OPENCLAW_INSTALL_CLI_SCRIPT=${AGENTIC_OPENCLAW_INSTALL_CLI_SCRIPT}"
    "AGENTIC_OPENCLAW_INSTALL_VERSION=${AGENTIC_OPENCLAW_INSTALL_VERSION}"
    "AGENTIC_VIBE_INSTALL_SCRIPT=${AGENTIC_VIBE_INSTALL_SCRIPT}"
    "AGENTIC_LLM_MODE=${AGENTIC_LLM_MODE}"
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
    "OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}"
    "OLLAMA_MODELS_MOUNT_MODE=${OLLAMA_MODELS_MOUNT_MODE}"
    "OLLAMA_PRELOAD_GENERATE_MODEL=${OLLAMA_PRELOAD_GENERATE_MODEL}"
    "OLLAMA_PRELOAD_EMBED_MODEL=${OLLAMA_PRELOAD_EMBED_MODEL}"
    "OLLAMA_MODEL_STORE_BUDGET_GB=${OLLAMA_MODEL_STORE_BUDGET_GB}"
    "RAG_EMBED_MODEL=${RAG_EMBED_MODEL}"
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
  printf 'openhands_install_script=%s\n' "${AGENTIC_OPENHANDS_INSTALL_SCRIPT}"
  printf 'openclaw_install_cli_script=%s\n' "${AGENTIC_OPENCLAW_INSTALL_CLI_SCRIPT}"
  printf 'openclaw_install_version=%s\n' "${AGENTIC_OPENCLAW_INSTALL_VERSION}"
  printf 'vibe_install_script=%s\n' "${AGENTIC_VIBE_INSTALL_SCRIPT}"
  printf 'llm_mode=%s\n' "${AGENTIC_LLM_MODE}"
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
  printf 'ollama_context_length=%s\n' "${OLLAMA_CONTEXT_LENGTH}"
  printf 'ollama_models_mount_mode=%s\n' "${OLLAMA_MODELS_MOUNT_MODE}"
  printf 'ollama_preload_generate_model=%s\n' "${OLLAMA_PRELOAD_GENERATE_MODEL}"
  printf 'ollama_preload_embed_model=%s\n' "${OLLAMA_PRELOAD_EMBED_MODEL}"
  printf 'ollama_model_store_budget_gb=%s\n' "${OLLAMA_MODEL_STORE_BUDGET_GB}"
  printf 'rag_embed_model=%s\n' "${RAG_EMBED_MODEL}"
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

prepare_tool_session() {
  local tool="$1"
  local project="$2"
  local service container_id workspace defaults_file

  service="$(tool_to_service "${tool}")" || die "Unknown tool '${tool}'"
  container_id="$(service_container_id "${service}")"
  [[ -n "${container_id}" ]] || die "Service '${service}' is not running. Start it with: agent up agents"

  workspace="/workspace/${project}"
  defaults_file="/state/bootstrap/ollama-gate-defaults.env"
  docker exec "${container_id}" sh -lc "mkdir -p '${workspace}'"

  if ! docker exec "${container_id}" tmux has-session -t "${tool}" >/dev/null 2>&1; then
    docker exec "${container_id}" tmux new-session -d -s "${tool}" -c "${workspace}" \
      "bash -lc 'if [ -f \"${defaults_file}\" ]; then source \"${defaults_file}\"; fi; exec bash -l'"
  fi
  docker exec "${container_id}" sh -lc "tmux send-keys -t '${tool}' C-c"
  docker exec "${container_id}" sh -lc "tmux send-keys -t '${tool}' 'cd \"${workspace}\"' C-m"
}

cmd_tool_attach() {
  local tool="$1"
  local project="${2:-$(detect_project_name)}"
  local service container_id

  prepare_tool_session "${tool}" "${project}"
  service="$(tool_to_service "${tool}")"
  container_id="$(service_container_id "${service}")"

  printf 'INFO: %s uses a persistent tmux session. Detach with Ctrl-b d (session keeps running).\n' "${tool}"
  printf 'INFO: you are attaching to an existing shell in-container (not auto-running %s).\n' "${tool}"
  printf 'INFO: attach reset sends Ctrl-c, then cd to /workspace/%s; a running foreground command in that pane will be interrupted.\n' "${project}"
  printf 'INFO: use "exit" to close the pane/session; entrypoint will recreate an empty shell session automatically.\n'

  if [[ "${AGENT_NO_ATTACH:-0}" == "1" ]]; then
    printf 'prepared tool=%s project=%s container=%s\n' "${tool}" "${project}" "${container_id}"
    return 0
  fi

  exec docker exec -it "${container_id}" tmux attach-session -t "${tool}"
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

cmd_ls() {
  require_cmd docker

  printf 'tool\tservice\tstatus\ttmux\tworkspace\tsticky_model\n'

  local tool service container_id status tmux_status workspace_size sticky
  for tool in "${AGENT_TOOLS[@]}"; do
    service="$(tool_to_service "${tool}")"
    container_id="$(service_container_id "${service}")"

    status="down"
    tmux_status="-"
    if [[ -n "${container_id}" ]]; then
      status="$(docker inspect --format '{{.State.Status}}' "${container_id}" 2>/dev/null || echo unknown)"
      if docker exec "${container_id}" tmux has-session -t "${tool}" >/dev/null 2>&1; then
        tmux_status="up"
      else
        tmux_status="missing"
      fi
    fi

    local workspace_host_dir
    workspace_host_dir="$(agent_workspace_dir "${tool}")"
    if [[ -d "${workspace_host_dir}" ]]; then
      workspace_size="$(du -sh "${workspace_host_dir}" 2>/dev/null | awk '{print $1}')"
      workspace_size="${workspace_size:-0B}"
    else
      workspace_size="n/a"
    fi

    sticky="$(sticky_model_for_session "${tool}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${tool}" "${service}" "${status}" "${tmux_status}" "${workspace_size}" "${sticky}"
  done
}

cmd_stop_tool() {
  local tool="${1:-}"
  local service compose_file
  [[ -n "${tool}" ]] || die "Usage: agent stop <tool>"

  service="$(tool_to_service "${tool}")" || die "Unknown tool '${tool}'. Expected one of: ${AGENT_TOOLS[*]}"
  compose_file="$(stack_to_compose_file agents)"
  [[ -f "${compose_file}" ]] || die "Compose file not found for agents stack: ${compose_file}"

  require_cmd docker
  docker compose --project-name "${AGENTIC_COMPOSE_PROJECT}" -f "${compose_file}" stop "${service}"
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
      printf '%s\n' \
        "${AGENTIC_ROOT}/comfyui/models" \
        "${AGENTIC_ROOT}/comfyui/input" \
        "${AGENTIC_ROOT}/comfyui/output" \
        "${AGENTIC_ROOT}/comfyui/user" \
        "${AGENTIC_ROOT}/comfyui/custom_nodes"
      ;;
    openclaw)
      printf '%s\n' \
        "${AGENTIC_ROOT}/optional/openclaw/config" \
        "${AGENTIC_ROOT}/optional/openclaw/state" \
        "${AGENTIC_ROOT}/optional/openclaw/logs" \
        "${AGENTIC_ROOT}/optional/openclaw/sandbox/state"
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
        "${AGENTIC_ROOT}/optional/openclaw" \
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
    openclaw) printf '%s\n' optional-openclaw optional-openclaw-sandbox ;;
    openhands) printf '%s\n' openhands ;;
    openwebui) printf '%s\n' openwebui ;;
    qdrant) printf '%s\n' qdrant rag-retriever rag-worker opensearch ;;
    obs) printf '%s\n' prometheus grafana loki promtail node-exporter cadvisor dcgm-exporter ;;
    all)
      printf '%s\n' \
        optional-openclaw optional-openclaw-sandbox \
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
      --profile optional-openclaw \
      --profile optional-mcp \
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
    "agentic/comfyui:local"
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
  local answer confirmation confirmation_remove
  local export_dir="${AGENTIC_CLEANUP_EXPORT_DIR:-${AGENTIC_REPO_ROOT}/.runtime/cleanup-exports}"
  local backup_path=""
  local ts target
  local -a selected_targets=()
  local -a cleanup_images=()
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
      -h|--help|help)
        cat <<USAGE
Usage:
  agent cleanup [--yes] [--backup|--no-backup]
  agent strict-prod cleanup [--yes] [--backup|--no-backup]
  agent rootless-dev cleanup [--yes] [--backup|--no-backup]

Description:
  Stop the stack stepwise, optionally export a backup archive, then purge AGENTIC_ROOT
  to bring runtime state back to a fresh/brand-new state. Cleanup also removes local
  docker images associated with the stack.
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

  purge_runtime_root_symlink_safe "${AGENTIC_ROOT}"
  cleanup_rootless_ollama_models_link
  remove_cleanup_images_best_effort "${cleanup_images[@]}"
  install -d -m 0750 "${AGENTIC_ROOT}"

  printf 'cleanup completed root=%s\n' "${AGENTIC_ROOT}"
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
      local mode="${1:-}"
      local mode_file="${AGENTIC_ROOT}/gate/state/llm_mode.json"
      local actor="${SUDO_USER:-${USER:-unknown}}"
      local current_mode

      if [[ -z "${mode}" ]]; then
        if [[ -f "${mode_file}" ]]; then
          current_mode="$(python3 - "${mode_file}" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print("hybrid")
    raise SystemExit(0)

if isinstance(data, dict):
    mode = data.get("mode")
else:
    mode = data
if isinstance(mode, str) and mode.strip():
    print(mode.strip().lower())
else:
    print("hybrid")
PY
)"
          printf 'llm mode=%s\n' "${current_mode}"
        else
          printf 'llm mode=%s\n' "${AGENTIC_LLM_MODE:-hybrid}"
        fi
        return 0
      fi

      case "${mode}" in
        local|hybrid|remote) ;;
        *) die "Usage: agent llm mode [local|hybrid|remote]" ;;
      esac

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
      die "Usage: agent llm mode [local|hybrid|remote] | agent llm test-mode [on|off]"
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

  local -a compose_args=()
  local compose_file
  for compose_file in "${compose_files[@]}"; do
    compose_args+=("-f" "${compose_file}")
  done

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
  release_id="$("${AGENT_RELEASE_SNAPSHOT_SCRIPT}" --reason update "${compose_files[@]}")"
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
    claude|codex|opencode|vibestral) tool_to_service "${target}" ;;
    *) printf '%s\n' "${target}" ;;
  esac
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
        --profile optional-openclaw \
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
  claude|codex|opencode|vibestral)
    shift
    cmd_tool_attach "${cmd}" "${1:-}"
    ;;
  ls)
    cmd_ls
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
  logs)
    [[ $# -ge 2 ]] || die "Usage: agent logs <service>"
    require_cmd docker
    docker logs --tail "${AGENT_LOG_TAIL:-200}" -f "$(normalize_logs_target "$2")"
    ;;
  stop)
    [[ $# -ge 2 ]] || die "Usage: agent stop <tool> | agent stop service <service...> | agent stop container <container...>"
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
        cmd_stop_tool "$2"
        ;;
    esac
    ;;
  start)
    [[ $# -ge 3 ]] || die "Usage: agent start service <service...> | agent start container <container...>"
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
        die "Usage: agent start service <service...> | agent start container <container...>"
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
