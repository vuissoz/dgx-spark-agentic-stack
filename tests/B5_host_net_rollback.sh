#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_B_NETWORK_TESTS:-0}" == "1" ]]; then
  ok "B5 skipped because AGENTIC_SKIP_B_NETWORK_TESTS=1"
  exit 0
fi

if [[ "${AGENTIC_PROFILE:-strict-prod}" == "rootless-dev" ]]; then
  ok "B5 skipped in rootless-dev profile (host net rollback is strict-prod only)"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd iptables
assert_cmd iptables-save
assert_cmd sha256sum
assert_cmd awk

chain="${AGENTIC_DOCKER_USER_CHAIN:-AGENTIC-DOCKER-USER}"

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

fingerprint_before="$(docker_user_fingerprint)"

set +e
apply_output="$("${agent_bin}" net apply 2>&1)"
apply_rc=$?
set -e

if [[ "${apply_rc}" -ne 0 ]]; then
  printf '%s\n' "${apply_output}" >&2
  fail "agent net apply failed"
fi

backup_id="$(printf '%s\n' "${apply_output}" | sed -n 's/^backup_id=//p' | tail -n 1)"
[[ -n "${backup_id}" ]] || fail "agent net apply did not report backup_id"
ok "agent net apply created backup ${backup_id}"

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
  || fail "DOCKER-USER/agentic chain state differs after rollback (before=${fingerprint_before}, after=${fingerprint_after})"
ok "host-net rollback restored DOCKER-USER chain state"

changes_log="${AGENTIC_ROOT:-/srv/agentic}/deployments/changes.log"
[[ -s "${changes_log}" ]] || fail "changes log missing or empty: ${changes_log}"
grep -q "action=host-net-backup backup_id=${backup_id}" "${changes_log}" \
  || fail "changes log missing host-net-backup record for ${backup_id}"
grep -q "action=host-net-apply backup_id=${backup_id}" "${changes_log}" \
  || fail "changes log missing host-net-apply record for ${backup_id}"
grep -q "action=host-net-rollback backup_id=${backup_id}" "${changes_log}" \
  || fail "changes log missing host-net-rollback record for ${backup_id}"
ok "changes log contains apply/rollback audit trail for backup ${backup_id}"

ok "B5_host_net_rollback passed"
