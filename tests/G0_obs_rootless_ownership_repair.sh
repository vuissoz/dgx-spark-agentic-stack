#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_G_TESTS:-0}" == "1" ]]; then
  ok "G0 skipped because AGENTIC_SKIP_G_TESTS=1"
  exit 0
fi

assert_cmd docker

suffix="g0-obs-$RANDOM-$$"
export AGENTIC_PROFILE=rootless-dev
runtime_base="${AGENTIC_TEST_RUNTIME_BASE:-/tmp/agentic-tests}"
install -d -m 0750 "${runtime_base}"
export AGENTIC_ROOT="${runtime_base}/${suffix}-root"
export AGENT_RUNTIME_UID="${AGENT_RUNTIME_UID:-$(id -u)}"
export AGENT_RUNTIME_GID="${AGENT_RUNTIME_GID:-$(id -g)}"

cleanup() {
  if [[ -d "${AGENTIC_ROOT}" ]]; then
    docker run --rm -v "${runtime_base}:/cleanup" busybox:1.36.1 \
      sh -lc "rm -rf '/cleanup/${suffix}-root'" >/dev/null 2>&1 || true
    rm -rf "${AGENTIC_ROOT}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

install -d -m 0750 "${AGENTIC_ROOT}/monitoring/prometheus"
install -d -m 0750 "${AGENTIC_ROOT}/monitoring/grafana"
install -d -m 0750 "${AGENTIC_ROOT}/monitoring/loki"
install -d -m 0750 "${AGENTIC_ROOT}/monitoring/promtail/positions"
install -d -m 0750 "${AGENTIC_ROOT}/monitoring/config"

docker run --rm -v "${AGENTIC_ROOT}/monitoring:/repair/monitoring" busybox:1.36.1 sh -lc '
  set -eu
  cat > /repair/monitoring/config/promtail-config.yml <<'"'"'CFG'"'"'
scrape_configs:
  - job_name: egress-proxy
    static_configs:
      - targets:
          - localhost
        labels:
          __path__: /var/log/agentic-proxy/access.log*
CFG
  touch /repair/monitoring/prometheus/queries.active
  touch /repair/monitoring/grafana/grafana.db
  touch /repair/monitoring/loki/chunks.db
  touch /repair/monitoring/promtail/positions/positions.yaml
  chown -R 0:0 /repair/monitoring
  chmod -R 0700 /repair/monitoring
'

"${REPO_ROOT}/deployments/obs/init_runtime.sh" >/tmp/agent-g0-obs-init.out \
  || fail "obs runtime init failed to repair rootless ownership drift"
"${REPO_ROOT}/deployments/obs/init_runtime.sh" >/tmp/agent-g0-obs-init-second.out \
  || fail "obs runtime init is not idempotent after ownership repair"

first_unwritable="$(find "${AGENTIC_ROOT}/monitoring" -mindepth 0 ! -writable -print -quit 2>/dev/null || true)"
[[ -z "${first_unwritable}" ]] \
  || fail "monitoring tree still contains unwritable entries after repair: ${first_unwritable}"

owner_sample="$(stat -c '%u:%g' "${AGENTIC_ROOT}/monitoring/prometheus/queries.active")"
[[ "${owner_sample}" == "${AGENT_RUNTIME_UID}:${AGENT_RUNTIME_GID}" ]] \
  || fail "ownership repair did not set expected uid:gid on monitoring files (got ${owner_sample})"

grep -q '/tmp/agentic-proxy/access.log\*' "${AGENTIC_ROOT}/monitoring/config/promtail-config.yml" \
  || fail "promtail config migration to /tmp/agentic-proxy was not applied"
if grep -q '/var/log/agentic-proxy/access.log\*' "${AGENTIC_ROOT}/monitoring/config/promtail-config.yml"; then
  fail "legacy promtail path remains after migration"
fi

ok "G0_obs_rootless_ownership_repair passed"
