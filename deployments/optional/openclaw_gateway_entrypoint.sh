#!/usr/bin/env bash
set -euo pipefail

token_file="${OPENCLAW_GATEWAY_TOKEN_FILE:-/run/secrets/openclaw.token}"
gateway_port="${OPENCLAW_GATEWAY_PORT:-18789}"
proxy_port="${OPENCLAW_GATEWAY_PROXY_PORT:-8114}"
auth_mode="${OPENCLAW_GATEWAY_AUTH_MODE:-token}"
bind_mode="${OPENCLAW_GATEWAY_BIND_MODE:-loopback}"
tailscale_mode="${OPENCLAW_GATEWAY_TAILSCALE_MODE:-off}"

if [[ ! -r "${token_file}" ]]; then
  echo "ERROR: OpenClaw gateway token file is not readable: ${token_file}" >&2
  exit 1
fi

gateway_token="$(tr -d '\n' <"${token_file}")"
if [[ -z "${gateway_token}" ]]; then
  echo "ERROR: OpenClaw gateway token file is empty: ${token_file}" >&2
  exit 1
fi

export OPENCLAW_GATEWAY_TOKEN="${gateway_token}"
export OPENCLAW_CAPTURE_LAYER_STATE_ON_EXIT=0
gateway_pid=""
proxy_pid=""

cleanup() {
  if [[ -n "${proxy_pid}" ]]; then
    kill "${proxy_pid}" >/dev/null 2>&1 || true
    wait "${proxy_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${gateway_pid}" ]]; then
    kill "${gateway_pid}" >/dev/null 2>&1 || true
    wait "${gateway_pid}" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM

openclaw gateway run \
  --allow-unconfigured \
  --auth "${auth_mode}" \
  --bind "${bind_mode}" \
  --tailscale "${tailscale_mode}" \
  --port "${gateway_port}" &
gateway_pid="$!"

python3 /app/tcp_forward.py \
  --listen-host 0.0.0.0 \
  --listen-port "${proxy_port}" \
  --target-host 127.0.0.1 \
  --target-port "${gateway_port}" &
proxy_pid="$!"

while true; do
  if ! kill -0 "${gateway_pid}" >/dev/null 2>&1; then
    wait "${gateway_pid}"
    exit $?
  fi
  if ! kill -0 "${proxy_pid}" >/dev/null 2>&1; then
    wait "${proxy_pid}"
    exit $?
  fi
  sleep 1
done
