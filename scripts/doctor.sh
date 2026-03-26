#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"
# shellcheck source=scripts/lib/ollama_context.sh
source "${SCRIPT_DIR}/lib/ollama_context.sh"
# shellcheck source=scripts/lib/model_compat.sh
source "${SCRIPT_DIR}/lib/model_compat.sh"
# shellcheck source=tests/lib/common.sh
source "${AGENTIC_REPO_ROOT}/tests/lib/common.sh"

status=0
fix_net=0
check_tool_stream_e2e=0

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
  agent doctor [--fix-net] [--check-tool-stream-e2e]

Environment:
  AGENTIC_PROFILE=strict-prod|rootless-dev
  AGENTIC_DOCTOR_STREAM_MODEL=<model> (default: AGENTIC_DEFAULT_MODEL)
  AGENTIC_DOCTOR_STREAM_TIMEOUT_SEC=<seconds> (default: 90)
  AGENTIC_DOCTOR_STREAM_GATE_QUEUE_TIMEOUT_SEC=<seconds> (default: 20)
USAGE
}

critical_ports=()
if [[ -n "${AGENTIC_DOCTOR_CRITICAL_PORTS:-}" ]]; then
  read -r -a critical_ports <<<"${AGENTIC_DOCTOR_CRITICAL_PORTS//,/ }"
fi
host_machine="$(uname -m 2>/dev/null || printf 'unknown')"
portainer_host_port="${PORTAINER_HOST_PORT:-9001}"
openclaw_webhook_host_port="${OPENCLAW_WEBHOOK_HOST_PORT:-18111}"
openclaw_gateway_host_port="${OPENCLAW_GATEWAY_HOST_PORT:-18789}"
openclaw_relay_host_port="${OPENCLAW_RELAY_HOST_PORT:-18112}"
goose_context_limit_expected="${AGENTIC_GOOSE_CONTEXT_LIMIT:-${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-262144}}"

service_requires_proxy_env() {
  local service="$1"
  case "${service}" in
    agentic-claude|agentic-codex|agentic-opencode|agentic-vibestral|openwebui|openhands|comfyui|openclaw|openclaw-gateway|openclaw-provider-bridge|openclaw-sandbox|openclaw-relay|optional-mcp-catalog|optional-pi-mono|optional-goose|ollama-gate)
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

mount_destination_matches_source() {
  local cid="$1"
  local destination="$2"
  local expected_source="$3"
  local actual_source expected_real actual_real

  actual_source="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "'"${destination}"'"}}{{println .Source}}{{end}}{{end}}' "${cid}" 2>/dev/null | head -n 1)"
  [[ -n "${actual_source}" ]] || return 1

  expected_real="$(readlink -f "${expected_source}" 2>/dev/null || printf '%s\n' "${expected_source}")"
  actual_real="$(readlink -f "${actual_source}" 2>/dev/null || printf '%s\n' "${actual_source}")"
  [[ "${actual_real}" == "${expected_real}" ]]
}

allowlist_has_entry() {
  local allowlist_file="$1"
  local entry="$2"
  grep -Fxiq -- "${entry}" "${allowlist_file}"
}

validate_openclaw_profile_file() {
  local profile_file="$1"
  python3 - "${profile_file}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))

if not isinstance(payload, dict):
    raise SystemExit("profile must be a JSON object")
for key in ("profile_id", "profile_version", "runtime", "upstream_contract"):
    if not payload.get(key):
        raise SystemExit(f"missing top-level key: {key}")

runtime = payload.get("runtime")
if not isinstance(runtime, dict):
    raise SystemExit("runtime must be an object")

required_env = runtime.get("required_env")
if not isinstance(required_env, dict):
    raise SystemExit("runtime.required_env must be an object")

for key in ("openclaw", "openclaw_sandbox"):
    values = required_env.get(key)
    if not isinstance(values, list) or not values:
        raise SystemExit(f"runtime.required_env.{key} must be a non-empty array")

endpoints = runtime.get("endpoints")
if not isinstance(endpoints, dict):
    raise SystemExit("runtime.endpoints must be an object")

required_endpoints = {
    "dm": "/v1/dm",
    "webhook_dm": "/v1/webhooks/dm",
    "tool_execute": "/v1/tools/execute",
    "sandbox_execute": "/v1/tools/execute",
    "profile": "/v1/profile",
}
for key, required_value in required_endpoints.items():
    values = endpoints.get(key)
    if not isinstance(values, list) or required_value not in values:
        raise SystemExit(f"runtime.endpoints.{key} must include {required_value}")
PY
}

check_default_model_context_resources() {
  local default_model="${AGENTIC_DEFAULT_MODEL:-}"
  local requested_context="${AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW:-${OLLAMA_CONTEXT_LENGTH:-}}"
  local mem_limit_raw="${AGENTIC_LIMIT_OLLAMA_MEM:-}"
  local mem_limit_bytes=0
  local report_file
  local key value
  local model_max_context=0
  local kv_bytes_per_token=0
  local estimated_required_bytes=0
  local estimated_required_gib=0
  local estimated_max_fitting_context=0
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

  report_file="$(mktemp)"
  cleanup_context_check_files() {
    rm -f "${report_file}"
  }

  if ! ollama_context_estimate_report "${default_model}" "${requested_context}" "${mem_limit_raw}" >"${report_file}" 2>/dev/null; then
    doctor_fail_or_warn "unable to compute model/context resource estimate for '${default_model}'"
    cleanup_context_check_files
    return 0
  fi

  while IFS='=' read -r key value; do
    [[ -n "${key}" ]] || continue
    case "${key}" in
      model_max_context) model_max_context="${value}" ;;
      kv_bytes_per_token) kv_bytes_per_token="${value}" ;;
      estimated_required_bytes) estimated_required_bytes="${value}" ;;
      mem_limit_bytes) mem_limit_bytes="${value}" ;;
      estimated_max_fitting_context) estimated_max_fitting_context="${value}" ;;
      *) ;;
    esac
  done <"${report_file}"

  if (( requested_context > model_max_context )); then
    doctor_fail_or_warn "configured context (${requested_context}) exceeds model max (${model_max_context}) for ${default_model}"
    cleanup_context_check_files
    return 0
  fi

  if (( estimated_required_bytes > 0 )); then
    estimated_required_gib="$(bytes_to_gib_ceil "${estimated_required_bytes}")"
  fi

  if (( mem_limit_bytes > 0 && requested_context > estimated_max_fitting_context )); then
    if (( estimated_max_fitting_context > 0 )); then
      doctor_fail_or_warn "AGENTIC_LIMIT_OLLAMA_MEM=${mem_limit_raw} is likely insufficient for ${default_model} with context ${requested_context} (estimated >= ${estimated_required_gib}GiB; estimated max fitting context=${estimated_max_fitting_context} tokens). Set AGENTIC_DEFAULT_MODEL_CONTEXT_WINDOW/OLLAMA_CONTEXT_LENGTH and AGENTIC_GOOSE_CONTEXT_LIMIT to <= ${estimated_max_fitting_context}, or raise AGENTIC_LIMIT_OLLAMA_MEM."
    else
      doctor_fail_or_warn "AGENTIC_LIMIT_OLLAMA_MEM=${mem_limit_raw} is likely insufficient to load ${default_model} at all (model size + safety overhead exceed the budget)."
    fi
    cleanup_context_check_files
    return 0
  fi

  ok "default model '${default_model}' context=${requested_context} (max=${model_max_context}, fit=${estimated_max_fitting_context}, kv_bytes/token=${kv_bytes_per_token}, est_mem=${estimated_required_gib}GiB)"
  cleanup_context_check_files
}

check_default_model_tool_call_compatibility() {
  local default_model="${AGENTIC_DEFAULT_MODEL:-}"
  local reason=""
  local recommendation=""

  [[ -n "${default_model}" ]] || return 0

  if reason="$(agentic_tool_call_model_incompatibility_reason "${default_model}")"; then
    recommendation="$(agentic_tool_call_model_recommendation "${default_model}" 2>/dev/null || true)"
    if [[ -n "${recommendation}" ]]; then
      doctor_fail "default model '${default_model}' is incompatible with the stack agentic tool-calling path: ${reason}; set AGENTIC_DEFAULT_MODEL='${recommendation}'"
    else
      doctor_fail "default model '${default_model}' is incompatible with the stack agentic tool-calling path: ${reason}"
    fi
  else
    ok "default model '${default_model}' passes tool-calling compatibility policy"
  fi
}

