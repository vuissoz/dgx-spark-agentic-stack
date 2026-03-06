#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"
# shellcheck source=tests/lib/common.sh
source "${AGENTIC_REPO_ROOT}/tests/lib/common.sh"

status=0
fix_net=0

warn() {
  echo "WARN: $*" >&2
}

doctor_fail() {
  echo "FAIL: $*" >&2
  status=1
}

doctor_fail_or_warn() {
  local message="$1"
  if [[ "${AGENTIC_PROFILE}" == "strict-prod" ]]; then
    doctor_fail "${message}"
  else
    warn "${message}"
  fi
}

usage() {
  cat <<USAGE
Usage:
  agent doctor [--fix-net]

Environment:
  AGENTIC_PROFILE=strict-prod|rootless-dev
USAGE
}

critical_ports=()
if [[ -n "${AGENTIC_DOCTOR_CRITICAL_PORTS:-}" ]]; then
  read -r -a critical_ports <<<"${AGENTIC_DOCTOR_CRITICAL_PORTS//,/ }"
fi
portainer_host_port="${PORTAINER_HOST_PORT:-9001}"
openclaw_webhook_host_port="${OPENCLAW_WEBHOOK_HOST_PORT:-18111}"

service_requires_proxy_env() {
  local service="$1"
  case "${service}" in
    agentic-claude|agentic-codex|agentic-opencode|agentic-vibestral|openwebui|openhands|comfyui|optional-openclaw|optional-openclaw-sandbox|optional-mcp-catalog|optional-pi-mono|optional-goose|ollama-gate)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

service_allows_root_user() {
  local service="$1"
  case "${service}" in
    ollama|unbound|egress-proxy|promtail|cadvisor|dcgm-exporter)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

service_allows_readwrite_rootfs() {
  local service="$1"
  case "${service}" in
    ollama|egress-proxy|opensearch)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

service_is_agent_cli() {
  local service="$1"
  case "${service}" in
    agentic-claude|agentic-codex|agentic-opencode|agentic-vibestral)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

assert_agent_sudo_mode_hardening() {
  local cid="$1"
  local inspect_out readonly cap_drop security_opt

  inspect_out="$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}|{{join .HostConfig.CapDrop ","}}|{{json .HostConfig.SecurityOpt}}' "${cid}" 2>/dev/null)" \
    || fail "cannot inspect container ${cid}"

  IFS='|' read -r readonly cap_drop security_opt <<<"${inspect_out}"

  [[ "${readonly}" == "true" ]] || {
    fail "${cid}: readonly rootfs is not enabled"
    return 1
  }
  [[ ",${cap_drop}," == *",ALL,"* ]] || {
    fail "${cid}: cap_drop does not include ALL"
    return 1
  }
  [[ "${security_opt}" == *"no-new-privileges:false"* ]] || {
    fail "${cid}: expected no-new-privileges:false in sudo mode"
    return 1
  }

  return 0
}

mount_destination_present() {
  local cid="$1"
  local destination="$2"
  local mounts
  mounts="$(docker inspect --format '{{range .Mounts}}{{printf "%s|%v\n" .Destination .RW}}{{end}}' "${cid}" 2>/dev/null || true)"
  awk -F'|' -v d="${destination}" '$1 == d { found=1 } END { exit(found ? 0 : 1) }' <<<"${mounts}"
}

mount_destination_read_only() {
  local cid="$1"
  local destination="$2"
  local mounts
  mounts="$(docker inspect --format '{{range .Mounts}}{{printf "%s|%v\n" .Destination .RW}}{{end}}' "${cid}" 2>/dev/null || true)"
  awk -F'|' -v d="${destination}" '$1 == d && $2 == "false" { found=1 } END { exit(found ? 0 : 1) }' <<<"${mounts}"
}

allowlist_has_entry() {
  local allowlist_file="$1"
  local entry="$2"
  grep -Fxiq -- "${entry}" "${allowlist_file}"
}

