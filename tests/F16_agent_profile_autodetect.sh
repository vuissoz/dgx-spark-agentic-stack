#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

mock_home="${tmp_root}/home"
mock_bin="${tmp_root}/bin"
mkdir -p "${mock_home}/.local/share/agentic/deployments" "${mock_bin}"

cat >"${mock_home}/.local/share/agentic/deployments/runtime.env" <<EOF
AGENTIC_PROFILE=rootless-dev
AGENTIC_ROOT=${mock_home}/.local/share/agentic
AGENTIC_COMPOSE_PROJECT=agentic-dev
EOF

cat >"${mock_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "ps" ]]; then
  shift
  project=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --filter)
        if [[ $# -lt 2 ]]; then
          exit 1
        fi
        case "$2" in
          label=com.docker.compose.project=agentic-dev)
            project="agentic-dev"
            ;;
          label=com.docker.compose.project=agentic)
            project="agentic"
            ;;
        esac
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  if [[ "${MOCK_DOCKER_BOTH:-0}" == "1" ]]; then
    printf 'ambiguous-runtime\n'
    exit 0
  fi
  if [[ "${project}" == "agentic-dev" ]]; then
    printf 'agentic-dev-openwebui-1\n'
  fi
  exit 0
fi

exit 0
EOF
chmod +x "${mock_bin}/docker"

profile_output="$(env -i HOME="${mock_home}" PATH="${mock_bin}:/usr/bin:/bin" "${agent_bin}" profile)"
printf '%s\n' "${profile_output}" | grep -q '^profile=rootless-dev$' \
  || fail "agent wrapper did not auto-resolve active rootless-dev profile"
printf '%s\n' "${profile_output}" | grep -q "^root=${mock_home}/.local/share/agentic$" \
  || fail "agent wrapper did not load rootless runtime root"
printf '%s\n' "${profile_output}" | grep -q '^compose_project=agentic-dev$' \
  || fail "agent wrapper did not load rootless compose project"
ok "agent wrapper auto-resolves active rootless-dev runtime"

strict_output="$(env -i HOME="${mock_home}" PATH="${mock_bin}:/usr/bin:/bin" "${agent_bin}" strict-prod profile)"
printf '%s\n' "${strict_output}" | grep -q '^profile=strict-prod$' \
  || fail "explicit strict-prod argument must override auto-detection"
ok "explicit profile argument still overrides runtime auto-detection"

ambiguity_output="$(env -i HOME="${mock_home}" PATH="${mock_bin}:/usr/bin:/bin" MOCK_DOCKER_BOTH=1 "${agent_bin}" profile 2>&1 || true)"
printf '%s\n' "${ambiguity_output}" | grep -q 'both rootless-dev and strict-prod stacks appear active' \
  || fail "ambiguous active stacks must fail closed with an explicit profile hint"
ok "ambiguous active stacks fail closed"

ok "F16_agent_profile_autodetect passed"