doctor_stream_payload() {
  local model="$1"
  local tool_name="$2"
  python3 - "${model}" "${tool_name}" <<'PY'
import json
import sys

model = sys.argv[1]
tool_name = sys.argv[2]
payload = {
    "model": model,
    "input": [
        {
            "role": "user",
            "content": [
                {
                    "type": "input_text",
                    "text": (
                        f"Doctor stream probe for {tool_name}. "
                        "Call doctor_probe exactly once and return no prose."
                    ),
                }
            ],
        }
    ],
    "tools": [
        {
            "type": "function",
            "function": {
                "name": "doctor_probe",
                "description": "Internal doctor stream probe tool",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "tool": {"type": "string"},
                        "check": {"type": "string"},
                    },
                    "required": ["tool", "check"],
                    "additionalProperties": False,
                },
            },
        }
    ],
    "tool_choice": {"type": "function", "function": {"name": "doctor_probe"}},
    "temperature": 0,
    "max_output_tokens": 64,
    "stream": True,
}
print(json.dumps(payload, separators=(",", ":")))
PY
}

doctor_validate_stream_response() {
  local stream_file="$1"
  python3 - "${stream_file}" <<'PY'
import json
import sys

stream_file = sys.argv[1]
function_done_seen = False
completed_seen = False
completed_has_function_call = False
for raw_line in open(stream_file, "r", encoding="utf-8"):
    line = raw_line.strip()
    if not line.startswith("data: "):
        continue
    payload = line[len("data: "):].strip()
    if payload in ("", "[DONE]"):
        continue
    event = json.loads(payload)
    event_type = event.get("type")
    if event_type == "response.function_call_arguments.done":
        arguments = event.get("arguments")
        if not isinstance(arguments, str) or not arguments.strip():
            raise SystemExit("function_call_arguments.done contains empty arguments")
        parsed = json.loads(arguments)
        if not isinstance(parsed, dict):
            raise SystemExit("function_call_arguments.done arguments must decode to object")
        function_done_seen = True
    elif event_type == "response.completed":
        completed_seen = True
        response = event.get("response")
        if not isinstance(response, dict):
            raise SystemExit("response.completed missing response payload")
        output = response.get("output")
        if not isinstance(output, list):
            raise SystemExit("response.completed output must be a list")
        for item in output:
            if not isinstance(item, dict):
                continue
            if item.get("type") != "function_call":
                continue
            if item.get("name") != "doctor_probe":
                continue
            args = item.get("arguments")
            if not isinstance(args, str) or not args.strip():
                raise SystemExit("response.completed function_call arguments are empty")
            decoded = json.loads(args)
            if not isinstance(decoded, dict):
                raise SystemExit("response.completed function_call arguments must decode to object")
            completed_has_function_call = True

if not function_done_seen:
    raise SystemExit("missing response.function_call_arguments.done event")
if not completed_seen:
    raise SystemExit("missing response.completed event")
if not completed_has_function_call:
    raise SystemExit("response.completed missing doctor_probe function_call for expected tool")
PY
}

check_streamed_tool_call_health() {
  local probe_model="${AGENTIC_DOCTOR_STREAM_MODEL:-${AGENTIC_DEFAULT_MODEL:-}}"
  local timeout_sec="${AGENTIC_DOCTOR_STREAM_TIMEOUT_SEC:-90}"
  local queue_timeout_sec="${AGENTIC_DOCTOR_STREAM_GATE_QUEUE_TIMEOUT_SEC:-20}"
  local tool service cid payload stream_file
  local -a targets=(
    "codex|agentic-codex"
    "claude|agentic-claude"
    "openhands|openhands"
    "opencode|agentic-opencode"
    "openclaw|openclaw"
    "pi-mono|optional-pi-mono"
    "goose|optional-goose"
  )

  if [[ -z "${probe_model}" ]]; then
    doctor_fail "streamed tool-call check requires AGENTIC_DEFAULT_MODEL or AGENTIC_DOCTOR_STREAM_MODEL"
    return 0
  fi

  if ! [[ "${timeout_sec}" =~ ^[0-9]+$ ]] || (( timeout_sec < 10 )); then
    doctor_fail "AGENTIC_DOCTOR_STREAM_TIMEOUT_SEC must be an integer >= 10 (got: ${timeout_sec})"
    return 0
  fi
  if ! [[ "${queue_timeout_sec}" =~ ^[0-9]+$ ]] || (( queue_timeout_sec < 1 )); then
    doctor_fail "AGENTIC_DOCTOR_STREAM_GATE_QUEUE_TIMEOUT_SEC must be an integer >= 1 (got: ${queue_timeout_sec})"
    return 0
  fi

  for target in "${targets[@]}"; do
    tool="${target%%|*}"
    service="${target#*|}"
    cid="$(service_container_id "${service}")"
    if [[ -z "${cid}" ]]; then
      doctor_fail "streamed tool-call check requires running service '${service}' for '${tool}'"
      continue
    fi

    if ! payload="$(doctor_stream_payload "${probe_model}" "${tool}")"; then
      doctor_fail "unable to build streamed tool-call probe payload for '${tool}'"
      continue
    fi

    stream_file="$(mktemp)"
    stream_err_file="$(mktemp)"
    if ! printf '%s' "${payload}" | timeout "${timeout_sec}" docker exec -i \
      -e AGENT_DOCTOR_SESSION="doctor-${tool}-$$" \
      -e AGENT_DOCTOR_QUEUE_TIMEOUT_SEC="${queue_timeout_sec}" \
      -e AGENT_DOCTOR_HTTP_TIMEOUT_SEC="${timeout_sec}" \
      "${cid}" sh -lc '
        set -eu
        request_file="$(mktemp)"
        trap "rm -f \"${request_file}\"" EXIT
        cat >"${request_file}"

        if command -v curl >/dev/null 2>&1; then
          curl -fsS --max-time "${AGENT_DOCTOR_HTTP_TIMEOUT_SEC}" \
            -H "Content-Type: application/json" \
            -H "X-Agent-Project: doctor" \
            -H "X-Agent-Session: ${AGENT_DOCTOR_SESSION}" \
            -H "X-Gate-Queue-Timeout-Seconds: ${AGENT_DOCTOR_QUEUE_TIMEOUT_SEC}" \
            --data-binary @"${request_file}" \
            "http://ollama-gate:11435/v1/responses"
          exit 0
        fi

        if command -v wget >/dev/null 2>&1; then
          wget -q -O- --timeout="${AGENT_DOCTOR_HTTP_TIMEOUT_SEC}" \
            --header="Content-Type: application/json" \
            --header="X-Agent-Project: doctor" \
            --header="X-Agent-Session: ${AGENT_DOCTOR_SESSION}" \
            --header="X-Gate-Queue-Timeout-Seconds: ${AGENT_DOCTOR_QUEUE_TIMEOUT_SEC}" \
            --post-file="${request_file}" \
            "http://ollama-gate:11435/v1/responses"
          exit 0
        fi

        if command -v python3 >/dev/null 2>&1; then
          python3 - "${request_file}" <<'"'"'PY'"'"'
import os
import pathlib
import sys
import urllib.request

request_file = pathlib.Path(sys.argv[1])
payload = request_file.read_bytes()
request = urllib.request.Request(
    "http://ollama-gate:11435/v1/responses",
    data=payload,
    headers={
        "Content-Type": "application/json",
        "X-Agent-Project": "doctor",
        "X-Agent-Session": os.environ.get("AGENT_DOCTOR_SESSION", "doctor"),
        "X-Gate-Queue-Timeout-Seconds": os.environ.get("AGENT_DOCTOR_QUEUE_TIMEOUT_SEC", "20"),
    },
    method="POST",
)
with urllib.request.urlopen(request, timeout=int(os.environ.get("AGENT_DOCTOR_HTTP_TIMEOUT_SEC", "90"))) as response:
    sys.stdout.buffer.write(response.read())
PY
          exit 0
        fi

        echo "missing curl/wget/python3 in service container" >&2
        exit 91
      ' >"${stream_file}" 2>"${stream_err_file}"; then
      err_hint="$(tr '\n' ' ' <"${stream_err_file}" | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
      if [[ -n "${err_hint}" ]]; then
        doctor_fail "streamed tool-call probe failed for '${tool}' (${service}): ${err_hint}"
      else
        doctor_fail "streamed tool-call probe failed for '${tool}' (${service})"
      fi
      rm -f "${stream_file}"
      rm -f "${stream_err_file}"
      continue
    fi

    if ! validation_err="$(doctor_validate_stream_response "${stream_file}" 2>&1)"; then
      if [[ -n "${validation_err}" ]]; then
        doctor_fail "streamed tool-call probe returned invalid events for '${tool}' (${service}): ${validation_err}"
      else
        doctor_fail "streamed tool-call probe returned invalid events for '${tool}' (${service})"
      fi
      rm -f "${stream_file}"
      rm -f "${stream_err_file}"
      continue
    fi

    ok "streamed tool-call probe passed for '${tool}' (${service})"
    rm -f "${stream_file}"
    rm -f "${stream_err_file}"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix-net)
      fix_net=1
      shift
      ;;
    --check-tool-stream-e2e|--check-tool-stream-health)
      check_tool_stream_e2e=1
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

  if [[ "${service}" == "comfyui" ]]; then
    if ! mount_destination_matches_source "${cid}" "/comfyui" "${AGENTIC_ROOT}/comfyui"; then
      doctor_fail_or_warn "comfyui must mount ${AGENTIC_ROOT}/comfyui on /comfyui"
    fi

    comfy_mounts="$(docker inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' "${cid}" 2>/dev/null || true)"
    if printf '%s\n' "${comfy_mounts}" | grep -Eq '^/comfyui/(models|input|output|user|custom_nodes)$|^/opt/comfyui/custom_nodes$'; then
      doctor_fail_or_warn "comfyui must use a single /comfyui runtime root mount; fragmented ComfyUI mounts are no longer supported"
    fi

    if ! timeout 15 docker exec "${cid}" sh -lc 'test -L /opt/comfyui/custom_nodes && test "$(readlink /opt/comfyui/custom_nodes)" = "/comfyui/custom_nodes"'; then
      doctor_fail_or_warn "comfyui source tree must symlink /opt/comfyui/custom_nodes to /comfyui/custom_nodes"
    fi

    if [[ "${AGENTIC_PROFILE}" == "rootless-dev" && "${host_machine}" =~ ^(aarch64|arm64)$ ]]; then
      comfy_cuda_diag="$(timeout 15 docker exec "${cid}" sh -lc 'cat /comfyui/user/agentic-runtime/torch-runtime.json' 2>/dev/null || true)"
      if [[ -z "${comfy_cuda_diag}" ]]; then
        doctor_fail_or_warn "comfyui CUDA diagnostics missing at /comfyui/user/agentic-runtime/torch-runtime.json"
      else
        comfy_cuda_summary="$(
          python3 - "${comfy_cuda_diag}" <<'PY' 2>/dev/null || true
