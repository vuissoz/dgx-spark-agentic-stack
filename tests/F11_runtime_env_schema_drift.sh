#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

agent_bin="${REPO_ROOT}/agent"
runtime_lib="${REPO_ROOT}/scripts/lib/runtime.sh"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"
[[ -f "${runtime_lib}" ]] || fail "runtime lib is missing"

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

schema_dump() {
  AGENTIC_PROFILE=rootless-dev bash -lc '
    source "'"${runtime_lib}"'"
    agentic_runtime_schema
  '
}

schema_role_dump() {
  local role="$1"
  AGENTIC_PROFILE=rootless-dev bash -lc '
    source "'"${runtime_lib}"'"
    agentic_runtime_schema_iter_role "'"${role}"'"
  '
}

schema_file="${tmp_root}/runtime-schema.txt"
schema_dump >"${schema_file}"
[[ -s "${schema_file}" ]] || fail "runtime schema should not be empty"

python3 - <<'PY' "${schema_file}"
import pathlib
import sys

schema = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
keys = set()
labels = set()
required = {
    "AGENTIC_NETWORK",
    "AGENTIC_EGRESS_NETWORK",
    "AGENTIC_OPENCLAW_INIT_PROJECT",
    "AGENTIC_GPU_CLOCK_LOCK",
    "AGENTIC_LIMIT_OLLAMA_MEM",
    "AGENTIC_LIMIT_OPENHANDS_MEM",
    "AGENTIC_LIMIT_COMFYUI_MEM",
    "RAG_OPENSEARCH_BOOTSTRAP_TIMEOUT_SEC",
}
seen = set()
for line in schema:
    key, label, roles = line.split("|")
    if key in keys:
        raise SystemExit(f"duplicate schema key: {key}")
    if label in labels:
        raise SystemExit(f"duplicate schema label: {label}")
    if not roles:
        raise SystemExit(f"schema roles missing for {key}")
    keys.add(key)
    labels.add(label)
    for role in roles.split(","):
        seen.add((key, role))
missing = sorted(required - keys)
if missing:
    raise SystemExit("required schema keys missing: " + ",".join(missing))
for key in required:
    if (key, "persist") not in seen:
        raise SystemExit(f"required schema key must persist: {key}")
    if (key, "profile") not in seen:
        raise SystemExit(f"required schema key must be visible in agent profile: {key}")
    if (key, "load") not in seen:
        raise SystemExit(f"required schema key must be loadable from runtime.env: {key}")
PY
ok "runtime schema exports unique keys/labels and critical roles"

persist_root="${tmp_root}/persist-root"
AGENTIC_PROFILE=rootless-dev \
AGENTIC_ROOT="${persist_root}" \
AGENTIC_COMPOSE_PROJECT=agentic-schema-persist \
AGENTIC_NETWORK=agentic-schema-net \
AGENTIC_LLM_NETWORK=agentic-schema-llm \
AGENTIC_EGRESS_NETWORK=agentic-schema-egress \
AGENTIC_DOCKER_USER_SOURCE_NETWORKS=agentic-schema-net,agentic-schema-egress \
AGENTIC_OPENCLAW_INIT_PROJECT=issue-3je \
AGENTIC_GPU_CLOCK_LOCK=2100,2100 \
AGENTIC_LIMIT_OLLAMA_MEM=77g \
AGENTIC_LIMIT_OPENHANDS_MEM=5g \
AGENTIC_LIMIT_COMFYUI_MEM=66g \
RAG_OPENSEARCH_BOOTSTRAP_TIMEOUT_SEC=91 \
COMPOSE_PROFILES=trt,rag-lexical \
"${agent_bin}" llm mode remote >/dev/null

runtime_env_file="${persist_root}/deployments/runtime.env"
[[ -f "${runtime_env_file}" ]] || fail "ensure_runtime_env should create runtime.env"

while IFS='|' read -r key label; do
  grep -q "^${key}=" "${runtime_env_file}" \
    || fail "runtime.env should persist schema key ${key}"
done < <(schema_role_dump persist)
ok "runtime.env persists every schema key marked persist"

