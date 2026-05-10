#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

doctor_script="${REPO_ROOT}/scripts/doctor.sh"
[[ -f "${doctor_script}" ]] || fail "doctor script is missing"

tmpdir="$(mktemp -d)"
runtime_root="${tmpdir}/runtime"
fake_bin="${tmpdir}/bin"
mkdir -p "${runtime_root}" "${fake_bin}"

cleanup() {
  if [[ -n "${server_pid:-}" ]] && kill -0 "${server_pid}" >/dev/null 2>&1; then
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

subcommand="${1:-}"
shift || true

project_matches() {
  local project="$1"
  [[ "${project}" == "agentic" || "${project}" == "agentic-dev" ]]
}

if [[ "${subcommand}" == "info" ]]; then
  exit 0
fi

if [[ "${subcommand}" == "network" && "${1:-}" == "inspect" ]]; then
  network_name="${2:-}"
  case "${network_name}" in
    agentic) printf '%s\n' "172.18.0.0/16" ;;
    agentic-egress) printf '%s\n' "172.19.0.0/16" ;;
    agentic-dev) printf '%s\n' "172.28.0.0/16" ;;
    agentic-dev-egress) printf '%s\n' "172.29.0.0/16" ;;
    *) exit 1 ;;
  esac
  exit 0
fi

if [[ "${subcommand}" == "ps" ]]; then
  project=""
  service=""
  format=""
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --filter)
        filter="${2:-}"
        case "${filter}" in
          label=com.docker.compose.project=*)
            project="${filter#label=com.docker.compose.project=}"
            ;;
          label=com.docker.compose.service=*)
            service="${filter#label=com.docker.compose.service=}"
            ;;
        esac
        shift 2
        ;;
      --format)
        format="${2:-}"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  if ! project_matches "${project}"; then
    exit 0
  fi

  if [[ -n "${service}" ]]; then
    case "${service}" in
      optional-forgejo) printf '%s\n' "forgejo123" ;;
      ollama-gate) printf '%s\n' "gate123" ;;
      egress-proxy) printf '%s\n' "proxy123" ;;
      unbound) printf '%s\n' "unbound123" ;;
      ollama) printf '%s\n' "ollama123" ;;
      *) ;;
    esac
    exit 0
  fi

  case "${format}" in
    "{{.Names}}")
      printf '%s\n' "optional-forgejo"
      ;;
    '{{.ID}}|{{.Label "com.docker.compose.service"}}')
      printf '%s\n' "forgejo123|optional-forgejo"
      ;;
  esac
  exit 0
fi

if [[ "${subcommand}" == "inspect" ]]; then
  format=""
  if [[ "${1:-}" == "--format" ]]; then
    format="${2:-}"
    shift 2
  fi
  cid="${1:-}"

  case "${format}" in
    "{{.State.Status}}")
      printf '%s\n' "running"
      ;;
    "{{if .Config.Healthcheck}}present{{else}}missing{{end}}")
      printf '%s\n' "present"
      ;;
    "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}")
      printf '%s\n' "healthy"
      ;;
    '{{.Config.User}}|{{.HostConfig.ReadonlyRootfs}}|{{join .HostConfig.CapDrop ","}}|{{json .HostConfig.SecurityOpt}}')
      if [[ "${cid}" == "forgejo123" ]]; then
        printf '%s\n' '1000:1000|false|ALL|["no-new-privileges:true"]'
      else
        printf '%s\n' '1000:1000|true|ALL|["no-new-privileges:true"]'
      fi
      ;;
    '{{range .Mounts}}{{println .Source "|" .Destination}}{{end}}')
      if [[ "${cid}" == "forgejo123" ]]; then
        printf '%s\n' "/fake/state|/var/lib/gitea"
        printf '%s\n' "/fake/conf|/var/lib/gitea/custom/conf"
      fi
      ;;
    '{{range .Mounts}}{{printf "%s|%v\n" .Destination .RW}}{{end}}')
      if [[ "${cid}" == "forgejo123" ]]; then
        printf '%s\n' "/var/lib/gitea|true"
        printf '%s\n' "/var/lib/gitea/custom/conf|true"
      fi
      ;;
    "{{.State.StartedAt}}")
      printf '%s\n' "2026-05-10T10:00:00Z"
      ;;
    '{{range .Config.Env}}{{println .}}{{end}}')
      ;;
    *)
      case "${format}" in
        *NetworkSettings.Networks*agentic-dev-egress*IPAddress*)
          case "${cid}" in
            proxy123) printf '%s\n' "172.29.0.10" ;;
            unbound123) printf '%s\n' "172.29.0.11" ;;
            ollama123) printf '%s\n' "172.29.0.12" ;;
          esac
          ;;
        *NetworkSettings.Networks*agentic-egress*IPAddress*)
          case "${cid}" in
            proxy123) printf '%s\n' "172.19.0.10" ;;
            unbound123) printf '%s\n' "172.19.0.11" ;;
            ollama123) printf '%s\n' "172.19.0.12" ;;
          esac
          ;;
        *NetworkSettings.Networks*agentic-dev*IPAddress*)
          case "${cid}" in
            proxy123) printf '%s\n' "172.28.0.10" ;;
            unbound123) printf '%s\n' "172.28.0.11" ;;
          esac
          ;;
        *NetworkSettings.Networks*agentic*IPAddress*)
          case "${cid}" in
            proxy123) printf '%s\n' "172.18.0.10" ;;
            unbound123) printf '%s\n' "172.18.0.11" ;;
          esac
          ;;
      esac
      ;;
  esac
  exit 0