parse_memory_to_bytes() {
  local raw="${1:-}"
  local value unit factor

  [[ -n "${raw}" ]] || return 1
  raw="${raw,,}"
  if [[ "${raw}" =~ ^([0-9]+)([kmgt]?i?b?)?$ ]]; then
    value="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  else
    return 1
  fi

  case "${unit}" in
    ""|b) factor=1 ;;
    k|kb|ki|kib) factor=1024 ;;
    m|mb|mi|mib) factor=$((1024 * 1024)) ;;
    g|gb|gi|gib) factor=$((1024 * 1024 * 1024)) ;;
    t|tb|ti|tib) factor=$((1024 * 1024 * 1024 * 1024)) ;;
    *) return 1 ;;
  esac

  printf '%s\n' "$((value * factor))"
}

check_default_model_context_resources() {
  local default_model="${AGENTIC_DEFAULT_MODEL:-}"
  local requested_context="${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-${OLLAMA_CONTEXT_LENGTH:-}}"
  local mem_limit_raw="${AGENTIC_LIMIT_OLLAMA_MEM:-}"
  local mem_limit_bytes=""
  local tags_file show_file report_file
  local report_line key value
  local model_max_context=0
  local kv_bytes_per_token=0
  local model_size_bytes=0
  local estimated_required_bytes=0
  local cleanup_context_check_files

  [[ -n "${default_model}" ]] || {
    doctor_fail_or_warn "AGENTIC_DEFAULT_MODEL is empty"
    return 0
  }

  if ! [[ "${requested_context}" =~ ^[0-9]+$ ]]; then
    doctor_fail_or_warn "default model context window must be numeric (AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW/OLLAMA_CONTEXT_LENGTH)"
    return 0
  fi
  (( requested_context >= 2048 )) || {
    doctor_fail_or_warn "default model context window must be >= 2048 tokens (got ${requested_context})"
    return 0
  }

  tags_file="$(mktemp)"
  show_file="$(mktemp)"
  report_file="$(mktemp)"
  cleanup_context_check_files() {
    rm -f "${tags_file}" "${show_file}" "${report_file}"
  }

  if ! curl -fsS --max-time 20 "http://127.0.0.1:11434/api/tags" >"${tags_file}"; then
    doctor_fail_or_warn "unable to read ollama tags from http://127.0.0.1:11434/api/tags"
    cleanup_context_check_files
    return 0
  fi

  if ! curl -fsS --max-time 20 \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${default_model}\"}" \
    "http://127.0.0.1:11434/api/show" >"${show_file}"; then
    doctor_fail_or_warn "unable to read ollama model metadata for '${default_model}' from /api/show"
    cleanup_context_check_files
    return 0
  fi

  if ! python3 - "${tags_file}" "${show_file}" "${default_model}" "${requested_context}" >"${report_file}" <<'PY'
import json
import sys

tags_path, show_path, default_model, requested_context_raw = sys.argv[1:5]
requested_context = int(requested_context_raw)


def first_suffix_number(payload, suffix):
    for key, value in payload.items():
        if key.endswith(suffix) and isinstance(value, (int, float)):
            return int(value)
    return 0


with open(tags_path, "r", encoding="utf-8") as fh:
    tags_payload = json.load(fh)
with open(show_path, "r", encoding="utf-8") as fh:
    show_payload = json.load(fh)

if isinstance(show_payload, dict) and show_payload.get("error"):
    raise SystemExit(f"api/show returned error for {default_model}: {show_payload.get('error')}")

models = tags_payload.get("models") or []
model_size_bytes = 0
exact_match = None
base_match = None
base_slug = default_model.split(":", 1)[0]

for entry in models:
    if not isinstance(entry, dict):
        continue
    name = str(entry.get("name", ""))
    if name == default_model:
        exact_match = entry
        break
    if name.split(":", 1)[0] == base_slug and base_match is None:
        base_match = entry

if exact_match is None:
    exact_match = base_match

if isinstance(exact_match, dict):
    size_raw = exact_match.get("size")
    if isinstance(size_raw, (int, float)):
        model_size_bytes = int(size_raw)

model_info = show_payload.get("model_info") or {}
model_max_context = first_suffix_number(model_info, ".context_length")
if model_max_context <= 0:
    model_max_context = requested_context

block_count = first_suffix_number(model_info, ".block_count")
kv_head_count = first_suffix_number(model_info, ".attention.head_count_kv")
if kv_head_count <= 0:
    kv_head_count = first_suffix_number(model_info, ".attention.head_count")
key_length = first_suffix_number(model_info, ".attention.key_length")
if key_length <= 0:
    embed_dim = first_suffix_number(model_info, ".embedding_length")
    head_count = first_suffix_number(model_info, ".attention.head_count")
    if embed_dim > 0 and head_count > 0:
        key_length = embed_dim // head_count

if block_count > 0 and kv_head_count > 0 and key_length > 0:
    # 2 (K+V) * layers * kv_heads * key_length * 2 bytes(fp16 cache)
    kv_bytes_per_token = 2 * block_count * kv_head_count * key_length * 2
else:
    # Conservative fallback when architecture metadata is not exposed.
    kv_bytes_per_token = 131072

estimated_required_bytes = model_size_bytes + (requested_context * kv_bytes_per_token) + (1024 * 1024 * 1024)

print(f"model_max_context={model_max_context}")
print(f"kv_bytes_per_token={kv_bytes_per_token}")
print(f"model_size_bytes={model_size_bytes}")
print(f"estimated_required_bytes={estimated_required_bytes}")
PY
  then
    doctor_fail_or_warn "unable to compute model/context resource estimate for '${default_model}'"
    cleanup_context_check_files
    return 0
  fi

  while IFS='=' read -r key value; do
    [[ -n "${key}" ]] || continue
    case "${key}" in
      model_max_context) model_max_context="${value}" ;;
      kv_bytes_per_token) kv_bytes_per_token="${value}" ;;
      model_size_bytes) model_size_bytes="${value}" ;;
      estimated_required_bytes) estimated_required_bytes="${value}" ;;
      *) ;;
    esac
  done <"${report_file}"

  if (( requested_context > model_max_context )); then
    doctor_fail_or_warn "configured context (${requested_context}) exceeds model max (${model_max_context}) for ${default_model}"
    cleanup_context_check_files
    return 0
  fi

  if mem_limit_bytes="$(parse_memory_to_bytes "${mem_limit_raw}")"; then
    if (( mem_limit_bytes < estimated_required_bytes )); then
      doctor_fail_or_warn "AGENTIC_LIMIT_OLLAMA_MEM=${mem_limit_raw} is likely insufficient for ${default_model} with context ${requested_context} (estimated >= $((estimated_required_bytes / 1024 / 1024 / 1024))GiB)"
      cleanup_context_check_files
      return 0
    fi
  fi

  ok "default model '${default_model}' context=${requested_context} (max=${model_max_context}, kv_bytes/token=${kv_bytes_per_token}, est_mem=$((estimated_required_bytes / 1024 / 1024 / 1024))GiB)"
  cleanup_context_check_files
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix-net)
      fix_net=1
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      doctor_fail "unknown doctor argument: $1"
      usage
      exit "$status"
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  doctor_fail "docker command not found; stack is not ready"
  exit "$status"
