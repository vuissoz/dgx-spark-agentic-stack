#!/usr/bin/env bash
set -euo pipefail

real_bin="$(cat /etc/agentic/openclaw-real-path 2>/dev/null || true)"
[[ -n "${real_bin}" && -x "${real_bin}" ]] || {
  echo "ERROR: upstream openclaw binary is unavailable" >&2
  exit 1
}

layer_helper="${OPENCLAW_LAYER_HELPER:-/app/openclaw_config_layers.py}"
immutable_file="${OPENCLAW_IMMUTABLE_CONFIG_FILE:-/config/immutable/openclaw.stack-config.v1.json}"
overlay_file="${OPENCLAW_OPERATOR_OVERLAY_FILE:-/overlay/openclaw.operator-overlay.json}"
state_file="${OPENCLAW_STATE_CONFIG_FILE:-/state/cli/openclaw-home/openclaw.state.json}"
effective_file="${OPENCLAW_CONFIG_PATH:-/tmp/openclaw.effective.json}"
gateway_token_file="${OPENCLAW_CONFIG_GATEWAY_TOKEN_FILE:-${OPENCLAW_GATEWAY_TOKEN_FILE:-/run/secrets/openclaw.token}}"
capture_on_exit="${OPENCLAW_CAPTURE_LAYER_STATE_ON_EXIT:-1}"

python3 "${layer_helper}" materialize \
  --immutable-file "${immutable_file}" \
  --overlay-file "${overlay_file}" \
  --state-file "${state_file}" \
  --effective-file "${effective_file}" \
  --gateway-token-file "${gateway_token_file}"

set +e
"${real_bin}" "$@"
rc=$?
set -e

if [[ "${capture_on_exit}" == "1" ]]; then
  python3 "${layer_helper}" capture \
    --immutable-file "${immutable_file}" \
    --overlay-file "${overlay_file}" \
    --state-file "${state_file}" \
    --effective-file "${effective_file}" \
    --gateway-token-file "${gateway_token_file}"
fi

exit "${rc}"