import json
import sys

payload = json.loads(sys.argv[1])
policy = payload.get("policy", "")
reason = str(payload.get("reason", "")).strip()

if policy not in {"effective", "unsupported-explicit"}:
    raise SystemExit(1)

print(f"{policy}|{reason}")
PY
        )"
        if [[ -z "${comfy_cuda_summary}" ]]; then
          doctor_fail_or_warn "comfyui CUDA diagnostics are invalid for arm64/rootless-dev"
        elif [[ "${comfy_cuda_summary%%|*}" == "effective" ]]; then
          ok "comfyui arm64/rootless-dev CUDA backend is effective"
        else
          warn "comfyui arm64/rootless-dev CUDA policy is explicit unsupported; ${comfy_cuda_summary#*|}"
        fi
      fi
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

  if [[ "${service}" == "optional-pi-mono" ]]; then
    env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${cid}" 2>/dev/null || true)"
    if ! echo "${env_dump}" | grep -q '^HOME=/state/home$'; then
      doctor_fail "optional-pi-mono must set HOME=/state/home"
    fi
    if ! echo "${env_dump}" | grep -q '^AGENT_HOME=/state/home$'; then
      doctor_fail "optional-pi-mono must set AGENT_HOME=/state/home"
    fi
    if ! echo "${env_dump}" | grep -q '^GATE_MCP_URL=http://gate-mcp:8123$'; then
      doctor_fail "optional-pi-mono must set GATE_MCP_URL=http://gate-mcp:8123"
    fi
    if ! echo "${env_dump}" | grep -q '^GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token$'; then
      doctor_fail "optional-pi-mono must set GATE_MCP_AUTH_TOKEN_FILE=/run/secrets/gate_mcp.token"
    fi

    if ! mount_destination_present "${cid}" "/run/secrets/gate_mcp.token"; then
      doctor_fail "optional-pi-mono must mount /run/secrets/gate_mcp.token read-only"
    elif ! mount_destination_read_only "${cid}" "/run/secrets/gate_mcp.token"; then
      doctor_fail "optional-pi-mono must mount /run/secrets/gate_mcp.token read-only"
    fi
    if ! mount_destination_matches_source "${cid}" "/workspace" "${AGENTIC_PI_MONO_WORKSPACES_DIR}"; then
      doctor_fail "optional-pi-mono /workspace source must match AGENTIC_PI_MONO_WORKSPACES_DIR (${AGENTIC_PI_MONO_WORKSPACES_DIR})"
    fi

    if ! timeout 15 docker exec "${cid}" sh -lc 'test -d /state/home && test -w /state/home'; then
      doctor_fail "optional-pi-mono home directory is not writable (/state/home)"
    fi
    if ! timeout 20 docker exec "${cid}" sh -lc '
      python3 - <<'"'"'PY'"'"'
import json
from pathlib import Path

models_path = Path("/state/home/.pi/agent/models.json")
settings_path = Path("/state/home/.pi/agent/settings.json")

if not models_path.exists() or not settings_path.exists():
    raise SystemExit(1)

models_payload = json.loads(models_path.read_text(encoding="utf-8"))
settings_payload = json.loads(settings_path.read_text(encoding="utf-8"))

if not isinstance(models_payload, dict) or not isinstance(settings_payload, dict):
    raise SystemExit(1)

providers = models_payload.get("providers")
if not isinstance(providers, dict):
    raise SystemExit(1)

provider = providers.get("ollama")
if not isinstance(provider, dict):
    raise SystemExit(1)

if provider.get("baseUrl") != "http://ollama-gate:11435/v1":
    raise SystemExit(1)
if provider.get("api") != "openai-completions":
    raise SystemExit(1)
if not isinstance(provider.get("apiKey"), str) or not provider.get("apiKey").strip():
    raise SystemExit(1)

models = provider.get("models")
if not isinstance(models, list) or not models:
    raise SystemExit(1)

model_ids = {
    item.get("id").strip()
    for item in models
    if isinstance(item, dict) and isinstance(item.get("id"), str) and item.get("id").strip()
}
if not model_ids:
    raise SystemExit(1)

if settings_payload.get("defaultProvider") != "ollama":
    raise SystemExit(1)

default_model = settings_payload.get("defaultModel")
if not isinstance(default_model, str) or not default_model.strip():
    raise SystemExit(1)
if default_model.strip() not in model_ids:
    raise SystemExit(1)