fi

if ! docker info >/dev/null 2>&1; then
  doctor_fail "docker daemon unavailable; stack is not ready"
  exit "$status"
fi

ok "doctor profile=${AGENTIC_PROFILE}"
if [[ "${AGENTIC_AGENT_NO_NEW_PRIVILEGES}" == "false" ]]; then
  warn "agent sudo-mode is enabled (AGENTIC_AGENT_NO_NEW_PRIVILEGES=false)"
fi

if [[ "${#critical_ports[@]}" -gt 0 ]]; then
  if ! assert_no_public_bind "${critical_ports[@]}"; then
    doctor_fail "one or more configured critical ports are exposed on a non-loopback interface"
  fi
else
  if ! assert_no_public_bind; then
    doctor_fail "one or more critical ports are exposed on a non-loopback interface"
  fi
fi

running_count="$(docker ps --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" --format '{{.Names}}' | wc -l | tr -d ' ')"
if [[ "$running_count" -eq 0 ]]; then
  doctor_fail "no containers deployed for compose project '${AGENTIC_COMPOSE_PROJECT}' (not ready)"
else
  ok "compose project '${AGENTIC_COMPOSE_PROJECT}' has ${running_count} running container(s)"
fi

if [[ "$fix_net" -eq 1 ]]; then
  if [[ "${AGENTIC_SKIP_DOCKER_USER_APPLY:-0}" == "1" ]]; then
    warn "skip network fix because AGENTIC_SKIP_DOCKER_USER_APPLY=1"
  else
    if "${AGENTIC_REPO_ROOT}/deployments/net/apply_docker_user.sh"; then
      ok "DOCKER-USER policy reapplied"
    else
      doctor_fail "unable to reapply DOCKER-USER policy"
    fi
  fi