profile_output="$(
  AGENTIC_PROFILE=rootless-dev \
  AGENTIC_ROOT="${persist_root}" \
  AGENTIC_COMPOSE_PROJECT=agentic-schema-persist \
  "${agent_bin}" profile
)"
while IFS='|' read -r key label; do
  printf '%s\n' "${profile_output}" | grep -q "^${label}=" \
    || fail "agent profile should expose schema label ${label}"
done < <(schema_role_dump profile)
ok "agent profile exposes every schema label marked profile"

load_root="${tmp_root}/load-root"
mkdir -p "${load_root}/deployments"
cat >"${load_root}/deployments/runtime.env" <<'EOF'
AGENTIC_NETWORK=load-net
AGENTIC_LLM_NETWORK=load-llm
AGENTIC_EGRESS_NETWORK=load-egress
AGENTIC_DOCKER_USER_SOURCE_NETWORKS=load-net,load-egress
AGENTIC_OPENCLAW_INIT_PROJECT=load-openclaw-project
AGENTIC_GPU_CLOCK_LOCK=2300,2300
AGENTIC_LIMIT_OLLAMA_MEM=88g
AGENTIC_LIMIT_OPENHANDS_MEM=6g
AGENTIC_LIMIT_COMFYUI_MEM=77g
RAG_OPENSEARCH_BOOTSTRAP_TIMEOUT_SEC=123
COMPOSE_PROFILES=trt,rag-lexical
EOF

load_profile_output="$(
  AGENTIC_PROFILE=rootless-dev \
  AGENTIC_ROOT="${load_root}" \
  AGENTIC_COMPOSE_PROJECT=agentic-schema-load \
  "${agent_bin}" profile
)"
printf '%s\n' "${load_profile_output}" | grep -q '^network=load-net$' \
  || fail "agent profile should load AGENTIC_NETWORK from runtime.env"
printf '%s\n' "${load_profile_output}" | grep -q '^llm_network=load-llm$' \
  || fail "agent profile should load AGENTIC_LLM_NETWORK from runtime.env"
printf '%s\n' "${load_profile_output}" | grep -q '^egress_network=load-egress$' \
  || fail "agent profile should load AGENTIC_EGRESS_NETWORK from runtime.env"
printf '%s\n' "${load_profile_output}" | grep -q '^docker_user_source_networks=load-net,load-egress$' \
  || fail "agent profile should load AGENTIC_DOCKER_USER_SOURCE_NETWORKS from runtime.env"
printf '%s\n' "${load_profile_output}" | grep -q '^openclaw_init_project=load-openclaw-project$' \
  || fail "agent profile should load AGENTIC_OPENCLAW_INIT_PROJECT from runtime.env"
printf '%s\n' "${load_profile_output}" | grep -q '^gpu_clock_lock=2300,2300$' \
  || fail "agent profile should load AGENTIC_GPU_CLOCK_LOCK from runtime.env"
printf '%s\n' "${load_profile_output}" | grep -q '^limit_ollama_mem=88g$' \
  || fail "agent profile should load AGENTIC_LIMIT_OLLAMA_MEM from runtime.env"
printf '%s\n' "${load_profile_output}" | grep -q '^limit_openhands_mem=6g$' \
  || fail "agent profile should load AGENTIC_LIMIT_OPENHANDS_MEM from runtime.env"
printf '%s\n' "${load_profile_output}" | grep -q '^limit_comfyui_mem=77g$' \
  || fail "agent profile should load AGENTIC_LIMIT_COMFYUI_MEM from runtime.env"
printf '%s\n' "${load_profile_output}" | grep -q '^rag_opensearch_bootstrap_timeout_sec=123$' \
  || fail "agent profile should load RAG_OPENSEARCH_BOOTSTRAP_TIMEOUT_SEC from runtime.env"
printf '%s\n' "${load_profile_output}" | grep -q '^compose_profiles=trt,rag-lexical$' \
  || fail "agent profile should load COMPOSE_PROFILES from runtime.env"

ok "F11_runtime_env_schema_drift passed"