fi

if [[ "${subcommand}" == "exec" ]]; then
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -i|-t)
        shift
        ;;
      -e)
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done
  cid="${1:-}"
  if [[ "${cid}" == "gate123" ]]; then
    cat <<'JSON'
{"choices":[{"message":{"tool_calls":[{"function":{"name":"doctor_probe","arguments":"{\"path\":\"/workspace/README.md\"}"}}]}}]}
JSON
    exit 0
  fi
  exit 1
fi

echo "unexpected docker invocation: ${subcommand} $*" >&2
exit 1
EOF

cat >"${fake_bin}/iptables" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "-S" ]]; then
  echo "unexpected iptables invocation: $*" >&2
  exit 1
fi

chain="${2:-}"
if [[ "${chain}" == "DOCKER-USER" ]]; then
  target_chain="${AGENTIC_DOCKER_USER_CHAIN:-AGENTIC-DOCKER-USER}"
  printf '%s\n' "-A DOCKER-USER -j ${target_chain}"
  exit 0
fi

if [[ "${chain}" == "AGENTIC-DOCKER-USER" ]]; then
  cat <<'RULES'
-A AGENTIC-DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A AGENTIC-DOCKER-USER --log-prefix "AGENTIC-DROP "
-A AGENTIC-DOCKER-USER -s 172.18.0.0/16 -j DROP
-A AGENTIC-DOCKER-USER -s 172.19.0.0/16 -j DROP
-A AGENTIC-DOCKER-USER -s 172.19.0.10/32 -p tcp --dport 80 -j ACCEPT
-A AGENTIC-DOCKER-USER -s 172.19.0.10/32 -p tcp --dport 443 -j ACCEPT
-A AGENTIC-DOCKER-USER -s 172.19.0.11/32 -p udp --dport 53 -j ACCEPT
-A AGENTIC-DOCKER-USER -s 172.19.0.11/32 -p tcp --dport 53 -j ACCEPT
-A AGENTIC-DOCKER-USER -s 172.19.0.12/32 -d 172.18.0.0/16 -j ACCEPT
-A AGENTIC-DOCKER-USER -s 172.19.0.12/32 -d 172.18.0.10/32 -p tcp --dport 3128 -j ACCEPT
-A AGENTIC-DOCKER-USER -s 172.19.0.12/32 -d 172.19.0.10/32 -p tcp --dport 3128 -j ACCEPT
-A AGENTIC-DOCKER-USER -s 172.19.0.12/32 -d 172.18.0.11/32 -p udp --dport 53 -j ACCEPT
-A AGENTIC-DOCKER-USER -s 172.19.0.12/32 -d 172.18.0.11/32 -p tcp --dport 53 -j ACCEPT
-A AGENTIC-DOCKER-USER -s 172.19.0.12/32 -d 172.19.0.11/32 -p udp --dport 53 -j ACCEPT
-A AGENTIC-DOCKER-USER -s 172.19.0.12/32 -d 172.19.0.11/32 -p tcp --dport 53 -j ACCEPT
-A AGENTIC-DOCKER-USER -j DROP
RULES
  exit 0
fi

exit 1
EOF

cat >"${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

outfile=""
write_code=0
url=""
while [[ $# -gt 0 ]]; do
  case "${1}" in
    -o)
      outfile="${2:-}"
      shift 2
      ;;
    -w)
      if [[ "${2:-}" == "%{http_code}" ]]; then
        write_code=1
      fi
      shift 2
      ;;
    -s|-S|-sS)
      shift
      ;;
    *)
      url="${1}"
      shift
      ;;
  esac
done

if [[ -n "${outfile}" ]]; then
  printf '<html>forgejo</html>\n' >"${outfile}"
fi
if [[ "${write_code}" -eq 1 ]]; then
  printf '200'
fi
if [[ -z "${outfile}" && "${write_code}" -eq 0 ]]; then
  printf '<html>forgejo</html>\n'
fi
if [[ -z "${url}" ]]; then
  exit 1
fi
exit 0
EOF

cat >"${fake_bin}/python3" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/python3 "$@"
EOF

