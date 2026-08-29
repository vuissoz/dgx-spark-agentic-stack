#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

state_root="$(mktemp -d)"
trap 'rm -rf "${state_root}"' EXIT
mkdir -p "${state_root}/devices" "${state_root}/identity"

python3 - "${state_root}" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
device_id = "device-test"
token = "test-token"
(root / "devices" / "pending.json").write_text(json.dumps({
    "request-test": {
        "requestId": "request-test",
        "deviceId": device_id,
        "publicKey": "public-test",
        "platform": "linux",
        "clientId": "cli",
        "clientMode": "cli",
        "role": "operator",
        "roles": ["operator"],
        "scopes": ["operator.write", "operator.pairing"],
    }
}), encoding="utf-8")
(root / "devices" / "paired.json").write_text(json.dumps({
    device_id: {
        "deviceId": device_id,
        "publicKey": "public-test",
        "clientId": "cli",
        "role": "operator",
        "roles": ["operator"],
        "scopes": ["operator.read"],
        "approvedScopes": ["operator.read"],
        "tokens": {"operator": {"token": token, "role": "operator", "scopes": ["operator.read"]}},
    }
}), encoding="utf-8")
(root / "identity" / "device-auth.json").write_text(json.dumps({
    "version": 1,
    "deviceId": device_id,
    "tokens": {"operator": {"token": token, "role": "operator", "scopes": ["operator.read"]}},
}), encoding="utf-8")
PY

python3 "${REPO_ROOT}/deployments/optional/openclaw_terminal_pairing.py" \
  --state-dir "${state_root}" \
  --request-id request-test >/tmp/agent-k20-authorize.json

python3 - "${state_root}" /tmp/agent-k20-authorize.json <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
result = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
paired = json.loads((root / "devices" / "paired.json").read_text(encoding="utf-8"))["device-test"]
auth = json.loads((root / "identity" / "device-auth.json").read_text(encoding="utf-8"))
pending = json.loads((root / "devices" / "pending.json").read_text(encoding="utf-8"))
expected = {"operator.read", "operator.write", "operator.pairing"}
if result.get("authorized") is not True or pending:
    raise SystemExit("scope upgrade was not completed")
if set(paired["approvedScopes"]) != expected:
    raise SystemExit("paired approved scopes were not reconciled")
if set(paired["tokens"]["operator"]["scopes"]) != expected:
    raise SystemExit("paired token scopes were not reconciled")
if set(auth["tokens"]["operator"]["scopes"]) != expected:
    raise SystemExit("local CLI token scopes were not reconciled")
PY

ok "K20_openclaw_terminal_pairing passed"
