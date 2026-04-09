#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

agent_bin="${REPO_ROOT}/agent"
[[ -x "${agent_bin}" ]] || fail "agent binary is missing or not executable"

work_dir="${REPO_ROOT}/.runtime/test-tunnel-generator-$$"
list_json="${work_dir}/list.json"
linux_script="${work_dir}/agentic-tunnel.sh"
windows_script="${work_dir}/agentic-tunnel.ps1"
iphone_config="${work_dir}/agentic-tunnel-iphone.conf"
check_ok_json="${work_dir}/check-ok.json"
check_fail_out="${work_dir}/check-fail.out"
server_log="${work_dir}/http-server.log"

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
  fi
  rm -rf "${work_dir}"
}
trap cleanup EXIT
mkdir -p "${work_dir}"

export AGENTIC_PROFILE="rootless-dev"
export AGENTIC_ROOT="${work_dir}/runtime-root"
export OPENWEBUI_HOST_PORT="38080"
export GRAFANA_HOST_PORT="39000"
export GIT_FORGE_SSH_HOST_PORT="32222"

"${agent_bin}" tunnel list --all --json >"${list_json}"
python3 - "${list_json}" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
lookup = {entry["id"]: entry for entry in payload}
assert lookup["openwebui"]["port"] == 38080
assert lookup["grafana"]["port"] == 39000
assert lookup["forgejo-ssh"]["port"] == 32222
PY

"${agent_bin}" tunnel generate linux \
  --surface openwebui \
  --surface grafana \
  --ssh-target dev@dgx.tail.example \
  --output "${linux_script}"
[[ -x "${linux_script}" ]] || fail "linux tunnel script must be executable"
bash -n "${linux_script}" || fail "linux tunnel script must parse as bash"
grep -Fq -- "-L 38080:127.0.0.1:38080" "${linux_script}" \
  || fail "linux tunnel script must contain forwarded OpenWebUI port"
grep -Fq -- "SSH_TARGET_DEFAULT='dev@dgx.tail.example'" "${linux_script}" \
  || fail "linux tunnel script must bake the requested SSH target"

"${agent_bin}" tunnel generate windows \
  --surface openwebui \
  --surface forgejo-ssh \
  --ssh-target dev@dgx.tail.example \
  --output "${windows_script}"
grep -Fq 'ssh.exe "-N" "-T"' "${windows_script}" \
  || fail "windows artifact must invoke ssh.exe"
grep -Fq '"32222:127.0.0.1:32222"' "${windows_script}" \
  || fail "windows artifact must contain the Forgejo SSH forward"

"${agent_bin}" tunnel generate iphone \
  --surface openwebui \
  --surface grafana \
  --ssh-target dev@dgx.tail.example \
  --name dgx-spark-phone \
  --output "${iphone_config}"
grep -Fq "Host dgx-spark-phone" "${iphone_config}" \
  || fail "iphone config must contain the requested host alias"
grep -Fq "  HostName dgx.tail.example" "${iphone_config}" \
  || fail "iphone config must split the SSH host correctly"
grep -Fq "  User dev" "${iphone_config}" \
  || fail "iphone config must split the SSH user correctly"
grep -Fq "  LocalForward 39000 127.0.0.1:39000" "${iphone_config}" \
  || fail "iphone config must contain local forwards"

python3 -m http.server "${OPENWEBUI_HOST_PORT}" --bind 127.0.0.1 >"${server_log}" 2>&1 &
server_pid=$!
sleep 1

"${agent_bin}" tunnel check --surface openwebui --json >"${check_ok_json}" \
  || fail "tunnel check should succeed when the requested surface is reachable"
python3 - "${check_ok_json}" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload == [
    {
        "id": "openwebui",
        "port": 38080,
        "status": "ok",
        "client_urls": ["http://127.0.0.1:38080/"],
    }
]
PY

if OPENWEBUI_HOST_PORT=38081 "${agent_bin}" tunnel check --surface openwebui >"${check_fail_out}" 2>&1; then
  cat "${check_fail_out}" >&2 || true
  fail "tunnel check must fail when the selected surface is not reachable"
fi
grep -Fq "FAIL: openwebui is not reachable on 127.0.0.1:38081" "${check_fail_out}" \
  || fail "tunnel check failure must be explicit"

ok "F15_tunnel_generator passed"
