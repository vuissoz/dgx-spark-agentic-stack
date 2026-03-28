#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd docker

work_dir="${REPO_ROOT}/.runtime/test-g3-obs-retention-$$"
runtime_root="${work_dir}/runtime"
compose_render="${work_dir}/compose.obs.rendered.yml"
trap 'rm -rf "${work_dir}"' EXIT
mkdir -p "${work_dir}"

export AGENTIC_PROFILE=rootless-dev
export AGENTIC_ROOT="${runtime_root}"
export AGENTIC_COMPOSE_PROJECT="agentic-g3"
export AGENTIC_NETWORK="agentic-g3-net"
export AGENTIC_EGRESS_NETWORK="agentic-g3-egress"
export AGENTIC_OBS_RETENTION_TIME="14d"
export AGENTIC_OBS_MAX_DISK="12GB"

# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

"${REPO_ROOT}/deployments/obs/init_runtime.sh" >/tmp/agent-g3-obs-init.out 2>&1 \
  || {
    cat /tmp/agent-g3-obs-init.out >&2 || true
    fail "obs init runtime failed"
  }

policy_file="${runtime_root}/monitoring/config/retention-policy.env"
loki_config="${runtime_root}/monitoring/config/loki-config.yml"

[[ -s "${policy_file}" ]] || fail "retention policy file was not generated"
[[ -s "${loki_config}" ]] || fail "loki config was not generated"

grep -q '^AGENTIC_OBS_RETENTION_TIME=14d$' "${policy_file}" \
  || fail "retention policy file must persist AGENTIC_OBS_RETENTION_TIME=14d"
grep -q '^AGENTIC_OBS_MAX_DISK=12GB$' "${policy_file}" \
  || fail "retention policy file must persist AGENTIC_OBS_MAX_DISK=12GB"
grep -q '^AGENTIC_PROMETHEUS_DISK_BUDGET=3GB$' "${policy_file}" \
  || fail "retention policy file must derive a 3GB Prometheus budget from 12GB total"
grep -q '^AGENTIC_LOKI_DISK_BUDGET=9GB$' "${policy_file}" \
  || fail "retention policy file must derive a 9GB Loki budget from 12GB total"
grep -q '^PROMETHEUS_RETENTION_TIME=14d$' "${policy_file}" \
  || fail "retention policy file must persist PROMETHEUS_RETENTION_TIME=14d"
grep -q '^PROMETHEUS_RETENTION_SIZE=3GB$' "${policy_file}" \
  || fail "retention policy file must persist PROMETHEUS_RETENTION_SIZE=3GB"
grep -q '^LOKI_RETENTION_PERIOD=14d$' "${policy_file}" \
  || fail "retention policy file must persist LOKI_RETENTION_PERIOD=14d"
grep -q '^LOKI_MAX_QUERY_LOOKBACK=14d$' "${policy_file}" \
  || fail "retention policy file must persist LOKI_MAX_QUERY_LOOKBACK=14d"
ok "obs init writes a retention policy audit file"

grep -Eq '^[[:space:]]*retention_period:[[:space:]]*14d$' "${loki_config}" \
  || fail "loki config must render retention_period=14d"
grep -Eq '^[[:space:]]*max_query_lookback:[[:space:]]*14d$' "${loki_config}" \
  || fail "loki config must render max_query_lookback=14d"
grep -Eq '^[[:space:]]*retention_enabled:[[:space:]]*true$' "${loki_config}" \
  || fail "loki config must enable retention compaction"
grep -Eq '^[[:space:]]*delete_request_store:[[:space:]]*filesystem$' "${loki_config}" \
  || fail "loki config must use delete_request_store=filesystem"
ok "loki runtime config is rendered with managed retention values"

docker compose -f "${REPO_ROOT}/compose/compose.obs.yml" config >"${compose_render}" \
  || fail "docker compose config failed for compose.obs.yml"

grep -q -- '--storage.tsdb.retention.time=14d' "${compose_render}" \
  || fail "prometheus compose config must include retention.time=14d"
grep -q -- '--storage.tsdb.retention.size=3GB' "${compose_render}" \
  || fail "prometheus compose config must include retention.size=3GB"
grep -q 'LOKI_RETENTION_PERIOD: 14d' "${compose_render}" \
  || fail "loki compose config must expose LOKI_RETENTION_PERIOD=14d"
grep -q 'LOKI_MAX_QUERY_LOOKBACK: 14d' "${compose_render}" \
  || fail "loki compose config must expose LOKI_MAX_QUERY_LOOKBACK=14d"
ok "compose renders effective retention settings for Prometheus and Loki"

ok "G3_obs_retention_policy passed"
