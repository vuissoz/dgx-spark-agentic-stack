#!/usr/bin/env bash
set -euo pipefail

real_bin=""
if [[ -f /etc/agentic/hermes-real-path ]]; then
  real_bin="$(cat /etc/agentic/hermes-real-path 2>/dev/null || true)"
fi

hermes_home_default="${AGENT_HERMES_HOME:-${AGENT_HOME:-${AGENT_STATE_DIR:-/state}/home}/.hermes}"
export HERMES_HOME="${HERMES_HOME:-${hermes_home_default}}"

if [[ -n "${real_bin}" && -x "${real_bin}" ]]; then
  resolved_real="$(readlink -f "${real_bin}" 2>/dev/null || printf '%s\n' "${real_bin}")"
  resolved_self="$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")"
  if [[ "${resolved_real}" != "${resolved_self}" ]]; then
    exec "${real_bin}" "$@"
  fi
fi

if [[ "${1:-}" == "--version" || "${1:-}" == "version" ]]; then
  printf 'hermes-shim 0.1.0\n'
  exit 0
fi

if [[ "${1:-}" == "config" && "${2:-}" == "path" ]]; then
  printf '%s/config.yaml\n' "${HERMES_HOME}"
  exit 0
fi

cat <<EOF
hermes wrapper fallback: official Hermes CLI is unavailable in this image.
Rebuild with outbound access, or set AGENT_CLI_INSTALL_MODE=required to fail image builds on missing CLI installs.
EOF
exit 127