PY
    '; then
      doctor_fail "optional-pi-mono must reconcile ~/.pi/agent config to local ollama-gate provider defaults"
    fi
  fi

  if [[ "${service}" == "optional-goose" ]]; then
    env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${cid}" 2>/dev/null || true)"
    if ! echo "${env_dump}" | grep -q '^HOME=/state/home$'; then
      doctor_fail "optional-goose must set HOME=/state/home"
    fi
    if ! echo "${env_dump}" | grep -q '^XDG_CONFIG_HOME=/state/home/.config$'; then
      doctor_fail "optional-goose must set XDG_CONFIG_HOME=/state/home/.config"
    fi
    if ! echo "${env_dump}" | grep -q '^XDG_DATA_HOME=/state/home/.local/share$'; then
      doctor_fail "optional-goose must set XDG_DATA_HOME=/state/home/.local/share"
    fi
    if ! echo "${env_dump}" | grep -q '^XDG_STATE_HOME=/state/home/.local/state$'; then
      doctor_fail "optional-goose must set XDG_STATE_HOME=/state/home/.local/state"
    fi
    if ! echo "${env_dump}" | grep -q '^OLLAMA_HOST=http://ollama-gate:11435$'; then
      doctor_fail "optional-goose must set OLLAMA_HOST=http://ollama-gate:11435"
    fi
    goose_context_limit_runtime="$(printf '%s\n' "${env_dump}" | sed -n 's/^GOOSE_CONTEXT_LIMIT=//p' | head -n 1)"
    if [[ -z "${goose_context_limit_runtime}" ]]; then
      doctor_fail "optional-goose must set GOOSE_CONTEXT_LIMIT"
    elif ! [[ "${goose_context_limit_runtime}" =~ ^[0-9]+$ ]] || (( goose_context_limit_runtime < 2048 )); then
      doctor_fail "optional-goose GOOSE_CONTEXT_LIMIT must be a numeric value >= 2048 (got: ${goose_context_limit_runtime})"
    elif [[ "${goose_context_limit_runtime}" != "${goose_context_limit_expected}" ]]; then
      doctor_fail_or_warn "optional-goose context limit mismatch: runtime=${goose_context_limit_runtime} expected=${goose_context_limit_expected}"
    fi

    if ! mount_destination_present "${cid}" "/state"; then
      doctor_fail "optional-goose must mount /state"
    fi
    if ! mount_destination_present "${cid}" "/logs"; then
      doctor_fail "optional-goose must mount /logs"
    fi
    if ! mount_destination_present "${cid}" "/workspace"; then
      doctor_fail "optional-goose must mount /workspace"
    fi
    if ! mount_destination_matches_source "${cid}" "/workspace" "${AGENTIC_GOOSE_WORKSPACES_DIR}"; then
      doctor_fail "optional-goose /workspace source must match AGENTIC_GOOSE_WORKSPACES_DIR (${AGENTIC_GOOSE_WORKSPACES_DIR})"
    fi

    if ! timeout 20 docker exec "${cid}" sh -lc 'goose session list >/dev/null 2>&1'; then
      doctor_fail "optional-goose goose session storage is not operational"
    fi
    if ! timeout 20 docker exec "${cid}" sh -lc 'test -d /state/home && test -w /state/home'; then
      doctor_fail "optional-goose home directory is not writable (/state/home)"
    fi
    if ! timeout 20 docker exec "${cid}" sh -lc 'test -d /state/home/.local/share/goose/sessions && test -w /state/home/.local/share/goose/sessions'; then
      doctor_fail "optional-goose sessions directory must be writable (/state/home/.local/share/goose/sessions)"
    fi
    if ! timeout 20 docker exec "${cid}" sh -lc 'test -d /state/home/.local/state/goose/logs && test -w /state/home/.local/state/goose/logs'; then
      doctor_fail "optional-goose logs directory must be writable (/state/home/.local/state/goose/logs)"
    fi
  fi

  if [[ "${service}" == "openhands" ]]; then
    env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${cid}" 2>/dev/null || true)"
    openhands_runtime_model="$(printf '%s\n' "${env_dump}" | sed -n 's/^LLM_MODEL=//p' | head -n 1)"
    if [[ -z "${openhands_runtime_model}" ]]; then
      doctor_fail "openhands missing LLM_MODEL"
    else
      openhands_reason="$(agentic_tool_call_model_incompatibility_reason "${openhands_runtime_model}" 2>/dev/null || true)"
      if [[ -n "${openhands_reason}" ]]; then
        openhands_recommendation="$(agentic_tool_call_model_recommendation "${openhands_runtime_model}" 2>/dev/null || true)"
        if [[ -n "${openhands_recommendation}" ]]; then
          doctor_fail "openhands LLM_MODEL='${openhands_runtime_model}' is incompatible with the stack agentic tool-calling path: ${openhands_reason}; use '${openhands_recommendation}'"
        else
          doctor_fail "openhands LLM_MODEL='${openhands_runtime_model}' is incompatible with the stack agentic tool-calling path: ${openhands_reason}"
        fi
      fi
    fi
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

check_default_model_tool_call_compatibility
check_default_model_context_resources

comfyui_cid="$(service_container_id comfyui)"
if [[ -n "${comfyui_cid}" ]]; then
  if [[ ! -d "${AGENTIC_ROOT}/comfyui" ]]; then
    doctor_fail_or_warn "comfyui runtime root is missing: ${AGENTIC_ROOT}/comfyui"
  fi
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

optional_openclaw_cid="$(service_container_id openclaw)"
optional_openclaw_gateway_cid="$(service_container_id openclaw-gateway)"
optional_openclaw_provider_bridge_cid="$(service_container_id openclaw-provider-bridge)"
optional_openclaw_sandbox_cid="$(service_container_id openclaw-sandbox)"
optional_openclaw_relay_cid="$(service_container_id openclaw-relay)"
optional_openclaw_profile_file="${AGENTIC_ROOT}/openclaw/config/integration-profile.current.json"
optional_openclaw_operator_runtime_file="${AGENTIC_ROOT}/openclaw/config/operator-runtime.v1.json"
optional_openclaw_relay_targets_file="${AGENTIC_ROOT}/openclaw/config/relay_targets.json"
optional_openclaw_manifest_file="${AGENTIC_ROOT}/openclaw/config/module/openclaw.module-manifest.v1.json"
optional_openclaw_immutable_file="${AGENTIC_ROOT}/openclaw/config/immutable/openclaw.stack-config.v1.json"
optional_openclaw_provider_bridge_file="${AGENTIC_ROOT}/openclaw/config/bridge/openclaw.provider-bridge.json"
optional_openclaw_provider_bridge_status_file="${AGENTIC_ROOT}/openclaw/state/provider-bridge-status.json"
optional_openclaw_overlay_file="${AGENTIC_ROOT}/openclaw/config/overlay/openclaw.operator-overlay.json"
optional_openclaw_state_file="${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/openclaw.state.json"
optional_openclaw_chat_status_plugin_dir="${AGENTIC_ROOT}/openclaw/state/cli/openclaw-home/.openclaw/extensions/openclaw-chat-status"
optional_openclaw_chat_status_runtime_dir="/state/cli/openclaw-home/.openclaw/extensions/openclaw-chat-status"
optional_openclaw_chat_status_manifest_file="${optional_openclaw_chat_status_plugin_dir}/openclaw.plugin.json"
optional_openclaw_chat_status_skill_file="${optional_openclaw_chat_status_plugin_dir}/skills/openclaw/SKILL.md"
optional_openclaw_approvals_dir="${AGENTIC_ROOT}/openclaw/state/approvals"
optional_openclaw_sandbox_registry_file="${AGENTIC_ROOT}/openclaw/sandbox/state/session-sandboxes.json"
optional_openclaw_operator_registry_file="${AGENTIC_ROOT}/openclaw/sandbox/state/openclaw-state-registry.v1.json"
optional_openclaw_token_file="${AGENTIC_ROOT}/secrets/runtime/openclaw.token"
optional_openclaw_webhook_secret_file="${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret"
optional_openclaw_layer_helper="${AGENTIC_REPO_ROOT}/deployments/optional/openclaw_config_layers.py"
optional_openclaw_manifest_helper="${AGENTIC_REPO_ROOT}/deployments/optional/openclaw_module_manifest.py"
if [[ -n "${optional_openclaw_cid}" ]]; then
  if ! assert_no_public_bind "${openclaw_webhook_host_port}"; then
    doctor_fail "openclaw webhook bind must stay loopback-only on port ${openclaw_webhook_host_port}"
  fi

  if [[ ! -s "${optional_openclaw_immutable_file}" ]]; then
    doctor_fail "openclaw immutable config is missing: ${optional_openclaw_immutable_file}"
  fi
  if [[ ! -s "${optional_openclaw_overlay_file}" ]]; then
    doctor_fail "openclaw operator overlay is missing: ${optional_openclaw_overlay_file}"
  fi
  if [[ ! -f "${optional_openclaw_state_file}" ]]; then
    doctor_fail "openclaw writable state config is missing: ${optional_openclaw_state_file}"
  elif ! python3 "${optional_openclaw_layer_helper}" validate-host-layout \
    --immutable-file "${optional_openclaw_immutable_file}" \
    --bridge-file "${optional_openclaw_provider_bridge_file}" \
    --overlay-file "${optional_openclaw_overlay_file}" \
    --state-file "${optional_openclaw_state_file}" >/dev/null 2>&1; then
    doctor_fail "openclaw layered config layout is invalid"
  fi

  if [[ ! -s "${optional_openclaw_profile_file}" ]]; then
    doctor_fail "openclaw integration profile is missing: ${optional_openclaw_profile_file}"
  elif ! validate_openclaw_profile_file "${optional_openclaw_profile_file}" >/dev/null 2>&1; then
    doctor_fail "openclaw integration profile is invalid: ${optional_openclaw_profile_file}"
  fi
  if [[ ! -s "${optional_openclaw_operator_runtime_file}" ]]; then
    doctor_fail "openclaw operator runtime file is missing: ${optional_openclaw_operator_runtime_file}"
  elif ! python3 - "${optional_openclaw_operator_runtime_file}" <<'PY' >/dev/null 2>&1
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(payload, dict):
    raise SystemExit(1)
if payload.get("module") != "openclaw-operator-runtime":
    raise SystemExit(1)
if payload.get("schema_version") != 1:
    raise SystemExit(1)
default_model = payload.get("default_model")
if not isinstance(default_model, str) or not default_model.strip():
    raise SystemExit(1)
