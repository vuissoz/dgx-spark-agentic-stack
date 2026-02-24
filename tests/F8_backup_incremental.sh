#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F8 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

assert_cmd python3
assert_cmd rsync

suffix="f8-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-${suffix}"
export AGENTIC_EGRESS_NETWORK="agentic-${suffix}-egress"

cleanup() {
  if [[ -d "${AGENTIC_ROOT}" ]]; then
    find "${AGENTIC_ROOT}" -mindepth 1 -depth \( -type f -o -type l -o -type s -o -type p \) -delete || true
    find "${AGENTIC_ROOT}" -mindepth 1 -depth -type d -empty -delete || true
    rmdir "${AGENTIC_ROOT}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"${REPO_ROOT}/deployments/bootstrap/init_fs.sh" >/tmp/agent-f8-initfs.out

mkdir -p "${AGENTIC_ROOT}/codex/workspaces/demo"
mkdir -p "${AGENTIC_ROOT}/claude/state"
mkdir -p "${AGENTIC_ROOT}/secrets/runtime"
printf 'version-one\n' >"${AGENTIC_ROOT}/codex/workspaces/demo/readme.txt"
printf 'marker-one\n' >"${AGENTIC_ROOT}/claude/state/marker.txt"
printf 'super-secret-key\n' >"${AGENTIC_ROOT}/secrets/runtime/openai.api_key"

run1_output="$("${agent_bin}" backup run)"
id1="$(printf '%s\n' "${run1_output}" | sed -n 's/^snapshot_id=//p' | tail -n 1)"
[[ -n "${id1}" ]] || fail "backup run #1 did not report a snapshot id"

snapshots_root="${AGENTIC_ROOT}/deployments/backups/snapshots"
snap1_dir="${snapshots_root}/${id1}"
[[ -d "${snap1_dir}" ]] || fail "backup snapshot #1 directory missing"
[[ -f "${snap1_dir}/metadata/backup.json" ]] || fail "backup snapshot #1 metadata missing"
ok "first backup snapshot created (${id1})"

sleep 1
run2_output="$("${agent_bin}" backup run)"
id2="$(printf '%s\n' "${run2_output}" | sed -n 's/^snapshot_id=//p' | tail -n 1)"
changed2="$(printf '%s\n' "${run2_output}" | sed -n 's/^changed_entries=//p' | tail -n 1)"
[[ -n "${id2}" ]] || fail "backup run #2 did not report a snapshot id"
[[ "${changed2}" =~ ^[0-9]+$ ]] || fail "backup run #2 did not report numeric changed_entries"
[[ "${changed2}" -le 3 ]] || fail "backup run #2 should be near-zero incremental delta (changed_entries=${changed2})"
ok "second backup snapshot is incremental (changed_entries=${changed2})"

printf 'version-two\n' >"${AGENTIC_ROOT}/codex/workspaces/demo/readme.txt"
printf 'marker-two\n' >"${AGENTIC_ROOT}/claude/state/marker.txt"
printf 'private-key-material\n' >"${AGENTIC_ROOT}/codex/workspaces/demo/key.PEM"

sleep 1
run3_output="$("${agent_bin}" backup run)"
id3="$(printf '%s\n' "${run3_output}" | sed -n 's/^snapshot_id=//p' | tail -n 1)"
changed3="$(printf '%s\n' "${run3_output}" | sed -n 's/^changed_entries=//p' | tail -n 1)"
[[ -n "${id3}" ]] || fail "backup run #3 did not report a snapshot id"
[[ "${changed3}" =~ ^[0-9]+$ ]] || fail "backup run #3 did not report numeric changed_entries"
[[ "${changed3}" -gt 0 ]] || fail "backup run #3 should include a non-zero delta after targeted file changes"

grep -q 'codex/workspaces/demo/readme.txt' "${snapshots_root}/${id3}/metadata/rsync.changes" \
  || fail "snapshot #3 delta does not include updated codex workspace file"
ok "targeted modifications are captured in incremental delta"

printf 'corrupted\n' >"${AGENTIC_ROOT}/codex/workspaces/demo/readme.txt"
rm -f "${AGENTIC_ROOT}/claude/state/marker.txt"

"${agent_bin}" backup restore "${id3}" --yes >/tmp/agent-f8-restore.out \
  || fail "backup restore failed for snapshot ${id3}"

grep -q '^version-two$' "${AGENTIC_ROOT}/codex/workspaces/demo/readme.txt" \
  || fail "backup restore did not restore codex workspace file content"
grep -q '^marker-two$' "${AGENTIC_ROOT}/claude/state/marker.txt" \
  || fail "backup restore did not restore claude state file"
[[ ! -f "${AGENTIC_ROOT}/codex/workspaces/demo/key.PEM" ]] \
  || fail "backup restore should remove excluded key material patterns"
ok "backup restore restored targeted persistent files"

list_output="$("${agent_bin}" backup list)"
printf '%s\n' "${list_output}" | grep -q '^retention=hourly:' \
  || fail "backup list must report retention policy"
printf '%s\n' "${list_output}" | grep -q "snapshot_id=${id3}" \
  || fail "backup list must include latest snapshot id"
ok "backup list reports retention policy and snapshots"

for snapshot_id in "${id1}" "${id2}" "${id3}"; do
  snapshot_dir="${snapshots_root}/${snapshot_id}"
  [[ -f "${snapshot_dir}/metadata/files.list" ]] || fail "snapshot ${snapshot_id} missing files.list"

  if grep -Eq '^secrets(/|$)' "${snapshot_dir}/metadata/files.list"; then
    fail "snapshot ${snapshot_id} must not include secrets path"
  fi

  if find "${snapshot_dir}/data" -path '*/secrets/*' -print -quit | grep -q .; then
    fail "snapshot ${snapshot_id} contains secrets data"
  fi

  if grep -Eqi 'openai\.api_key|\.pem$|\.key$|\.p12$|\.pfx$' "${snapshot_dir}/metadata/files.list"; then
    fail "snapshot ${snapshot_id} contains file patterns treated as sensitive"
  fi
done
ok "backup snapshots exclude secret material"

ok "F8_backup_incremental passed"
