#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd python3

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

immutable_file="${tmp_root}/immutable.json"
bridge_file="${tmp_root}/bridge.json"
overlay_file="${tmp_root}/overlay.json"
state_file="${tmp_root}/state.json"
effective_file="${tmp_root}/effective.json"
gateway_token_file="${tmp_root}/gateway.token"
helper="${REPO_ROOT}/deployments/optional/openclaw_config_layers.py"

cat >"${immutable_file}" <<'JSON'
{
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "auth": {
      "mode": "token",
      "token": "__OPENCLAW_GATEWAY_TOKEN__"
    }
  }
}
JSON

cat >"${bridge_file}" <<'JSON'
{
  "models": {
    "mode": "merge"
  }
}
JSON

cat >"${overlay_file}" <<'JSON'
{
  "agents": {
    "defaults": {
      "workspace": "/workspace/openclaw-default"
    }
  }
}
JSON

cat >"${state_file}" <<'JSON'
{
  "plugins": {
    "allow": [
      "openclaw-chat-status"
    ],
    "entries": {
      "openclaw-chat-status": {
        "enabled": true
      }
    }
  },
  "meta": {
    "lastTouchedVersion": "test"
  }
}
JSON

printf 'k13-test-token\n' > "${gateway_token_file}"

python3 "${helper}" materialize \
  --immutable-file "${immutable_file}" \
  --bridge-file "${bridge_file}" \
  --overlay-file "${overlay_file}" \
  --state-file "${state_file}" \
  --effective-file "${effective_file}" \
  --gateway-token-file "${gateway_token_file}" \
  || fail "materialize must succeed"

python3 "${helper}" capture \
  --immutable-file "${immutable_file}" \
  --bridge-file "${bridge_file}" \
  --overlay-file "${overlay_file}" \
  --state-file "${state_file}" \
  --effective-file "${effective_file}" \
  --gateway-token-file "${gateway_token_file}" \
  || fail "capture must succeed"

python3 - "${state_file}" <<'PY' || fail "managed plugin provenance must survive capture"
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
plugins = state.get("plugins") or {}
allow = plugins.get("allow") or []
entries = plugins.get("entries") or {}
installs = plugins.get("installs") or {}
entry = entries.get("openclaw-chat-status") or {}
install = installs.get("openclaw-chat-status") or {}
plugin_dir = "/state/cli/openclaw-home/.openclaw/extensions/openclaw-chat-status"

assert "openclaw-chat-status" in allow, state
assert entry.get("enabled") is True, state
assert install.get("source") == "path", state
assert install.get("sourcePath") == plugin_dir, state
assert install.get("installPath") == plugin_dir, state
assert state.get("meta", {}).get("lastTouchedVersion") == "test", state
PY

ok "openclaw managed plugin provenance survives materialize/capture reconciliation"
ok "K13_openclaw_managed_plugin_provenance_capture passed"
