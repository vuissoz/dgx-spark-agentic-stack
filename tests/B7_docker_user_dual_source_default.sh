#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_B_NETWORK_TESTS:-0}" == "1" ]]; then
  ok "B7 skipped because AGENTIC_SKIP_B_NETWORK_TESTS=1"
  exit 0
fi

if [[ "${AGENTIC_PROFILE:-strict-prod}" == "rootless-dev" ]]; then
  ok "B7 skipped in rootless-dev profile (strict DOCKER-USER default-source integration is strict-prod only)"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd iptables
assert_cmd iptables-save
assert_cmd sha256sum
assert_cmd awk
assert_cmd docker

chain="${AGENTIC_DOCKER_USER_CHAIN:-AGENTIC-DOCKER-USER}"
internal_network="${AGENTIC_NETWORK:-agentic}"
egress_network="${AGENTIC_EGRESS_NETWORK:-agentic-egress}"
expected_default="${internal_network},${egress_network}"
previous_source_networks="${AGENTIC_DOCKER_USER_SOURCE_NETWORKS-__agentic_unset__}"

docker_user_fingerprint() {
  iptables-save | awk -v chain="${chain}" '
    $0 == "*filter" {in_filter=1; next}
    in_filter && $0 == "COMMIT" {in_filter=0}
    !in_filter {next}
    /^:DOCKER-USER / || ($0 ~ "^:" chain " ") {
      gsub(/\[[0-9]+:[0-9]+\]/, "", $0)
      print
      next
    }
    $1 == "-A" && ($2 == "DOCKER-USER" || $2 == chain) {print}
  ' | sha256sum | awk '{print $1}'
}

restore_source_networks_env() {
  if [[ "${previous_source_networks}" == "__agentic_unset__" ]]; then
    unset AGENTIC_DOCKER_USER_SOURCE_NETWORKS
  else
    export AGENTIC_DOCKER_USER_SOURCE_NETWORKS="${previous_source_networks}"
  fi
}

trap restore_source_networks_env EXIT

source "${REPO_ROOT}/scripts/lib/runtime.sh"
unset AGENTIC_DOCKER_USER_SOURCE_NETWORKS
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"
[[ "${AGENTIC_DOCKER_USER_SOURCE_NETWORKS}" == "${expected_default}" ]] \
  || fail "runtime default AGENTIC_DOCKER_USER_SOURCE_NETWORKS must resolve to ${expected_default} (got ${AGENTIC_DOCKER_USER_SOURCE_NETWORKS})"
ok "runtime default AGENTIC_DOCKER_USER_SOURCE_NETWORKS resolves to both internal and egress networks"

fingerprint_before="$(docker_user_fingerprint)"

set +e
apply_output="$(env -u AGENTIC_DOCKER_USER_SOURCE_NETWORKS "${agent_bin}" net apply 2>&1)"
apply_rc=$?
set -e

if [[ "${apply_rc}" -ne 0 ]]; then
  printf '%s\n' "${apply_output}" >&2
  fail "agent net apply failed with default dual-source configuration"
fi

backup_id="$(printf '%s\n' "${apply_output}" | sed -n 's/^backup_id=//p' | tail -n 1)"
[[ -n "${backup_id}" ]] || fail "agent net apply did not report backup_id"
ok "agent net apply succeeded with default dual-source configuration (backup_id=${backup_id})"

internal_subnet="$(docker network inspect "${internal_network}" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
egress_subnet="$(docker network inspect "${egress_network}" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
[[ -n "${internal_subnet}" ]] || fail "cannot resolve subnet for ${internal_network}"
[[ -n "${egress_subnet}" ]] || fail "cannot resolve subnet for ${egress_network}"

chain_rules="$(iptables -S "${chain}" 2>/dev/null)" || fail "iptables chain '${chain}' is missing after net apply"
printf '%s\n' "${chain_rules}" | grep -Fq -- "-s ${internal_subnet} -j DROP" \
  || fail "${chain} is missing DROP coverage for default internal subnet ${internal_subnet}"
printf '%s\n' "${chain_rules}" | grep -Fq -- "-s ${egress_subnet} -j DROP" \
  || fail "${chain} is missing DROP coverage for default egress subnet ${egress_subnet}"
ok "iptables chain carries DROP coverage for both default source subnets"

unset AGENTIC_DOCKER_USER_SOURCE_NETWORKS
assert_docker_user_policy || fail "default dual-source DOCKER-USER policy validation failed"
ok "shared DOCKER-USER validator accepts the default dual-source policy"

set +e
rollback_output="$("${agent_bin}" rollback host-net "${backup_id}" 2>&1)"
rollback_rc=$?
set -e

if [[ "${rollback_rc}" -ne 0 ]]; then
  printf '%s\n' "${rollback_output}" >&2
  fail "agent rollback host-net ${backup_id} failed"
fi

printf '%s\n' "${rollback_output}" | grep -q "rollback completed backup_id=${backup_id}" \
  || fail "host-net rollback output did not confirm the restored backup id"

fingerprint_after="$(docker_user_fingerprint)"
[[ "${fingerprint_after}" == "${fingerprint_before}" ]] \
  || fail "DOCKER-USER chain state differs after rollback (before=${fingerprint_before}, after=${fingerprint_after})"
ok "host-net rollback restored the original DOCKER-USER chain state"

ok "B7_docker_user_dual_source_default passed"
