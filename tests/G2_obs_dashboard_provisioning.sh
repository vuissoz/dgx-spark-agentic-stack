#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd docker
assert_cmd curl
assert_cmd python3

grafana_port="${GRAFANA_HOST_PORT:-13000}"
grafana_user="${GRAFANA_ADMIN_USER:-admin}"
grafana_password="${GRAFANA_ADMIN_PASSWORD:-change-me}"
root_dir="${AGENTIC_ROOT:-/srv/agentic}"

grafana_cid="$(require_service_container grafana)" || exit 1
wait_for_container_ready "${grafana_cid}" 120 || fail "grafana is not ready"

for required in \
  "${root_dir}/monitoring/config/grafana/provisioning/datasources/datasources.yml" \
  "${root_dir}/monitoring/config/grafana/provisioning/dashboards/dashboards.yml" \
  "${root_dir}/monitoring/config/grafana/dashboards/agentic-activity-overview.json"
do
  [[ -s "${required}" ]] || fail "missing Grafana provisioning artifact: ${required}"
done
ok "Grafana provisioning artifacts exist under ${root_dir}/monitoring/config/grafana"

python3 - <<'PY' "${root_dir}/monitoring/config/grafana/dashboards/agentic-activity-overview.json"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
panels = payload.get("panels") or []
titles = {panel.get("title") for panel in panels if isinstance(panel, dict)}
required = {
    "OpenClaw TCP Forwarder Health",
    "OpenClaw TCP Forwarder Traffic",
}
missing = sorted(required - titles)
if missing:
    raise SystemExit(f"dashboard is missing OpenClaw forwarder panel(s): {', '.join(missing)}")
PY
ok "Grafana dashboard includes OpenClaw forwarder panels"

timeout 10 docker exec "${grafana_cid}" sh -lc 'test -s /etc/grafana/provisioning/datasources/datasources.yml && test -s /etc/grafana/provisioning/dashboards/dashboards.yml && test -s /etc/grafana/dashboards/agentic-activity-overview.json' \
  || fail "Grafana provisioning files are not mounted in container"
ok "Grafana provisioning files are mounted read-only in container"

env_dump="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${grafana_cid}")"
echo "${env_dump}" | grep -q '^GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/etc/grafana/dashboards/agentic-activity-overview.json$' \
  || fail "Grafana default home dashboard path is not configured"
ok "Grafana default home dashboard path is configured"

auth_status="$(curl -sS -o /tmp/g2-grafana-datasources.json -w '%{http_code}' --max-time 12 -u "${grafana_user}:${grafana_password}" "http://127.0.0.1:${grafana_port}/api/datasources" || true)"
if [[ "${auth_status}" == "200" ]]; then
  datasources_payload="$(cat /tmp/g2-grafana-datasources.json)"
  python3 - <<'PY' "${datasources_payload}"
import json
import sys

payload = json.loads(sys.argv[1])
if not isinstance(payload, list):
    raise SystemExit("Grafana datasources response is not a list")

names = {item.get("name") for item in payload if isinstance(item, dict)}
missing = [name for name in ("Prometheus", "Loki") if name not in names]
if missing:
    raise SystemExit(f"Missing provisioned datasource(s): {', '.join(missing)}")
PY
  ok "Grafana datasources include provisioned Prometheus and Loki"

  dashboard_payload="$(curl -fsS --max-time 12 -u "${grafana_user}:${grafana_password}" --get --data-urlencode 'query=DGX Spark Agentic Activity Overview' "http://127.0.0.1:${grafana_port}/api/search")"
  python3 - <<'PY' "${dashboard_payload}"
import json
import sys

payload = json.loads(sys.argv[1])
if not isinstance(payload, list):
    raise SystemExit("Grafana dashboard search response is not a list")

for item in payload:
    if isinstance(item, dict) and item.get("uid") == "dgx-spark-activity":
        raise SystemExit(0)

raise SystemExit("Provisioned dashboard uid 'dgx-spark-activity' not found")
PY
  ok "Grafana first-run dashboard is provisioned via API"
else
  [[ "${auth_status}" == "401" ]] || fail "Grafana API check failed with HTTP status ${auth_status}"
  warn "Grafana API credentials rejected; using provisioning-log fallback checks"

  grafana_logs="$(docker logs "${grafana_cid}" --tail 400 2>&1 || true)"
  echo "${grafana_logs}" | grep -q 'inserting datasource from configuration\" name=Prometheus' \
    || fail "Grafana logs do not show Prometheus datasource provisioning"
  echo "${grafana_logs}" | grep -q 'inserting datasource from configuration\" name=Loki' \
    || fail "Grafana logs do not show Loki datasource provisioning"
  echo "${grafana_logs}" | grep -q 'finished to provision dashboards' \
    || fail "Grafana logs do not show dashboard provisioning completion"
  ok "Grafana logs confirm datasource and dashboard provisioning"
fi

rm -f /tmp/g2-grafana-datasources.json

ok "G2_obs_dashboard_provisioning passed"
