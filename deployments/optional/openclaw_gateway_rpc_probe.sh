#!/usr/bin/env bash
set -euo pipefail

real_bin="$(cat /etc/agentic/openclaw-real-path 2>/dev/null || true)"
[[ -n "${real_bin}" && -x "${real_bin}" ]] || {
  echo "ERROR: upstream openclaw binary is unavailable" >&2
  exit 1
}

token_file="${OPENCLAW_GATEWAY_TOKEN_FILE:-/run/secrets/openclaw.token}"
gateway_token_file="${OPENCLAW_CONFIG_GATEWAY_TOKEN_FILE:-${token_file}}"
gateway_port="${OPENCLAW_GATEWAY_PORT:-18789}"
layer_helper="${OPENCLAW_LAYER_HELPER:-/app/openclaw_config_layers.py}"
immutable_file="${OPENCLAW_IMMUTABLE_CONFIG_FILE:-/config/immutable/openclaw.stack-config.v1.json}"
bridge_file="${OPENCLAW_PROVIDER_BRIDGE_FILE:-/config/bridge/openclaw.provider-bridge.json}"
overlay_file="${OPENCLAW_OPERATOR_OVERLAY_FILE:-/overlay/openclaw.operator-overlay.json}"
state_file="${OPENCLAW_STATE_CONFIG_FILE:-/state/cli/openclaw-home/openclaw.state.json}"
probe_effective_file="$(mktemp /tmp/openclaw-gateway-probe.XXXXXX.json)"

cleanup() {
  rm -f "${probe_effective_file}"
}
trap cleanup EXIT INT TERM

[[ -r "${token_file}" ]] || exit 1
token="$(tr -d '\n' <"${token_file}")"
[[ -n "${token}" ]] || exit 1

python3 "${layer_helper}" materialize \
  --immutable-file "${immutable_file}" \
  --bridge-file "${bridge_file}" \
  --overlay-file "${overlay_file}" \
  --state-file "${state_file}" \
  --effective-file "${probe_effective_file}" \
  --gateway-token-file "${gateway_token_file}" >/dev/null

OPENCLAW_CONFIG_PATH="${probe_effective_file}" \
OPENCLAW_CAPTURE_LAYER_STATE_ON_EXIT=0 \
  "${real_bin}" gateway status --json --require-rpc --url "ws://127.0.0.1:${gateway_port}" --token "${token}"
