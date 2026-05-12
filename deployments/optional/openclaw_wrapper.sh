#!/usr/bin/env bash
set -euo pipefail

export_secret_env() {
  local env_name="$1"
  local file_path="$2"
  local value=""
  [[ -r "${file_path}" ]] || return 0
  value="$(tr -d '\r\n' <"${file_path}")"
  [[ -n "${value}" ]] || return 0
  export "${env_name}=${value}"
}

help_requested() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      -h|--help|help)
        return 0
        ;;
    esac
  done
  return 1
}

guard_stack_managed_gateway_run() {
  if [[ "${1:-}" != "gateway" || "${2:-}" != "run" ]]; then
    return 0
  fi

  shift 2
  if help_requested "$@"; then
    return 0
  fi

  if [[ "${OPENCLAW_ALLOW_UPSTREAM_GATEWAY_RUN:-0}" == "1" ]]; then
    return 0
  fi

  cat >&2 <<'EOF'
ERROR: stack-managed OpenClaw blocks manual 'openclaw gateway run' in operator shells.
Use './agent up core' for the managed gateway service on 127.0.0.1:18789.
If you intentionally need the upstream gateway for debugging, rerun with:
  OPENCLAW_ALLOW_UPSTREAM_GATEWAY_RUN=1 openclaw gateway run ...
EOF
  exit 64
}

real_bin="$(cat /etc/agentic/openclaw-real-path 2>/dev/null || true)"
[[ -n "${real_bin}" && -x "${real_bin}" ]] || {
  echo "ERROR: upstream openclaw binary is unavailable" >&2
  exit 1
}

layer_helper="${OPENCLAW_LAYER_HELPER:-/app/openclaw_config_layers.py}"
immutable_file="${OPENCLAW_IMMUTABLE_CONFIG_FILE:-/config/immutable/openclaw.stack-config.v1.json}"
bridge_file="${OPENCLAW_PROVIDER_BRIDGE_FILE:-/config/bridge/openclaw.provider-bridge.json}"
overlay_file="${OPENCLAW_OPERATOR_OVERLAY_FILE:-/overlay/openclaw.operator-overlay.json}"
state_file="${OPENCLAW_STATE_CONFIG_FILE:-/state/cli/openclaw-home/openclaw.state.json}"
effective_file="${OPENCLAW_CONFIG_PATH:-/tmp/openclaw.effective.json}"
gateway_token_file="${OPENCLAW_CONFIG_GATEWAY_TOKEN_FILE:-${OPENCLAW_GATEWAY_TOKEN_FILE:-/run/secrets/openclaw.token}}"
capture_on_exit="${OPENCLAW_CAPTURE_LAYER_STATE_ON_EXIT:-1}"

export_secret_env TELEGRAM_BOT_TOKEN "${OPENCLAW_TELEGRAM_BOT_TOKEN_FILE:-/run/secrets/telegram.bot_token}"
export_secret_env DISCORD_BOT_TOKEN "${OPENCLAW_DISCORD_BOT_TOKEN_FILE:-/run/secrets/discord.bot_token}"
export_secret_env SLACK_BOT_TOKEN "${OPENCLAW_SLACK_BOT_TOKEN_FILE:-/run/secrets/slack.bot_token}"
export_secret_env SLACK_APP_TOKEN "${OPENCLAW_SLACK_APP_TOKEN_FILE:-/run/secrets/slack.app_token}"
export_secret_env SLACK_SIGNING_SECRET "${OPENCLAW_SLACK_SIGNING_SECRET_FILE:-/run/secrets/slack.signing_secret}"

guard_stack_managed_gateway_run "$@"

python3 "${layer_helper}" materialize \
  --immutable-file "${immutable_file}" \
  --bridge-file "${bridge_file}" \
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
    --bridge-file "${bridge_file}" \
    --overlay-file "${overlay_file}" \
    --state-file "${state_file}" \
    --effective-file "${effective_file}" \
    --gateway-token-file "${gateway_token_file}"
fi

exit "${rc}"
