#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_C_TESTS:-0}" == "1" ]]; then
  ok "C3 skipped because AGENTIC_SKIP_C_TESTS=1"
  exit 0
fi

assert_cmd curl

trt_cid="$(service_container_id trtllm)"
if [[ -z "${trt_cid}" ]]; then
  ok "C3 skipped because trtllm profile is not enabled (set COMPOSE_PROFILES=trt)"
  exit 0
fi

gate_cid="$(require_service_container ollama-gate)"
toolbox_cid="$(require_service_container toolbox)"

wait_for_container_ready "${gate_cid}" 90 || fail "ollama-gate is not ready"
wait_for_container_ready "${toolbox_cid}" 60 || fail "toolbox is not ready"
wait_for_container_ready "${trt_cid}" 120 || fail "trtllm is not ready"

published_trt="$(docker port "${trt_cid}" 11436/tcp 2>/dev/null || true)"
[[ -z "${published_trt}" ]] || fail "trtllm port 11436 must not be published on host (got: ${published_trt})"
ok "trtllm has no host-published ports"

set +e
curl -fsS --max-time 3 http://127.0.0.1:11436/healthz >/dev/null 2>&1
host_direct_rc=$?
set -e
[[ "${host_direct_rc}" -ne 0 ]] || fail "host direct access to trtllm must be unavailable"
ok "host direct access to trtllm is blocked"

timeout 15 docker exec "${gate_cid}" sh -lc 'python3 -c "import sys,urllib.request; sys.exit(0 if urllib.request.urlopen(\"http://trtllm:11436/healthz\", timeout=4).status == 200 else 1)"' \
  || fail "ollama-gate cannot reach trtllm internal endpoint"
ok "ollama-gate reaches trtllm internal endpoint"

timeout 20 docker exec -i "${gate_cid}" python3 - <<'PY' \
  || fail "trtllm runtime health/models contract is invalid"
import json
import urllib.request

health = json.loads(urllib.request.urlopen("http://trtllm:11436/healthz", timeout=5).read().decode("utf-8"))
assert health["runtime_mode_requested"] in {"auto", "mock", "native"}, health
assert health["runtime_mode_effective"] in {"mock", "native"}, health
assert health["primary_model_requested"], health

models = json.loads(urllib.request.urlopen("http://trtllm:11436/v1/models", timeout=5).read().decode("utf-8"))
data = models.get("data")
assert isinstance(data, list) and data, models
assert isinstance(data[0], dict) and data[0].get("id"), models
print("ok")
PY
ok "trtllm exposes health metadata and a non-empty model catalog"

set +e
timeout 10 docker exec "${toolbox_cid}" sh -lc 'curl -fsS --max-time 4 http://trtllm:11436/healthz >/dev/null 2>&1'
toolbox_rc=$?
set -e
[[ "${toolbox_rc}" -ne 0 ]] || fail "toolbox must not reach trtllm directly"
ok "non-gate internal direct access to trtllm is blocked"

ok "C3_trtllm_basic passed"
