#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd docker
assert_cmd curl

docker image inspect agentic/trtllm-runtime:local >/dev/null 2>&1 \
  || fail "missing local image agentic/trtllm-runtime:local; build core images first"
docker image inspect agentic/ollama-gate:local >/dev/null 2>&1 \
  || fail "missing local image agentic/ollama-gate:local; build core images first"

tmp_root="$(mktemp -d)"
network_name="codex-trt-stream-$$"
trt_name="codex-trt-stream-trt-$$"
gate_name="codex-trt-stream-gate-$$"

cleanup() {
  docker rm -f "${gate_name}" "${trt_name}" >/dev/null 2>&1 || true
  docker network rm "${network_name}" >/dev/null 2>&1 || true
  if [[ -d "${tmp_root}" ]]; then
    docker run --rm \
      -v "${tmp_root}:/cleanup" \
      --entrypoint /bin/sh \
      agentic/trtllm-runtime:local \
      -c "chown -R $(id -u):$(id -g) /cleanup" >/dev/null 2>&1 || true
    rm -rf "${tmp_root}" || true
  fi
}
trap cleanup EXIT

mkdir -p \
  "${tmp_root}/gate-config" \
  "${tmp_root}/gate-state" \
  "${tmp_root}/gate-logs" \
  "${tmp_root}/trt-state" \
  "${tmp_root}/trt-logs" \
  "${tmp_root}/trt-models"

cat >"${tmp_root}/gate-config/model_routes.yml" <<'YAML'
version: 1
defaults:
  backend: trtllm
backends:
  trtllm:
    protocol: ollama
    base_url: http://codex-trt-stream-trt-PLACEHOLDER:11436
routes:
  - name: default-trt
    backend: trtllm
    match:
      - "https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8"
      - "trtllm/nvidia-nemotron-3-nano-30b-a3b-fp8"
YAML
sed -i "s/codex-trt-stream-trt-PLACEHOLDER/${trt_name}/g" "${tmp_root}/gate-config/model_routes.yml"

docker network create "${network_name}" >/dev/null

docker run -d \
  --name "${trt_name}" \
  --network "${network_name}" \
  -e TRTLLM_RUNTIME_MODE=mock \
  -e TRTLLM_LISTEN_HOST=0.0.0.0 \
  -e TRTLLM_PORT=11436 \
  -e TRTLLM_STATE_DIR=/state \
  -e TRTLLM_LOGS_DIR=/logs \
  -e TRTLLM_MODELS_DIR=/models \
  -v "${tmp_root}/trt-state:/state" \
  -v "${tmp_root}/trt-logs:/logs" \
  -v "${tmp_root}/trt-models:/models" \
  agentic/trtllm-runtime:local >/dev/null

docker run -d \
  --name "${gate_name}" \
  --network "${network_name}" \
  -p 127.0.0.1:18035:11435 \
  -e OLLAMA_BASE_URL="http://${trt_name}:11436" \
  -e TRTLLM_BASE_URL="http://${trt_name}:11436" \
  -e GATE_MODEL_ROUTES_FILE=/gate/config/model_routes.yml \
  -e GATE_STATE_DIR=/gate/state \
  -e GATE_LOG_FILE=/gate/logs/gate.jsonl \
  -v "${tmp_root}/gate-config:/gate/config:ro" \
  -v "${tmp_root}/gate-state:/gate/state" \
  -v "${tmp_root}/gate-logs:/gate/logs" \
  agentic/ollama-gate:local >/dev/null

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:18035/healthz >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

headers_file="${tmp_root}/headers.txt"
body_file="${tmp_root}/body.txt"
status_code="$(curl -N -sS \
  -D "${headers_file}" \
  -o "${body_file}" \
  -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d '{"model":"trtllm/nvidia-nemotron-3-nano-30b-a3b-fp8","messages":[{"role":"user","content":"Hello"}],"stream":true}' \
  http://127.0.0.1:18035/v1/chat/completions)"

[[ "${status_code}" == "200" ]] || {
  cat "${headers_file}" >&2 || true
  cat "${body_file}" >&2 || true
  fail "gate TRT streaming request returned status ${status_code}"
}

grep -qi '^content-type: text/event-stream' "${headers_file}" \
  || fail "gate TRT streaming response is not SSE"
grep -qi '^x-gate-backend: trtllm' "${headers_file}" \
  || fail "gate TRT streaming response did not route to trtllm"
grep -q '^data: {' "${body_file}" \
  || fail "gate TRT streaming response missing JSON chunks"
grep -q 'chat.completion.chunk' "${body_file}" \
  || fail "gate TRT streaming response missing OpenAI chunk objects"
grep -q 'trtllm synthetic response' "${body_file}" \
  || fail "gate TRT streaming response missing TRT content delta"
grep -q '^data: \[DONE\]$' "${body_file}" \
  || fail "gate TRT streaming response missing [DONE] terminator"

ok "gate forwards TRT chat streaming as SSE chunks"
