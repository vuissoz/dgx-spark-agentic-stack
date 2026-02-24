#!/usr/bin/env bash
set -euo pipefail

tool="$(basename "$0")"
path_file="/etc/agentic/${tool}-real-path"
real_bin=""

if [[ -f "${path_file}" ]]; then
  real_bin="$(cat "${path_file}" 2>/dev/null || true)"
fi

if [[ -n "${real_bin}" && -x "${real_bin}" ]]; then
  resolved_real="$(readlink -f "${real_bin}" 2>/dev/null || printf '%s\n' "${real_bin}")"
  resolved_self="$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")"
  if [[ "${resolved_real}" != "${resolved_self}" ]]; then
    exec "${real_bin}" "$@"
  fi
fi

if [[ "${1:-}" == "--version" || "${1:-}" == "version" ]]; then
  printf '%s-shim 0.1.0\n' "${tool}"
  exit 0
fi

cat <<EOF
${tool} wrapper fallback: official CLI is unavailable in this image.
Rebuild with outbound access, or set AGENT_CLI_INSTALL_MODE=required to fail image builds on missing CLI installs.
EOF
exit 127