fi

if [[ "${AGENTIC_SKIP_DOCKER_USER_CHECK:-0}" == "1" ]]; then
  warn "skip DOCKER-USER policy check because AGENTIC_SKIP_DOCKER_USER_CHECK=1"
else
  if ! assert_docker_user_policy; then
    doctor_fail_or_warn "DOCKER-USER policy is missing or incomplete"
  fi
fi

if [[ "${AGENTIC_SKIP_DOCTOR_PROXY_CHECK:-0}" != "1" ]]; then
  toolbox_cid="$(service_container_id toolbox)"
  if [[ -z "${toolbox_cid}" ]]; then
    doctor_fail_or_warn "toolbox container is not running; cannot validate egress policy"
  else
    set +e
    timeout 15 docker exec "${toolbox_cid}" sh -lc \
      'env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY curl -fsS --noproxy "*" --max-time 8 https://example.com >/dev/null'
    direct_rc=$?
    set -e

    if [[ "${direct_rc}" -eq 0 ]]; then
      doctor_fail_or_warn "direct egress from toolbox succeeded; proxy enforcement is broken"
    else
      ok "direct egress from toolbox is blocked"
    fi
  fi
else
  warn "skip proxy enforcement check because AGENTIC_SKIP_DOCTOR_PROXY_CHECK=1"
fi

mapfile -t running_services < <(
  docker ps \
    --filter "label=com.docker.compose.project=${AGENTIC_COMPOSE_PROJECT}" \
    --format '{{.ID}}|{{.Label "com.docker.compose.service"}}' | sort -t'|' -k2,2
)