PY
  then
    doctor_fail "openclaw operator runtime file is invalid: ${optional_openclaw_operator_runtime_file}"
  fi
  if [[ ! -s "${optional_openclaw_manifest_file}" ]]; then
    doctor_fail "openclaw module manifest is missing: ${optional_openclaw_manifest_file}"
  elif ! python3 "${optional_openclaw_manifest_helper}" validate --manifest-file "${optional_openclaw_manifest_file}" >/dev/null 2>&1; then
    doctor_fail "openclaw module manifest is invalid: ${optional_openclaw_manifest_file}"
  else
    ok "openclaw module manifest is present and valid"
  fi

  optional_openclaw_env="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${optional_openclaw_cid}" 2>/dev/null || true)"
  if ! grep -q '^OPENCLAW_PROFILE_FILE=/config/integration-profile.current.json$' <<<"${optional_openclaw_env}"; then
    doctor_fail "openclaw must set OPENCLAW_PROFILE_FILE=/config/integration-profile.current.json"
  fi
  if ! grep -q '^OPENCLAW_OPERATOR_RUNTIME_FILE=/config/operator-runtime.v1.json$' <<<"${optional_openclaw_env}"; then
    doctor_fail "openclaw must set OPENCLAW_OPERATOR_RUNTIME_FILE=/config/operator-runtime.v1.json"
  fi
  if ! grep -q '^OPENCLAW_MODULE_MANIFEST_FILE=/config/module/openclaw.module-manifest.v1.json$' <<<"${optional_openclaw_env}"; then
    doctor_fail "openclaw must set OPENCLAW_MODULE_MANIFEST_FILE=/config/module/openclaw.module-manifest.v1.json"
  fi
  if ! grep -q '^OPENCLAW_IMMUTABLE_CONFIG_FILE=/config/immutable/openclaw.stack-config.v1.json$' <<<"${optional_openclaw_env}"; then
    doctor_fail "openclaw must set OPENCLAW_IMMUTABLE_CONFIG_FILE=/config/immutable/openclaw.stack-config.v1.json"
  fi
  if ! grep -q '^OPENCLAW_PROVIDER_BRIDGE_FILE=/config/bridge/openclaw.provider-bridge.json$' <<<"${optional_openclaw_env}"; then
    doctor_fail "openclaw must set OPENCLAW_PROVIDER_BRIDGE_FILE=/config/bridge/openclaw.provider-bridge.json"
  fi
  if ! grep -q '^OPENCLAW_OPERATOR_OVERLAY_FILE=/overlay/openclaw.operator-overlay.json$' <<<"${optional_openclaw_env}"; then
    doctor_fail "openclaw must set OPENCLAW_OPERATOR_OVERLAY_FILE=/overlay/openclaw.operator-overlay.json"
  fi
  if ! grep -q '^OPENCLAW_STATE_CONFIG_FILE=/state/cli/openclaw-home/openclaw.state.json$' <<<"${optional_openclaw_env}"; then
    doctor_fail "openclaw must set OPENCLAW_STATE_CONFIG_FILE=/state/cli/openclaw-home/openclaw.state.json"
  fi
  if ! grep -q '^OPENCLAW_CONFIG_PATH=/tmp/openclaw.effective.json$' <<<"${optional_openclaw_env}"; then
    doctor_fail "openclaw must set OPENCLAW_CONFIG_PATH=/tmp/openclaw.effective.json"
  fi
  if ! grep -q '^OPENCLAW_SANDBOX_LIFECYCLE_URL=http://openclaw-sandbox:8112/v1/internal/sandboxes/lease$' <<<"${optional_openclaw_env}"; then
    doctor_fail "openclaw must set OPENCLAW_SANDBOX_LIFECYCLE_URL=http://openclaw-sandbox:8112/v1/internal/sandboxes/lease"
  fi
  if ! grep -q '^OPENCLAW_APPROVALS_STATE_DIR=/state/approvals$' <<<"${optional_openclaw_env}"; then
    doctor_fail "openclaw must set OPENCLAW_APPROVALS_STATE_DIR=/state/approvals"
  fi
  if ! timeout 15 docker exec "${optional_openclaw_cid}" sh -lc 'command -v openclaw >/dev/null'; then
    doctor_fail "openclaw must provide openclaw CLI in-container"
  fi
  if ! mount_destination_present "${optional_openclaw_cid}" "/overlay"; then
    doctor_fail "openclaw must mount /overlay for validated operator config"
  fi
  if ! mount_destination_present "${optional_openclaw_cid}" "/workspace"; then
    doctor_fail "openclaw must mount /workspace for persistent operator sessions"
  elif ! mount_destination_matches_source "${optional_openclaw_cid}" "/workspace" "${AGENTIC_OPENCLAW_WORKSPACES_DIR}"; then
    doctor_fail "openclaw /workspace source must match AGENTIC_OPENCLAW_WORKSPACES_DIR (${AGENTIC_OPENCLAW_WORKSPACES_DIR})"
  fi
  if ! timeout 15 docker exec "${optional_openclaw_cid}" sh -lc 'test -d /workspace && test -w /workspace'; then
    doctor_fail "openclaw workspace mount must be writable (/workspace)"
  fi
  if [[ ! -d "${optional_openclaw_approvals_dir}" ]]; then
    doctor_fail "openclaw approvals state directory is missing: ${optional_openclaw_approvals_dir}"
  elif ! python3 - "${optional_openclaw_approvals_dir}" <<'PY' >/dev/null 2>&1
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for name in ("pending", "approved", "denied", "expired"):
    current = root / name
    if not current.is_dir():
        raise SystemExit(1)
    for item in current.glob("*.json"):
        payload = json.loads(item.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise SystemExit(1)
        if str(payload.get("status", "")) != name:
            raise SystemExit(1)
PY
  then
    doctor_fail "openclaw approvals queue must expose valid JSON records under ${optional_openclaw_approvals_dir}/{pending,approved,denied,expired}"
  fi
  dashboard_status="$(curl -sS -o /tmp/doctor-openclaw-dashboard.out -w '%{http_code}' "http://127.0.0.1:${openclaw_webhook_host_port}/dashboard" 2>/dev/null || true)"
  if [[ "${dashboard_status}" != "200" ]]; then
    doctor_fail "openclaw dashboard must be reachable on loopback (/dashboard, status=${dashboard_status:-unknown})"
  fi
  dashboard_json_status="$(curl -sS -o /tmp/doctor-openclaw-dashboard-status.out -w '%{http_code}' "http://127.0.0.1:${openclaw_webhook_host_port}/v1/dashboard/status" 2>/dev/null || true)"
  if [[ "${dashboard_json_status}" != "200" ]]; then
    doctor_fail "openclaw dashboard status must be reachable on loopback (/v1/dashboard/status, status=${dashboard_json_status:-unknown})"
  elif ! python3 - "/tmp/doctor-openclaw-dashboard-status.out" <<'PY' >/dev/null 2>&1
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
approvals = payload.get("approvals")
if not isinstance(approvals, dict):
    raise SystemExit(1)
for key in ("pending", "approved", "denied", "expired"):
    value = approvals.get(key)
    if value is not None and not isinstance(value, int):
        raise SystemExit(1)
PY
  then
    doctor_fail "openclaw dashboard status must expose approvals queue counters"
  fi
  if ! timeout 20 docker exec "${optional_openclaw_cid}" sh -lc "openclaw --version >/tmp/openclaw-layer-version.out && python3 /app/openclaw_config_layers.py check-runtime --immutable-file /config/immutable/openclaw.stack-config.v1.json --bridge-file /config/bridge/openclaw.provider-bridge.json --overlay-file /overlay/openclaw.operator-overlay.json --state-file /state/cli/openclaw-home/openclaw.state.json --effective-file /tmp/openclaw.effective.json --gateway-token-file /run/secrets/openclaw.token"; then
    doctor_fail "openclaw layered config runtime check failed"
  fi
  if [[ ! -s "${optional_openclaw_chat_status_manifest_file}" ]]; then
    doctor_fail "managed openclaw chat-status plugin manifest is missing: ${optional_openclaw_chat_status_manifest_file}"
  fi
  if [[ ! -s "${optional_openclaw_chat_status_skill_file}" ]]; then
    doctor_fail "managed openclaw slash-command skill is missing: ${optional_openclaw_chat_status_skill_file}"
  fi
  if ! python3 - "${optional_openclaw_state_file}" "${optional_openclaw_chat_status_manifest_file}" "${optional_openclaw_chat_status_runtime_dir}" <<'PY' >/dev/null 2>&1
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
manifest = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
plugin_dir = str(pathlib.Path(sys.argv[3]))
if manifest.get("id") != "openclaw-chat-status":
    raise SystemExit(1)
skills = manifest.get("skills")
if not isinstance(skills, list) or "./skills" not in skills:
    raise SystemExit(1)
plugins = state.get("plugins")
if not isinstance(plugins, dict):
    raise SystemExit(1)
allow = plugins.get("allow")
if not isinstance(allow, list) or "openclaw-chat-status" not in allow:
    raise SystemExit(1)
entries = plugins.get("entries")
if not isinstance(entries, dict):
    raise SystemExit(1)
entry = entries.get("openclaw-chat-status")
if not isinstance(entry, dict) or entry.get("enabled") is not True:
    raise SystemExit(1)
installs = plugins.get("installs")
if not isinstance(installs, dict):
    raise SystemExit(1)
install = installs.get("openclaw-chat-status")
if not isinstance(install, dict):
    raise SystemExit(1)
if install.get("source") != "path":
    raise SystemExit(1)
if install.get("sourcePath") != plugin_dir:
    raise SystemExit(1)
if install.get("installPath") != plugin_dir:
    raise SystemExit(1)
PY
  then
    doctor_fail "openclaw writable state must pin-trust, enable, and record path provenance for the managed /openclaw status plugin"
  fi
fi

if [[ -n "${optional_openclaw_gateway_cid}" ]]; then
  if ! assert_no_public_bind "${openclaw_gateway_host_port}"; then
    doctor_fail "openclaw gateway bind must stay loopback-only on port ${openclaw_gateway_host_port}"
  fi

  optional_openclaw_gateway_env="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${optional_openclaw_gateway_cid}" 2>/dev/null || true)"
  if ! grep -q '^OPENCLAW_GATEWAY_BIND_MODE=loopback$' <<<"${optional_openclaw_gateway_env}"; then
    doctor_fail "openclaw-gateway must set OPENCLAW_GATEWAY_BIND_MODE=loopback"
  fi
  if ! grep -q '^OPENCLAW_GATEWAY_PORT=18789$' <<<"${optional_openclaw_gateway_env}"; then
    doctor_fail "openclaw-gateway must set OPENCLAW_GATEWAY_PORT=18789"
  fi
  if ! grep -q '^OPENCLAW_IMMUTABLE_CONFIG_FILE=/config/immutable/openclaw.stack-config.v1.json$' <<<"${optional_openclaw_gateway_env}"; then
    doctor_fail "openclaw-gateway must set OPENCLAW_IMMUTABLE_CONFIG_FILE=/config/immutable/openclaw.stack-config.v1.json"
  fi
  if ! grep -q '^OPENCLAW_PROVIDER_BRIDGE_FILE=/config/bridge/openclaw.provider-bridge.json$' <<<"${optional_openclaw_gateway_env}"; then
    doctor_fail "openclaw-gateway must set OPENCLAW_PROVIDER_BRIDGE_FILE=/config/bridge/openclaw.provider-bridge.json"
  fi
  if ! grep -q '^OPENCLAW_OPERATOR_OVERLAY_FILE=/overlay/openclaw.operator-overlay.json$' <<<"${optional_openclaw_gateway_env}"; then
    doctor_fail "openclaw-gateway must set OPENCLAW_OPERATOR_OVERLAY_FILE=/overlay/openclaw.operator-overlay.json"
  fi
  if ! grep -q '^OPENCLAW_STATE_CONFIG_FILE=/state/cli/openclaw-home/openclaw.state.json$' <<<"${optional_openclaw_gateway_env}"; then
    doctor_fail "openclaw-gateway must set OPENCLAW_STATE_CONFIG_FILE=/state/cli/openclaw-home/openclaw.state.json"
  fi

  if ! timeout 15 docker exec "${optional_openclaw_gateway_cid}" sh -lc 'command -v openclaw >/dev/null'; then
    doctor_fail "openclaw-gateway must provide openclaw CLI in-container"
  fi

  if ! mount_destination_present "${optional_openclaw_gateway_cid}" "/overlay"; then
    doctor_fail "openclaw-gateway must mount /overlay for validated operator config"
  fi
  if ! mount_destination_present "${optional_openclaw_gateway_cid}" "/workspace"; then
    doctor_fail "openclaw-gateway must mount /workspace for persistent operator sessions"
  elif ! mount_destination_matches_source "${optional_openclaw_gateway_cid}" "/workspace" "${AGENTIC_OPENCLAW_WORKSPACES_DIR}"; then
    doctor_fail "openclaw-gateway /workspace source must match AGENTIC_OPENCLAW_WORKSPACES_DIR (${AGENTIC_OPENCLAW_WORKSPACES_DIR})"
  fi

  gateway_bindings_json="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "${optional_openclaw_gateway_cid}" 2>/dev/null || true)"
  if ! python3 - "${gateway_bindings_json}" "${openclaw_gateway_host_port}" <<'PY' >/dev/null 2>&1