chmod 0755 "${fake_bin}/docker" "${fake_bin}/iptables" "${fake_bin}/curl" "${fake_bin}/python3"

mkdir -p \
  "${runtime_root}/deployments/current" \
  "${runtime_root}/gate/state" \
  "${runtime_root}/gate/logs" \
  "${runtime_root}/gate/mcp/logs" \
  "${runtime_root}/monitoring/config" \
  "${runtime_root}/optional/git/bootstrap" \
  "${runtime_root}/secrets/runtime"

printf 'test-token\n' >"${runtime_root}/secrets/runtime/gate_mcp.token"
chmod 0600 "${runtime_root}/secrets/runtime/gate_mcp.token"

cat >"${runtime_root}/gate/state/llm_backend.json" <<'JSON'
{"backend":"both"}
JSON
cat >"${runtime_root}/gate/state/llm_backend_runtime.json" <<'JSON'
{"desired_backend":"both","effective_backend":"ollama","cooldown_until_epoch":0,"cooldown_until":""}
JSON
cat >"${runtime_root}/gate/state/sticky_sessions.json" <<'JSON'
{"anonymous":"nemotron-cascade-2:30b"}
JSON
cat >"${runtime_root}/gate/logs/gate.jsonl" <<'JSON'
{"ts":"2026-05-10T10:05:00Z","endpoint":"/v1/chat/completions","model_requested":"nemotron-cascade-2:30b","model_served":"nemotron-cascade-2:30b","status_code":200}
JSON

cat >"${runtime_root}/monitoring/config/retention-policy.env" <<'EOF'
AGENTIC_OBS_RETENTION_TIME=30d
AGENTIC_OBS_MAX_DISK=32GB
AGENTIC_PROMETHEUS_DISK_BUDGET=8GB
AGENTIC_LOKI_DISK_BUDGET=24GB
PROMETHEUS_RETENTION_TIME=30d
PROMETHEUS_RETENTION_SIZE=8GB
LOKI_RETENTION_PERIOD=30d
LOKI_MAX_QUERY_LOOKBACK=30d
EOF
cat >"${runtime_root}/monitoring/config/loki-config.yml" <<'EOF'
limits_config:
  retention_period: 30d
chunk_store_config:
  max_query_lookback: 30d
compactor:
  retention_enabled: true
  delete_request_store: filesystem
EOF

cat >"${runtime_root}/optional/git/bootstrap/git-forge-bootstrap.json" <<'JSON'
{
  "reference_repository": "eight-queens-agent-e2e",
  "reference_branch_policy": {
    "protected_branch": "main",
    "agent_branches": [
      "agent/codex",
      "agent/openclaw",
      "agent/claude",
      "agent/opencode",
      "agent/openhands",
      "agent/pi-mono",
      "agent/goose",
      "agent/vibestral",
      "agent/hermes"
    ],
    "main_push_allowlist_users": ["system-manager"]
  },
  "ssh_contract": {
    "host": "optional-forgejo",
    "port": 2222,
    "known_hosts_filename": "known_hosts",
    "managed_paths": {
      "codex": "/state/home/.ssh",
      "openhands": "/.openhands/home/.ssh",
      "openclaw": "/state/cli/openclaw-home/.ssh"
    }
  }
}
JSON

cat >"${runtime_root}/deployments/current/images.json" <<'JSON'
[
  {
    "service": "ollama",
    "configured_image": "ollama/ollama@sha256:1111111111111111111111111111111111111111111111111111111111111111"
  }
]
JSON
cat >"${runtime_root}/deployments/current/runtime.env" <<'EOF'
AGENTIC_CODEX_CLI_NPM_SPEC=@openai/codex@0.116.0
AGENTIC_OPENCLAW_INSTALL_VERSION=2026.3.22
EOF
cat >"${runtime_root}/deployments/current/latest-resolution.json" <<'JSON'
{"runtime_inputs":[],"docker_images":[]}
JSON
cat >"${runtime_root}/deployments/current/release.meta" <<'EOF'
release_id=test-doctor-contract
reason=update
EOF
cat >"${runtime_root}/deployments/current/compose.effective.yml" <<'EOF'
services: {}
EOF
cat >"${runtime_root}/deployments/current/compose.files" <<'EOF'
compose/compose.core.yml
EOF
cat >"${runtime_root}/deployments/current/health_report.json" <<'JSON'
{"services":[]}
JSON

/usr/bin/python3 - "${runtime_root}/deployments/current" <<'PY'
import hashlib
import json
import pathlib
import sys