for row in "${running_services[@]}"; do
  cid="${row%%|*}"
  service="${row#*|}"
  [[ -n "${cid}" && -n "${service}" ]] || continue

  state="$(docker inspect --format '{{.State.Status}}' "${cid}" 2>/dev/null || true)"
  healthcheck_cfg="$(docker inspect --format '{{if .Config.Healthcheck}}present{{else}}missing{{end}}' "${cid}" 2>/dev/null || true)"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}" 2>/dev/null || true)"

  if [[ "${state}" != "running" ]]; then
    doctor_fail "service '${service}' is not running (state=${state})"
    continue
  fi
  if [[ "${healthcheck_cfg}" != "present" ]]; then
    doctor_fail_or_warn "service '${service}' is missing a healthcheck"
    continue
  fi
  if [[ "${health}" != "healthy" ]]; then
    doctor_fail_or_warn "service '${service}' health is not healthy (health=${health})"
    continue
  fi
  ok "service '${service}' is running and healthy"

  if ! assert_no_docker_sock_mount "${cid}"; then
    doctor_fail_or_warn "docker.sock mount detected for service '${service}'"
  fi

  if service_allows_readwrite_rootfs "${service}"; then
    if ! assert_container_runtime_restrictions "${cid}"; then
      doctor_fail_or_warn "service '${service}' runtime restriction baseline failed"
    fi
  else
    if [[ "${AGENTIC_AGENT_NO_NEW_PRIVILEGES}" == "false" ]] && service_is_agent_cli "${service}"; then
      if ! assert_agent_sudo_mode_hardening "${cid}"; then
        doctor_fail_or_warn "service '${service}' hardening baseline failed in sudo mode"
      fi
    else
      if ! assert_container_hardening "${cid}"; then
        doctor_fail_or_warn "service '${service}' hardening baseline failed"
      fi
    fi
  fi

  if ! service_allows_root_user "${service}"; then
    if ! assert_container_non_root_user "${cid}"; then
      doctor_fail_or_warn "service '${service}' must run as non-root"
    fi
  fi

  if service_requires_proxy_env "${service}"; then
    if ! assert_proxy_enforced "${cid}"; then
      doctor_fail_or_warn "proxy env baseline failed for service '${service}'"
    fi
  fi

  if [[ "${service}" == "ollama" ]]; then
    env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${cid}" 2>/dev/null || true)"
    runtime_ctx="$(printf '%s\n' "${env_dump}" | sed -n 's/^OLLAMA_CONTEXT_LENGTH=//p' | head -n 1)"
    expected_ctx="${OLLAMA_CONTEXT_LENGTH:-${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-}}"
    if [[ -z "${runtime_ctx}" ]]; then
      doctor_fail_or_warn "ollama missing OLLAMA_CONTEXT_LENGTH env"
    elif [[ -n "${expected_ctx}" && "${runtime_ctx}" != "${expected_ctx}" ]]; then
      doctor_fail_or_warn "ollama context mismatch: runtime=${runtime_ctx} expected=${expected_ctx}"
    else
      ok "ollama context length is configured (${runtime_ctx} tokens)"
    fi
  fi

  if [[ "${service}" == "gate-mcp" ]]; then
    published="$(docker port "${cid}" 8123/tcp 2>/dev/null || true)"
    [[ -z "${published}" ]] || doctor_fail "gate-mcp must not publish host port 8123 (got: ${published})"

    env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${cid}" 2>/dev/null || true)"
    if ! echo "${env_dump}" | grep -q '^GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token$'; then
      doctor_fail "gate-mcp missing GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token"
    fi
    if ! echo "${env_dump}" | grep -q '^GATE_MCP_AUDIT_LOG=/logs/audit.jsonl$'; then
      doctor_fail "gate-mcp missing GATE_MCP_AUDIT_LOG=/logs/audit.jsonl"
    fi

    if ! mount_destination_present "${cid}" "/run/secrets/gate_mcp.token"; then
      doctor_fail "gate-mcp must mount /run/secrets/gate_mcp.token"
    elif ! mount_destination_read_only "${cid}" "/run/secrets/gate_mcp.token"; then
      doctor_fail "gate-mcp must mount /run/secrets/gate_mcp.token read-only"
    fi

    if ! mount_destination_present "${cid}" "/logs"; then
      doctor_fail "gate-mcp must mount /logs for audit persistence"
    fi
  fi

  if [[ "${service}" == "openwebui" ]]; then
    env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${cid}" 2>/dev/null || true)"
    openai_api_base_url="$(printf '%s\n' "${env_dump}" | sed -n 's/^OPENAI_API_BASE_URL=//p' | head -n 1)"
    ollama_base_url="$(printf '%s\n' "${env_dump}" | sed -n 's/^OLLAMA_BASE_URL=//p' | head -n 1)"
    enable_ollama_api_raw="$(printf '%s\n' "${env_dump}" | sed -n 's/^ENABLE_OLLAMA_API=//p' | head -n 1)"
    enable_ollama_api_norm="${enable_ollama_api_raw,,}"

    if [[ "${openai_api_base_url}" != "http://ollama-gate:11435/v1" ]]; then
      doctor_fail "openwebui must set OPENAI_API_BASE_URL=http://ollama-gate:11435/v1 (got: ${openai_api_base_url:-<unset>})"
    fi

    case "${enable_ollama_api_norm}" in
      1|true|yes|on)
        if [[ "${ollama_base_url}" == "http://ollama:11434" ]]; then
          warn "openwebui direct Ollama API is enabled (ENABLE_OLLAMA_API=true, OLLAMA_BASE_URL=http://ollama:11434): gate bypass is explicit and auditable"
        elif [[ "${ollama_base_url}" == "http://ollama-gate:11435" ]]; then
          warn "openwebui has ENABLE_OLLAMA_API=true but OLLAMA_BASE_URL points to ollama-gate; native model pull remains disabled"
        else
          doctor_fail_or_warn "openwebui ENABLE_OLLAMA_API=true uses unsupported OLLAMA_BASE_URL='${ollama_base_url:-<unset>}' (expected http://ollama:11434 for explicit direct mode)"
        fi
        ;;
      0|false|no|off|"")
        if [[ "${ollama_base_url}" != "http://ollama-gate:11435" ]]; then
          doctor_fail_or_warn "openwebui must keep OLLAMA_BASE_URL=http://ollama-gate:11435 when ENABLE_OLLAMA_API is disabled (got: ${ollama_base_url:-<unset>})"
        fi
        ;;
      *)
        doctor_fail_or_warn "openwebui has invalid ENABLE_OLLAMA_API='${enable_ollama_api_raw:-<unset>}'"
        ;;
    esac
  fi