import json
import sys

bindings_raw = sys.argv[1]
expected_port = sys.argv[2]

try:
    bindings = json.loads(bindings_raw)
except Exception:
    raise SystemExit(1)

entries = bindings.get("8114/tcp")
if not isinstance(entries, list) or not entries:
    raise SystemExit(1)

for item in entries:
    if not isinstance(item, dict):
        continue
    host_ip = str(item.get("HostIp", "")).strip()
    host_port = str(item.get("HostPort", "")).strip()
    if host_ip == "127.0.0.1" and host_port == expected_port:
        raise SystemExit(0)

raise SystemExit(1)
PY
  then
    doctor_fail "openclaw-gateway must publish 8114/tcp on loopback 127.0.0.1:${openclaw_gateway_host_port}"
  fi

  gateway_ui_status="$(curl -sS -o /tmp/doctor-openclaw-gateway-ui.out -w '%{http_code}' "http://127.0.0.1:${openclaw_gateway_host_port}/" 2>/dev/null || true)"
  if [[ "${gateway_ui_status}" != "200" ]]; then
    doctor_fail "openclaw-gateway Web UI must be reachable on loopback (/, status=${gateway_ui_status:-unknown})"
  elif ! grep -q 'assets/index-' /tmp/doctor-openclaw-gateway-ui.out; then
    doctor_fail "openclaw-gateway must serve the real Control UI asset bundle"
  elif grep -q 'Fallback control UI page provided by the agentic stack' /tmp/doctor-openclaw-gateway-ui.out; then
    doctor_fail "openclaw-gateway must not serve the fallback placeholder page"
  fi

  if ! timeout 20 docker exec "${optional_openclaw_gateway_cid}" sh -lc 'token="$(tr -d "\n" </run/secrets/openclaw.token)"; test -n "${token}" && OPENCLAW_CAPTURE_LAYER_STATE_ON_EXIT=0 openclaw gateway status --json --require-rpc --url ws://127.0.0.1:18789 --token "${token}" >/tmp/openclaw-gateway-health.out'; then
    doctor_fail "openclaw-gateway WS endpoint must answer token-auth RPC probe on ws://127.0.0.1:18789"
  fi
fi

if [[ -n "${optional_openclaw_provider_bridge_cid}" ]]; then
  optional_openclaw_provider_bridge_env="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${optional_openclaw_provider_bridge_cid}" 2>/dev/null || true)"
  if ! grep -q '^OPENCLAW_PROVIDER_BRIDGE_FILE=/config/bridge/openclaw.provider-bridge.json$' <<<"${optional_openclaw_provider_bridge_env}"; then
    doctor_fail "openclaw-provider-bridge must set OPENCLAW_PROVIDER_BRIDGE_FILE=/config/bridge/openclaw.provider-bridge.json"
  fi
  if ! grep -q '^OPENCLAW_PROVIDER_BRIDGE_STATUS_FILE=/state/provider-bridge-status.json$' <<<"${optional_openclaw_provider_bridge_env}"; then
    doctor_fail "openclaw-provider-bridge must set OPENCLAW_PROVIDER_BRIDGE_STATUS_FILE=/state/provider-bridge-status.json"
  fi
  if ! mount_destination_present "${optional_openclaw_provider_bridge_cid}" "/config/bridge"; then
    doctor_fail "openclaw-provider-bridge must mount /config/bridge"
  fi
  if [[ ! -s "${optional_openclaw_provider_bridge_file}" ]]; then
    doctor_fail "openclaw provider bridge file is missing: ${optional_openclaw_provider_bridge_file}"
  fi
  if [[ ! -s "${optional_openclaw_provider_bridge_status_file}" ]]; then
    doctor_fail "openclaw provider bridge status file is missing: ${optional_openclaw_provider_bridge_status_file}"
  elif ! python3 - "${optional_openclaw_provider_bridge_status_file}" <<'PY' >/dev/null 2>&1
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(payload, dict):
    raise SystemExit(1)
providers = payload.get("providers")
if not isinstance(providers, dict):
    raise SystemExit(1)
if "ready" not in payload:
    raise SystemExit(1)
PY
  then
    doctor_fail "openclaw provider bridge status payload is invalid"
  fi
fi

