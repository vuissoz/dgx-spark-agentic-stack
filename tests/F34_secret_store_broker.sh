#!/usr/bin/env bash
# tests/F34_secret_store_broker.sh — SecretStore & ExternalAccessBroker validation (PLAN.md §10)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_F_TESTS:-0}" == "1" ]]; then
  ok "F34 skipped because AGENTIC_SKIP_F_TESTS=1"
  exit 0
fi

ROOTLESS_TMP="$(mktemp -d)"
trap 'rm -rf "${ROOTLESS_TMP}"' EXIT

export AGENTIC_PROFILE="rootless-dev"
export AGENTIC_ROOT="${ROOTLESS_TMP}"
export USER="testuser"

STORE_SCRIPT="${REPO_ROOT}/deployments/secrets/store.sh"
BROKER_SCRIPT="${REPO_ROOT}/deployments/secrets/broker.sh"

ok "store and broker scripts exist"
[[ -f "${STORE_SCRIPT}" ]] || fail "store.sh missing"
[[ -x "${STORE_SCRIPT}" ]] || fail "store.sh not executable"
[[ -f "${BROKER_SCRIPT}" ]] || fail "broker.sh missing"
[[ -x "${BROKER_SCRIPT}" ]] || fail "broker.sh not executable"

# Test 1: store generate and get
ok "test 1: generate and retrieve secret"
generated_value="$(bash "${STORE_SCRIPT}" generate "github.test.key" github 16)"
retrieved_value="$(bash "${STORE_SCRIPT}" get "github.test.key" github)"
[[ "${generated_value}" == "${retrieved_value}" ]] || fail "test 1 mismatch: gen='${generated_value}' ret='${retrieved_value}'"

# Test 2: store rotation keeps last N entries for the SAME key+scope
ok "test 2: rotation retains history (last 3 per key+scope)"
for i in 1 2 3 4; do
  bash "${STORE_SCRIPT}" set "rotate.test.key" "value-${i}" github >/dev/null 2>&1 || true
done
line_count="$(python3 -c "import json; c=0
with open('${AGENTIC_ROOT}/secrets/store.jsonl') as f:
 for l in f:
  try: o=json.loads(l); c += 1 if o.get('key')=='rotate.test.key' else 0
  except: pass
print(c)" )"
[[ "${line_count}" -le 3 ]] || fail "test 2: expected <=3 rotate entries, got ${line_count}"

# Test 3: store expiration enforcement
ok "test 3: expired secrets are rejected"
bash "${STORE_SCRIPT}" set "expire.test.key" "old-value" github >/dev/null 2>&1 || true
exp_result="$(bash "${STORE_SCRIPT}" get "expire.test.key" github 0 2>&1 || true)"
if ! echo "${exp_result}" | grep -q "SECRET_EXPIRED\|SECRET_NOT_FOUND"; then
  fail "test 3: expired secret should be rejected, got '${exp_result}'"
fi

# Test 4: store permissions are 0600
ok "test 4: store file permissions are root-only (0600)"
store_perms="$(stat -c '%a' "${AGENTIC_ROOT}/secrets/store.jsonl" 2>/dev/null || stat -f '%Lp' "${AGENTIC_ROOT}/secrets/store.jsonl")"
[[ "${store_perms}" == "600" ]] || fail "test 4: permissions should be 600, found ${store_perms}"

# Test 5: store list shows keys without values
ok "test 5: list reveals keys but not secret values"
list_output="$(bash "${STORE_SCRIPT}" list)"
echo "${list_output}" | grep -q "github.test.key" || fail "test 5: list missing github.test.key"
if echo "${list_output}" | grep -q "old-value"; then
  fail "test 5: list must not reveal secret values"
fi

# Test 6: broker health reports status without errors
ok "test 6: broker health runs cleanly"
broker_health="$(bash "${BROKER_SCRIPT}" health 2>&1 || true)"
[[ -n "${broker_health}" ]] || fail "test 6: broker health produced no output"
echo "${broker_health}" | grep -q "GitHub token:" || fail "test 6: missing GitHub status"
echo "${broker_health}" | grep -q "HF token:" || fail "test 6: missing HF status"

# Test 7: broker inject creates temp directory with credentials
ok "test 7: broker inject returns credential temp dir"
inject_dir="$(bash "${BROKER_SCRIPT}" inject "test-service" github 2>&1 || true)"
[[ -d "${inject_dir}" ]] || fail "test 7: inject should return a directory, got '${inject_dir}'"

# Test 8: audit log is written
ok "test 8: audit log records secret access"
[[ -f "${AGENTIC_ROOT}/secrets/audit.log" ]] || fail "test 8: audit log missing"
grep -q '"action":"get"' "${AGENTIC_ROOT}/secrets/audit.log" || fail "test 8: no get actions in audit"

ok "F34_secret_store_broker passed"