done

rag_retriever_cid="$(service_container_id rag-retriever)"
if [[ -n "${rag_retriever_cid}" ]]; then
  published="$(docker port "${rag_retriever_cid}" 7111/tcp 2>/dev/null || true)"
  [[ -z "${published}" ]] || doctor_fail "rag-retriever must not publish host port 7111 (got: ${published})"
fi

rag_worker_cid="$(service_container_id rag-worker)"
if [[ -n "${rag_worker_cid}" ]]; then
  published="$(docker port "${rag_worker_cid}" 7112/tcp 2>/dev/null || true)"
  [[ -z "${published}" ]] || doctor_fail "rag-worker must not publish host port 7112 (got: ${published})"
fi

opensearch_cid="$(service_container_id opensearch)"
if [[ -n "${opensearch_cid}" ]]; then
  published="$(docker port "${opensearch_cid}" 9200/tcp 2>/dev/null || true)"
  [[ -z "${published}" ]] || doctor_fail "opensearch must not publish host port 9200 (got: ${published})"
fi

agents_found=0
for service in agentic-claude agentic-codex agentic-opencode agentic-vibestral; do
  cid="$(service_container_id "${service}")"
  [[ -n "${cid}" ]] || continue
  agents_found=1

  env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${cid}" 2>/dev/null || true)"
  if ! echo "${env_dump}" | grep -q '^GATE_MCP_URL=http://gate-mcp:8123$'; then
    doctor_fail "agent '${service}' missing GATE_MCP_URL=http://gate-mcp:8123"
  fi
  if ! echo "${env_dump}" | grep -q '^GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token$'; then
    doctor_fail "agent '${service}' missing GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token"
  fi
  if ! echo "${env_dump}" | grep -q '^HOME=/state/home$'; then
    doctor_fail "agent '${service}' must set HOME=/state/home"
  fi
  if ! echo "${env_dump}" | grep -q '^OLLAMA_BASE_URL=http://ollama-gate:11435$'; then
    doctor_fail "agent '${service}' must set OLLAMA_BASE_URL=http://ollama-gate:11435"
  fi

  if ! mount_destination_present "${cid}" "/run/secrets/gate_mcp.token"; then
    doctor_fail "agent '${service}' must mount /run/secrets/gate_mcp.token read-only"
  elif ! mount_destination_read_only "${cid}" "/run/secrets/gate_mcp.token"; then
    doctor_fail "agent '${service}' must mount /run/secrets/gate_mcp.token read-only"
  fi

  primary_cli="$(printf '%s\n' "${env_dump}" | awk -F= '/^AGENT_PRIMARY_CLI=/{print $2; exit}')"
  if [[ -z "${primary_cli}" ]]; then
    doctor_fail "agent '${service}' missing AGENT_PRIMARY_CLI"
  else
    if ! timeout 15 docker exec "${cid}" sh -lc "command -v ${primary_cli} >/dev/null"; then
      doctor_fail "agent '${service}' primary CLI '${primary_cli}' is missing"
    fi
  fi

  if ! timeout 15 docker exec "${cid}" sh -lc 'test -d /state/home && test -w /state/home'; then
    doctor_fail "agent '${service}' home directory is not writable (/state/home)"
  fi
  if ! timeout 15 docker exec "${cid}" sh -lc ". /state/bootstrap/ollama-gate-defaults.env && \
    test \"\${OPENAI_BASE_URL}\" = 'http://ollama-gate:11435/v1' && \
    test \"\${OPENAI_API_BASE_URL}\" = 'http://ollama-gate:11435/v1' && \
    test \"\${OPENAI_API_BASE}\" = 'http://ollama-gate:11435/v1' && \
    test \"\${ANTHROPIC_BASE_URL}\" = 'http://ollama-gate:11435' && \
    test \"\${ANTHROPIC_AUTH_TOKEN}\" = 'local-ollama'"; then
    doctor_fail "agent '${service}' bootstrap defaults must route OpenAI/Anthropic endpoints to ollama-gate"
  fi

  if [[ "${AGENTIC_AGENT_NO_NEW_PRIVILEGES}" == "false" ]]; then
    if ! timeout 15 docker exec "${cid}" sh -lc 'command -v sudo >/dev/null && sudo -n true'; then
      doctor_fail "agent '${service}' sudo-mode is enabled but sudo -n true failed"
    fi
  fi