if [[ -n "${optional_openclaw_sandbox_cid}" ]]; then
  if [[ ! -s "${optional_openclaw_profile_file}" ]]; then
    doctor_fail "openclaw sandbox requires integration profile: ${optional_openclaw_profile_file}"
  elif ! validate_openclaw_profile_file "${optional_openclaw_profile_file}" >/dev/null 2>&1; then
    doctor_fail "openclaw sandbox profile is invalid: ${optional_openclaw_profile_file}"
  fi

  optional_openclaw_sandbox_env="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${optional_openclaw_sandbox_cid}" 2>/dev/null || true)"
  if ! grep -q '^OPENCLAW_SANDBOX_PROFILE_FILE=/config/integration-profile.current.json$' <<<"${optional_openclaw_sandbox_env}"; then
    doctor_fail "openclaw-sandbox must set OPENCLAW_SANDBOX_PROFILE_FILE=/config/integration-profile.current.json"
  fi
  if ! grep -q '^OPENCLAW_SANDBOX_OPERATOR_RUNTIME_FILE=/config/operator-runtime.v1.json$' <<<"${optional_openclaw_sandbox_env}"; then
    doctor_fail "openclaw-sandbox must set OPENCLAW_SANDBOX_OPERATOR_RUNTIME_FILE=/config/operator-runtime.v1.json"
  fi
  if ! grep -q '^OPENCLAW_SANDBOX_MODULE_MANIFEST_FILE=/config/module/openclaw.module-manifest.v1.json$' <<<"${optional_openclaw_sandbox_env}"; then
    doctor_fail "openclaw-sandbox must set OPENCLAW_SANDBOX_MODULE_MANIFEST_FILE=/config/module/openclaw.module-manifest.v1.json"
  fi
  if ! grep -q '^OPENCLAW_SANDBOX_REGISTRY_FILE=/state/session-sandboxes.json$' <<<"${optional_openclaw_sandbox_env}"; then
    doctor_fail "openclaw-sandbox must set OPENCLAW_SANDBOX_REGISTRY_FILE=/state/session-sandboxes.json"
  fi
  if ! grep -q '^OPENCLAW_SANDBOX_OPERATOR_REGISTRY_FILE=/state/openclaw-state-registry.v1.json$' <<<"${optional_openclaw_sandbox_env}"; then
    doctor_fail "openclaw-sandbox must set OPENCLAW_SANDBOX_OPERATOR_REGISTRY_FILE=/state/openclaw-state-registry.v1.json"
  fi
  if ! grep -q '^OPENCLAW_APPROVALS_STATE_DIR=/approvals$' <<<"${optional_openclaw_sandbox_env}"; then
    doctor_fail "openclaw-sandbox must set OPENCLAW_APPROVALS_STATE_DIR=/approvals"
  fi
  if ! mount_destination_present "${optional_openclaw_sandbox_cid}" "/sandbox-workspaces"; then
    doctor_fail "openclaw-sandbox must mount /sandbox-workspaces for session-scoped workspaces"
  fi
  if ! mount_destination_present "${optional_openclaw_sandbox_cid}" "/approvals"; then
    doctor_fail "openclaw-sandbox must mount /approvals for shared approvals state"
  elif ! mount_destination_matches_source "${optional_openclaw_sandbox_cid}" "/approvals" "${optional_openclaw_approvals_dir}"; then
    doctor_fail "openclaw-sandbox /approvals source must match ${optional_openclaw_approvals_dir}"
  fi
  if [[ ! -d "${AGENTIC_ROOT}/openclaw/sandbox/workspaces" ]]; then
    doctor_fail "openclaw sandbox workspaces directory is missing: ${AGENTIC_ROOT}/openclaw/sandbox/workspaces"
  fi
  if [[ ! -s "${optional_openclaw_sandbox_registry_file}" ]]; then
    doctor_fail "openclaw sandbox registry is missing: ${optional_openclaw_sandbox_registry_file}"
  elif ! python3 - "${optional_openclaw_sandbox_registry_file}" <<'PY' >/dev/null 2>&1
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(payload, dict):
    raise SystemExit(1)
if not isinstance(payload.get("sandboxes"), dict):
    raise SystemExit(1)
expired = payload.get("expired")
if expired is not None and not isinstance(expired, list):
    raise SystemExit(1)
PY
  then
    doctor_fail "openclaw sandbox registry is invalid JSON: ${optional_openclaw_sandbox_registry_file}"
  else
    ok "openclaw sandbox registry is present and valid"
  fi
  if [[ ! -s "${optional_openclaw_operator_registry_file}" ]]; then
    doctor_fail "openclaw operator registry is missing: ${optional_openclaw_operator_registry_file}"
  elif ! python3 - \
    "${optional_openclaw_operator_registry_file}" \
    "${optional_openclaw_sandbox_registry_file}" \
    "${optional_openclaw_operator_runtime_file}" \
    "${optional_openclaw_token_file}" \
    "${optional_openclaw_webhook_secret_file}" <<'PY' >/dev/null 2>&1
import json
import pathlib
import sys

operator_path = pathlib.Path(sys.argv[1])
technical_path = pathlib.Path(sys.argv[2])
runtime_path = pathlib.Path(sys.argv[3])
secret_paths = [pathlib.Path(sys.argv[4]), pathlib.Path(sys.argv[5])]

operator_raw = operator_path.read_text(encoding="utf-8")
operator = json.loads(operator_raw)
technical = json.loads(technical_path.read_text(encoding="utf-8"))
runtime = json.loads(runtime_path.read_text(encoding="utf-8"))

if not isinstance(operator, dict):
    raise SystemExit(1)
if not isinstance(operator.get("sessions"), dict):
    raise SystemExit(1)
if not isinstance(operator.get("sandboxes"), dict):
    raise SystemExit(1)
if not isinstance(operator.get("recent_expired"), list):
    raise SystemExit(1)

default_model = operator.get("default_model")
default_session_id = operator.get("default_session_id")
provider = operator.get("provider")
policy_set = operator.get("policy_set")
if not isinstance(default_model, str) or not default_model:
    raise SystemExit(1)
if not isinstance(default_session_id, str) or not default_session_id:
    raise SystemExit(1)
if not isinstance(provider, str) or not provider:
    raise SystemExit(1)
if not isinstance(policy_set, list) or not policy_set or not all(isinstance(item, str) and item for item in policy_set):
    raise SystemExit(1)
runtime_default_model = runtime.get("default_model")
if not isinstance(runtime_default_model, str) or not runtime_default_model:
    raise SystemExit(1)
if runtime_default_model != default_model:
    raise SystemExit(1)

technical_sandboxes = technical.get("sandboxes")
if not isinstance(technical_sandboxes, dict):
    raise SystemExit(1)
operator_sandboxes = operator.get("sandboxes")
if set(operator_sandboxes.keys()) != set(technical_sandboxes.keys()):
    raise SystemExit(1)

for record in operator_sandboxes.values():
    if not isinstance(record, dict):
        raise SystemExit(1)
    for key in ("sandbox_id", "session_id", "model", "provider", "created_at", "workspace", "last_health"):
        value = record.get(key)
        if not isinstance(value, str):
            raise SystemExit(1)
    if not isinstance(record.get("current"), bool):
        raise SystemExit(1)
    if not isinstance(record.get("default"), bool):
        raise SystemExit(1)
    if not isinstance(record.get("policy_set"), list):
        raise SystemExit(1)

for session_id, record in operator.get("sessions").items():
    if not isinstance(session_id, str) or not session_id or not isinstance(record, dict):
        raise SystemExit(1)
    if record.get("session_id") != session_id:
        raise SystemExit(1)
    for key in ("model", "provider", "created_at", "workspace", "last_health"):
        value = record.get(key)
        if not isinstance(value, str):
            raise SystemExit(1)
    if not isinstance(record.get("current"), bool):
        raise SystemExit(1)
    if not isinstance(record.get("default"), bool):
        raise SystemExit(1)
    if not isinstance(record.get("active"), bool):
        raise SystemExit(1)
    if not isinstance(record.get("active_sandbox_count"), int):
        raise SystemExit(1)
    models = record.get("models")
    if not isinstance(models, list) or not all(isinstance(item, str) for item in models):
        raise SystemExit(1)
    policy = record.get("policy_set")
    if not isinstance(policy, list) or not all(isinstance(item, str) and item for item in policy):
        raise SystemExit(1)

for path in secret_paths:
    if not path.exists():
        continue
    secret = path.read_text(encoding="utf-8").strip()
    if secret and secret in operator_raw:
        raise SystemExit(1)

for forbidden in ("token", "secret", "authorization"):
    if forbidden in operator_raw.lower():
        raise SystemExit(1)
PY
  then
    doctor_fail "openclaw operator registry is invalid or leaks sensitive data: ${optional_openclaw_operator_registry_file}"
  else
    ok "openclaw operator registry is present, coherent, and secret-free"
  fi
  if ! timeout 15 docker exec "${optional_openclaw_sandbox_cid}" sh -lc "python3 - <<'PY'
import json
import pathlib
import urllib.request

