#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F10b skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
validator="${REPO_ROOT}/deployments/releases/validate_release_artifacts.py"
integrity_writer="${REPO_ROOT}/deployments/releases/write_release_integrity.py"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"
[[ -f "${validator}" ]] || fail "release artifact validator is missing: ${validator}"
[[ -f "${integrity_writer}" ]] || fail "release integrity writer is missing: ${integrity_writer}"

assert_cmd docker
assert_cmd python3

suffix="f10b-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${REPO_ROOT}/.runtime/${suffix}-root"
export AGENTIC_COMPOSE_PROJECT="agentic-${suffix}"
export AGENTIC_NETWORK="agentic-${suffix}"
export AGENTIC_LLM_NETWORK="agentic-${suffix}-llm"
export AGENTIC_EGRESS_NETWORK="agentic-${suffix}-egress"
export OLLAMA_HOST_PORT="$((20000 + (RANDOM % 10000)))"
export OPENCLAW_WEBHOOK_HOST_PORT="$((30000 + (RANDOM % 10000)))"
export OPENCLAW_RELAY_HOST_PORT="$((40000 + (RANDOM % 10000)))"
export OPENCLAW_GATEWAY_HOST_PORT="$((50000 + (RANDOM % 1000)))"
export OPENCLAW_GATEWAY_PROXY_METRICS_PORT="$((51000 + (RANDOM % 1000)))"
images_backup=""

cleanup() {
  "${agent_bin}" down core >/tmp/agent-f10b-down.out 2>&1 || true
  docker network rm "${AGENTIC_EGRESS_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${AGENTIC_LLM_NETWORK}" >/dev/null 2>&1 || true
  docker network rm "${AGENTIC_NETWORK}" >/dev/null 2>&1 || true
  [[ -z "${images_backup}" ]] || rm -f "${images_backup}" >/dev/null 2>&1 || true
  if [[ -d "${AGENTIC_ROOT}" ]]; then
    find "${AGENTIC_ROOT}" -mindepth 1 -depth \( -type f -o -type l -o -type s -o -type p \) -delete || true
    find "${AGENTIC_ROOT}" -mindepth 1 -depth -type d -empty -delete || true
    rmdir "${AGENTIC_ROOT}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"${REPO_ROOT}/deployments/bootstrap/init_fs.sh" >/tmp/agent-f10b-initfs.out
secret_file="${AGENTIC_ROOT}/secrets/runtime/openai.api_key"
secret_value="f10b-release-secret-${suffix}-$(date +%s)"
printf '%s\n' "${secret_value}" >"${secret_file}"
chmod 0600 "${secret_file}"

"${agent_bin}" up core >/tmp/agent-f10b-up-core.out \
  || fail "agent up core failed in F10b"
"${REPO_ROOT}/deployments/releases/snapshot.sh" \
  --reason f10b-release-integrity \
  "${REPO_ROOT}/compose/compose.core.yml" >/tmp/agent-f10b-snapshot.out \
  || fail "release snapshot creation failed in F10b"

release_dir="$(readlink -f "${AGENTIC_ROOT}/deployments/current")"
[[ -d "${release_dir}" ]] || fail "current release symlink must resolve to a directory"
[[ -s "${release_dir}/artifact-integrity.json" ]] || fail "release must be sealed with artifact-integrity.json"
images_backup="$(mktemp)"

python3 "${validator}" --release-dir "${release_dir}" --secrets-dir "${AGENTIC_ROOT}/secrets" \
  >/tmp/agent-f10b-validate-clean.out 2>&1 \
  || fail "clean release artifacts must validate"
ok "clean release artifact integrity and secret hygiene validate"

"${agent_bin}" doctor >/tmp/agent-f10b-doctor-clean.out 2>&1 || true
grep -q 'active release artifact integrity and secret hygiene are valid' /tmp/agent-f10b-doctor-clean.out \
  || fail "doctor must report release artifact integrity validation"
ok "doctor reports clean sealed release validation"

cp "${release_dir}/images.json" "${images_backup}"
printf '\n' >>"${release_dir}/images.json"
set +e
python3 "${validator}" --release-dir "${release_dir}" --secrets-dir "${AGENTIC_ROOT}/secrets" \
  >/tmp/agent-f10b-validate-tamper.out 2>&1
tamper_rc=$?
set -e
[[ "${tamper_rc}" -ne 0 ]] || fail "tampered release artifacts must fail validation"
grep -q 'release artifact checksum mismatch: images.json' /tmp/agent-f10b-validate-tamper.out \
  || fail "tamper validation must report the checksum mismatch"
ok "artifact checksum drift is detected"

cp "${images_backup}" "${release_dir}/images.json"
rm -f "${images_backup}"
printf 'OPENAI_API_KEY=%s\n' "${secret_value}" >>"${release_dir}/runtime.env"
python3 "${integrity_writer}" --release-dir "${release_dir}" >/tmp/agent-f10b-reseal.out 2>&1 \
  || fail "resealing mutated release must succeed"

set +e
"${agent_bin}" doctor >/tmp/agent-f10b-doctor-leak.out 2>&1
set -e
grep -q 'leaks secret content from runtime/openai.api_key: runtime.env' /tmp/agent-f10b-doctor-leak.out \
  || fail "doctor leak output must identify the leaked secret source and artifact"
grep -q 'active release artifact integrity or secret hygiene validation failed' /tmp/agent-f10b-doctor-leak.out \
  || fail "doctor must fail explicitly on release secret leaks"
ok "doctor fails explicitly on release secret leaks"

ok "F10b_release_artifact_integrity passed"