done

if [[ "${agents_found}" -eq 0 ]]; then
  warn "no agent containers running; skipped agent confinement checks"
fi

gate_mcp_token_file="${AGENTIC_ROOT}/secrets/runtime/gate_mcp.token"
if [[ ! -s "${gate_mcp_token_file}" ]]; then
  doctor_fail "gate MCP token is missing or empty: ${gate_mcp_token_file}"
else
  token_mode="$(stat -c '%a' "${gate_mcp_token_file}" 2>/dev/null || true)"
  if [[ "${token_mode}" != "600" && "${token_mode}" != "640" ]]; then
    doctor_fail "gate MCP token permissions must be 600/640: ${gate_mcp_token_file} (mode=${token_mode:-unknown})"
  fi
fi

if [[ ! -d "${AGENTIC_ROOT}/gate/mcp/logs" ]]; then
  doctor_fail "gate MCP audit log directory is missing: ${AGENTIC_ROOT}/gate/mcp/logs"
fi

check_default_model_context_resources

comfyui_cid="$(service_container_id comfyui)"
if [[ -n "${comfyui_cid}" ]]; then
  allowlist_file="${AGENTIC_ROOT}/proxy/allowlist.txt"
  if [[ ! -f "${allowlist_file}" ]]; then
    doctor_fail_or_warn "proxy allowlist file is missing: ${allowlist_file}"
  else
    for required_domain in api.comfy.org registry.comfy.org; do
      if ! allowlist_has_entry "${allowlist_file}" "${required_domain}"; then
        doctor_fail_or_warn "proxy allowlist missing required ComfyUI domain '${required_domain}' in ${allowlist_file}"
      fi
    done
  fi
fi

optional_openclaw_cid="$(service_container_id optional-openclaw)"
if [[ -n "${optional_openclaw_cid}" ]]; then
  if ! assert_no_public_bind "${openclaw_webhook_host_port}"; then
    doctor_fail "optional openclaw webhook bind must stay loopback-only on port ${openclaw_webhook_host_port}"
  fi
fi

optional_portainer_cid="$(service_container_id optional-portainer)"
if [[ -n "${optional_portainer_cid}" ]]; then
  if ! assert_no_public_bind "${portainer_host_port}"; then
    doctor_fail "optional portainer host bind must stay loopback-only on port ${portainer_host_port}"
  fi
fi

current_release_dir="${AGENTIC_ROOT}/deployments/current"
if [[ ! -L "${current_release_dir}" && ! -d "${current_release_dir}" ]]; then
  doctor_fail_or_warn "no active release snapshot found at ${current_release_dir}"
else
  release_images_file="${current_release_dir}/images.json"
  if [[ ! -s "${release_images_file}" ]]; then
    legacy_release_images_file="$(find "${current_release_dir}" -mindepth 2 -maxdepth 2 -type f -name images.json 2>/dev/null | sort | tail -n 1 || true)"
    if [[ -n "${legacy_release_images_file}" && -s "${legacy_release_images_file}" ]]; then
      warn "legacy current release layout detected (${legacy_release_images_file}); run 'agent update' to migrate current/ to symlink mode"
      ok "active release images manifest is present"
    else
      doctor_fail_or_warn "active release is missing images manifest: ${release_images_file}"
    fi
  else
    ok "active release images manifest is present"
  fi
fi

if [[ "$status" -ne 0 ]]; then
  warn "doctor result: NOT READY"
else
  ok "doctor result: READY"
fi

exit "$status"