token = pathlib.Path('/run/secrets/openclaw.token').read_text(encoding='utf-8').strip()
req = urllib.request.Request(
    'http://127.0.0.1:8112/v1/sandboxes/status',
    headers={'Authorization': f'Bearer {token}'},
    method='GET',
)
with urllib.request.urlopen(req, timeout=4) as resp:
    payload = json.loads(resp.read().decode('utf-8'))
    if not isinstance(payload, dict) or 'active' not in payload or 'current_session_id' not in payload or 'sessions' not in payload:
        raise SystemExit(1)
PY"; then
    doctor_fail "openclaw-sandbox status endpoint must expose session/operator registry fields (/v1/sandboxes/status)"
  else
    ok "openclaw-sandbox status endpoint exposes operator registry fields"
  fi
  if ! timeout 15 docker exec "${optional_openclaw_sandbox_cid}" sh -lc "python3 - <<'PY'
import json
import pathlib
import urllib.request

token = pathlib.Path('/run/secrets/openclaw.token').read_text(encoding='utf-8').strip()
registry = json.loads(pathlib.Path('/state/openclaw-state-registry.v1.json').read_text(encoding='utf-8'))
req = urllib.request.Request(
    'http://127.0.0.1:8112/v1/internal/sandboxes',
    headers={'Authorization': f'Bearer {token}'},
    method='GET',
)
with urllib.request.urlopen(req, timeout=4) as resp:
    payload = json.loads(resp.read().decode('utf-8'))
if not isinstance(payload, dict):
    raise SystemExit(1)
if not isinstance(payload.get('sandboxes'), list):
    raise SystemExit(1)
if payload.get('active') != len((registry.get('sandboxes') or {})):
    raise SystemExit(1)
if payload.get('current_session_id') != registry.get('current_session_id'):
    raise SystemExit(1)
if payload.get('default_model') != registry.get('default_model'):
    raise SystemExit(1)
PY"; then
    doctor_fail "openclaw-sandbox internal lifecycle API must stay coherent with the operator registry"
  else
    ok "openclaw-sandbox internal lifecycle API is coherent with the operator registry"
  fi
fi

if [[ -n "${optional_openclaw_relay_cid}" ]]; then
  if ! assert_no_public_bind "${openclaw_relay_host_port}"; then
    doctor_fail "openclaw relay bind must stay loopback-only on port ${openclaw_relay_host_port}"
  fi
  if [[ ! -s "${optional_openclaw_relay_targets_file}" ]]; then
    doctor_fail "openclaw relay targets file is missing: ${optional_openclaw_relay_targets_file}"
  fi

  optional_openclaw_relay_env="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${optional_openclaw_relay_cid}" 2>/dev/null || true)"
  if ! grep -q '^OPENCLAW_RELAY_PROVIDER_TARGETS_FILE=/config/relay_targets.json$' <<<"${optional_openclaw_relay_env}"; then
    doctor_fail "openclaw-relay must set OPENCLAW_RELAY_PROVIDER_TARGETS_FILE=/config/relay_targets.json"
  fi

  relay_bindings_json="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "${optional_openclaw_relay_cid}" 2>/dev/null || true)"
  if ! python3 - "${relay_bindings_json}" "${openclaw_relay_host_port}" <<'PY' >/dev/null 2>&1
import json
import sys

bindings_raw = sys.argv[1]
expected_port = sys.argv[2]

try:
    bindings = json.loads(bindings_raw)
except Exception:
    raise SystemExit(1)

entries = bindings.get("8113/tcp")
if not isinstance(entries, list) or not entries:
    raise SystemExit(1)

for item in entries:
    if not isinstance(item, dict):
        continue
    host_ip = str(item.get("HostIp", "")).strip()
    host_port = str(item.get("HostPort", "")).strip()
    if host_ip == "127.0.0.1" and host_port == expected_port:
        raise SystemExit(0)

raise SystemExit(1)
PY
  then
    doctor_fail "openclaw-relay must publish 8113/tcp on loopback 127.0.0.1:${openclaw_relay_host_port}"
  fi

  if ! timeout 15 docker exec "${optional_openclaw_relay_cid}" sh -lc "python3 -c 'import sys,urllib.request; sys.exit(0 if urllib.request.urlopen(\"http://127.0.0.1:8113/v1/queue/status\", timeout=4).status == 200 else 1)'"; then
    doctor_fail "openclaw-relay queue status must be reachable from relay container (/v1/queue/status)"
  fi
fi

optional_portainer_cid="$(service_container_id optional-portainer)"
if [[ -n "${optional_portainer_cid}" ]]; then
  if ! assert_no_public_bind "${portainer_host_port}"; then
    doctor_fail "optional portainer host bind must stay loopback-only on port ${portainer_host_port}"
  fi
fi

if [[ "${check_tool_stream_e2e}" -eq 1 ]]; then
  check_streamed_tool_call_health
fi

current_release_dir="${AGENTIC_ROOT}/deployments/current"
if [[ ! -L "${current_release_dir}" && ! -d "${current_release_dir}" ]]; then
  doctor_fail_or_warn "no active release snapshot found at ${current_release_dir}"
else
  release_images_file="${current_release_dir}/images.json"
  release_runtime_env_file="${current_release_dir}/runtime.env"
  release_latest_resolution_file="${current_release_dir}/latest-resolution.json"
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

  if ! python3 - "${release_images_file}" "${release_runtime_env_file}" "${release_latest_resolution_file}" <<'PY'
import json
import pathlib
import sys

images_path = pathlib.Path(sys.argv[1])
runtime_env_path = pathlib.Path(sys.argv[2])
resolution_path = pathlib.Path(sys.argv[3])

messages = []

def image_is_mutable(ref: str) -> bool:
    if not ref or "@sha256:" in ref:
        return False
    if ref.startswith("agentic/") or ref.endswith(":local"):
        return False
    base = ref.split("@", 1)[0]
    last_slash = base.rfind("/")
    last_colon = base.rfind(":")
    if last_colon <= last_slash:
        return True
    return base.endswith(":latest")

mutable_runtime_keys = {
    "AGENTIC_CODEX_CLI_NPM_SPEC": "@latest",
    "AGENTIC_CLAUDE_CODE_NPM_SPEC": "@latest",
    "AGENTIC_OPENCODE_NPM_SPEC": "@latest",
    "AGENTIC_PI_CODING_AGENT_NPM_SPEC": "@latest",
    "AGENTIC_OPENCLAW_INSTALL_VERSION": "latest",
}

if resolution_path.is_file():
    try:
        payload = json.loads(resolution_path.read_text(encoding="utf-8"))
    except Exception as exc:
        messages.append(f"latest resolution manifest is unreadable: {exc}")
    else:
        runtime_inputs = payload.get("runtime_inputs")
        docker_images = payload.get("docker_images")
        if not isinstance(runtime_inputs, list) or not isinstance(docker_images, list):
            messages.append("latest resolution manifest has an invalid schema")
        else:
            for item in runtime_inputs:
                requested = str(item.get("requested") or "")
                resolved = str(item.get("resolved") or "")
                if requested.endswith("@latest") or requested == "latest":
                    if not resolved or resolved == requested or resolved.endswith("@latest") or resolved == "latest":
                        messages.append(
                            f"runtime latest value is not deterministically resolved ({item.get('env', 'unknown')}: {requested} -> {resolved or '<empty>'})"
                        )
            for item in docker_images:
                requested = str(item.get("requested") or "")
                resolved = str(item.get("resolved") or "")
                service = str(item.get("service") or "unknown")
                if image_is_mutable(requested) and image_is_mutable(resolved):
                    messages.append(
                        f"service {service} still uses a mutable image after update ({requested} -> {resolved})"
                    )
else:
    if images_path.is_file():
        try:
            images = json.loads(images_path.read_text(encoding="utf-8"))
        except Exception as exc:
            messages.append(f"images manifest is unreadable: {exc}")
        else:
            for item in images:
                service = str(item.get("service") or "unknown")
                configured = str(item.get("configured_image") or "")
                if image_is_mutable(configured):
                    messages.append(
                        f"active release has no latest-resolution.json and service {service} still points to mutable image {configured}"
                    )
    if runtime_env_path.is_file():
        for raw_line in runtime_env_path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            expected = mutable_runtime_keys.get(key)
            if expected and value.strip().endswith(expected):
                messages.append(
                    f"active release has no latest-resolution.json and runtime input {key} still requests {value.strip()}"
                )

if messages:
    for message in messages:
        print(message)
    raise SystemExit(1)
PY
  then
    doctor_fail "active release contains mutable 'latest' values that were not resolved deterministically; run 'agent update'"
  else
    ok "active release latest values are deterministically resolved"
  fi
fi

if [[ "$status" -ne 0 ]]; then
  warn "doctor result: NOT READY"
else
  ok "doctor result: READY"
fi

exit "$status"