release_dir = pathlib.Path(sys.argv[1])
files = {}
for path in sorted(release_dir.iterdir()):
    if not path.is_file() or path.name == "artifact-integrity.json":
        continue
    files[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()

(release_dir / "artifact-integrity.json").write_text(
    json.dumps({"files": files}, sort_keys=True, indent=2) + "\n",
    encoding="utf-8",
)
PY

export PATH="${fake_bin}:${PATH}"
export AGENTIC_ROOT="${runtime_root}"
export AGENTIC_OLLAMA_ESTIMATOR_TAGS_FILE="${REPO_ROOT}/tests/fixtures/ollama/tags.context-estimator.json"
export AGENTIC_OLLAMA_ESTIMATOR_SHOW_FILE="${REPO_ROOT}/tests/fixtures/ollama/show.nemotron-cascade-2-30b.json"
export AGENTIC_DOCTOR_CRITICAL_PORTS=11888
export AGENTIC_SKIP_DOCTOR_PROXY_CHECK=1

strict_host_out="${tmpdir}/strict-host.out"
set +e
AGENTIC_PROFILE=strict-prod \
AGENTIC_SKIP_DOCKER_USER_CHECK=0 \
AGENTIC_DOCKER_USER_CHAIN=AGENTIC-DOCTOR-MISSING \
bash "${doctor_script}" >"${strict_host_out}" 2>&1
strict_host_rc=$?
set -e
[[ "${strict_host_rc}" -ne 0 ]] || fail "strict-prod doctor must fail on host-root-only DOCKER-USER drift"
grep -q "FAIL: DOCKER-USER policy is missing or incomplete" "${strict_host_out}" \
  || fail "strict-prod host-root drift must stay blocking and explicit"
ok "strict-prod keeps host-root DOCKER-USER drift blocking"

rootless_skip_out="${tmpdir}/rootless-skip.out"
AGENTIC_PROFILE=rootless-dev \
AGENTIC_SKIP_DOCKER_USER_CHECK=1 \
bash "${doctor_script}" >"${rootless_skip_out}" 2>&1 \
  || fail "rootless-dev doctor must stay green when host-root-only checks are skipped"
grep -q "WARN: skip DOCKER-USER policy check because AGENTIC_SKIP_DOCKER_USER_CHECK=1" "${rootless_skip_out}" \
  || fail "rootless-dev default contract must expose the DOCKER-USER skip as a warning"
grep -q "WARN: skip proxy enforcement check because AGENTIC_SKIP_DOCTOR_PROXY_CHECK=1" "${rootless_skip_out}" \
  || fail "rootless-dev skip contract must keep proxy check downgrade explicit"
ok "rootless-dev default host-root checks are downgraded to warnings/skips"

rootless_warn_out="${tmpdir}/rootless-warn.out"
AGENTIC_PROFILE=rootless-dev \
AGENTIC_SKIP_DOCKER_USER_CHECK=0 \
AGENTIC_DOCKER_USER_CHAIN=AGENTIC-DOCTOR-MISSING \
bash "${doctor_script}" >"${rootless_warn_out}" 2>&1 \
  || fail "rootless-dev doctor must downgrade explicit host-root DOCKER-USER drift to a warning"
grep -q "WARN: DOCKER-USER policy is missing or incomplete" "${rootless_warn_out}" \
  || fail "rootless-dev explicit host-root drift must be downgraded to WARN"
ok "rootless-dev explicit host-root drift is downgraded to warning"

server_pid=""
python3 -m http.server 11888 --bind 0.0.0.0 >"${tmpdir}/http-server.log" 2>&1 &
server_pid="$!"
sleep 1

strict_bind_out="${tmpdir}/strict-bind.out"
set +e
AGENTIC_PROFILE=strict-prod \
AGENTIC_SKIP_DOCKER_USER_CHECK=1 \
bash "${doctor_script}" >"${strict_bind_out}" 2>&1
strict_bind_rc=$?
set -e
[[ "${strict_bind_rc}" -ne 0 ]] || fail "strict-prod doctor must fail on public critical port drift"
grep -Eqi 'critical ports|non-loopback|exposed' "${strict_bind_out}" \
  || fail "strict-prod public bind drift must remain explicit"
ok "strict-prod public critical port drift stays blocking"

rootless_bind_out="${tmpdir}/rootless-bind.out"
set +e
AGENTIC_PROFILE=rootless-dev \
AGENTIC_SKIP_DOCKER_USER_CHECK=1 \
bash "${doctor_script}" >"${rootless_bind_out}" 2>&1
rootless_bind_rc=$?
set -e
[[ "${rootless_bind_rc}" -ne 0 ]] || fail "rootless-dev doctor must still fail on public critical port drift"
grep -Eqi 'critical ports|non-loopback|exposed' "${rootless_bind_out}" \
  || fail "rootless-dev public bind drift must remain explicit"
ok "rootless-dev still blocks on runtime public bind drift"

kill "${server_pid}" >/dev/null 2>&1 || true
wait "${server_pid}" 2>/dev/null || true
server_pid=""

ok "F12_doctor_profile_contract passed"
