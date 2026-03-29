#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_G_TESTS:-0}" == "1" ]]; then
  ok "G1 skipped because AGENTIC_SKIP_G_TESTS=1"
  exit 0
fi

assert_cmd docker
assert_cmd curl
assert_cmd python3
assert_cmd ss

prom_port="${PROMETHEUS_HOST_PORT:-19090}"
grafana_port="${GRAFANA_HOST_PORT:-13000}"
loki_port="${LOKI_HOST_PORT:-13100}"

prom_cid="$(require_service_container prometheus)" || exit 1
grafana_cid="$(require_service_container grafana)" || exit 1
loki_cid="$(require_service_container loki)" || exit 1
promtail_cid="$(require_service_container promtail)" || exit 1
node_exporter_cid="$(require_service_container node-exporter)" || exit 1
cadvisor_cid="$(require_service_container cadvisor)" || exit 1

wait_for_container_ready "${prom_cid}" 120 || fail "prometheus is not ready"
wait_for_container_ready "${grafana_cid}" 120 || fail "grafana is not ready"
wait_for_container_ready "${loki_cid}" 120 || fail "loki is not ready"
wait_for_container_ready "${promtail_cid}" 120 || fail "promtail is not ready"
wait_for_container_ready "${node_exporter_cid}" 120 || fail "node-exporter is not ready"
wait_for_container_ready "${cadvisor_cid}" 120 || fail "cadvisor is not ready"

curl -fsS --max-time 10 "http://127.0.0.1:${grafana_port}/login" >/dev/null \
  || fail "grafana login endpoint is unavailable on 127.0.0.1:${grafana_port}"
ok "grafana login endpoint is reachable via loopback"

assert_no_public_bind "${grafana_port}" "${prom_port}" "${loki_port}" \
  || fail "obs exposed a host port on non-loopback interface"
ok "observability host ports are loopback-only"

targets_payload="$(curl -fsS --max-time 12 "http://127.0.0.1:${prom_port}/api/v1/targets")"
python3 - <<'PY' "${targets_payload}"
import json
import sys

payload = json.loads(sys.argv[1])
if payload.get("status") != "success":
    raise SystemExit("prometheus targets API did not return success")

targets = payload.get("data", {}).get("activeTargets", [])
if not targets:
    raise SystemExit("prometheus has no active targets")

prometheus_up = False
for target in targets:
    labels = target.get("labels", {})
    if labels.get("job") == "prometheus" and target.get("health") == "up":
        prometheus_up = True
        break

if not prometheus_up:
    raise SystemExit("prometheus self-target is not UP")
PY
ok "prometheus targets include a healthy prometheus job"

openclaw_gateway_cid="$(require_service_container openclaw-gateway 2>/dev/null || true)"
if [[ -n "${openclaw_gateway_cid}" ]]; then
  python3 - <<'PY' "${targets_payload}"
import json
import sys

payload = json.loads(sys.argv[1])
targets = payload.get("data", {}).get("activeTargets", [])
for target in targets:
    if not isinstance(target, dict):
        continue
    labels = target.get("labels") or {}
    discovered = target.get("discoveredLabels") or {}
    if labels.get("job") != "openclaw-tcp-forwarders":
        continue
    scrape_url = str(target.get("scrapeUrl", ""))
    if target.get("health") != "up":
        raise SystemExit("openclaw-tcp-forwarders target is not UP")
    if "openclaw-gateway:9114/metrics" not in scrape_url and discovered.get("__address__") != "openclaw-gateway:9114":
        raise SystemExit("openclaw-tcp-forwarders target address drifted")
    raise SystemExit(0)
raise SystemExit("prometheus is missing the openclaw-tcp-forwarders target")
PY
  ok "prometheus scrapes the openclaw tcp forwarder target"

  forwarder_metric_seen=0
  for _ in $(seq 1 15); do
    names_payload="$(curl -fsS --max-time 12 "http://127.0.0.1:${prom_port}/api/v1/label/__name__/values")"
    if python3 - <<'PY' "${names_payload}"
import json
import sys

payload = json.loads(sys.argv[1])
if payload.get("status") != "success":
    raise SystemExit(1)

required = {
    "agentic_tcp_forwarder_connections_total",
    "agentic_tcp_forwarder_active_connections",
    "agentic_tcp_forwarder_bytes_total",
}
names = {name for name in payload.get("data", []) if isinstance(name, str)}
if required.issubset(names):
    raise SystemExit(0)
raise SystemExit(1)
PY
    then
      forwarder_metric_seen=1
      break
    fi
    sleep 2
  done

  [[ "${forwarder_metric_seen}" -eq 1 ]] || fail "openclaw forwarder metrics are missing from prometheus scrape data"
  ok "openclaw forwarder metrics are present in prometheus"
fi

ts_ns="$(python3 - <<'PY'
import time
print(int(time.time() * 1_000_000_000))
PY
)"
line="g1-loki-smoke-${ts_ns}"
payload="$(python3 - <<'PY' "${ts_ns}" "${line}"
import json
import sys

ts = sys.argv[1]
line = sys.argv[2]
doc = {
    "streams": [
        {
            "stream": {"job": "g1-smoke"},
            "values": [[ts, line]],
        }
    ]
}
print(json.dumps(doc))
PY
)"

curl -fsS --max-time 10 -H "Content-Type: application/json" \
  -X POST "http://127.0.0.1:${loki_port}/loki/api/v1/push" \
  --data-raw "${payload}" >/dev/null \
  || fail "unable to push smoke log line to loki"

sleep 2
query_payload="$(curl -fsS --max-time 12 --get \
  --data-urlencode 'query={job="g1-smoke"}' \
  --data-urlencode 'limit=5' \
  "http://127.0.0.1:${loki_port}/loki/api/v1/query_range")"
python3 - <<'PY' "${query_payload}" "${line}"
import json
import sys

payload = json.loads(sys.argv[1])
needle = sys.argv[2]
if payload.get("status") != "success":
    raise SystemExit("loki query API did not return success")

for stream in payload.get("data", {}).get("result", []):
    for pair in stream.get("values", []):
        if len(pair) == 2 and needle in pair[1]:
            raise SystemExit(0)

raise SystemExit("loki query did not return the pushed smoke log line")
PY
ok "loki receives and serves log entries"

if [[ "${AGENTIC_SKIP_DCGM_CHECK:-0}" == "1" ]]; then
  warn "skip dcgm metrics check because AGENTIC_SKIP_DCGM_CHECK=1"
else
  dcgm_cid="$(require_service_container dcgm-exporter)" || exit 1
  wait_for_container_ready "${dcgm_cid}" 120 || fail "dcgm-exporter is not ready"

  dcgm_seen=0
  for _ in $(seq 1 15); do
    names_payload="$(curl -fsS --max-time 12 "http://127.0.0.1:${prom_port}/api/v1/label/__name__/values")"
    if python3 - <<'PY' "${names_payload}"
import json
import sys

payload = json.loads(sys.argv[1])
if payload.get("status") != "success":
    raise SystemExit(1)

for name in payload.get("data", []):
    if isinstance(name, str) and name.lower().startswith("dcgm_"):
        raise SystemExit(0)
raise SystemExit(1)
PY
    then
      dcgm_seen=1
      break
    fi
    sleep 2
  done

  [[ "${dcgm_seen}" -eq 1 ]] || fail "dcgm metrics are missing from prometheus scrape data"
  ok "dcgm metrics are present"
fi

ok "G1_obs_up passed"
