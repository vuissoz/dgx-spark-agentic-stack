#!/usr/bin/env bash
set -euo pipefail

real_bin=""
if [[ -f /etc/agentic/vibe-real-path ]]; then
  real_bin="$(cat /etc/agentic/vibe-real-path 2>/dev/null || true)"
fi

if [[ -n "${real_bin}" && -x "${real_bin}" ]]; then
  exec "${real_bin}" "$@"
fi

state_dir="${VIBE_STATE_DIR:-${AGENT_STATE_DIR:-/state}/vibe}"
marker="${state_dir}/.setup-complete"
config_file="${state_dir}/config.env"

mkdir -p "${state_dir}"

if [[ "${1:-}" == "--setup" ]]; then
  cat >"${config_file}" <<EOF
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
vibe_mode=shim
EOF
  touch "${marker}"
  printf 'vibe shim setup completed (%s)\n' "${state_dir}"
  exit 0
fi

if [[ "${1:-}" == "--version" || "${1:-}" == "version" ]]; then
  printf 'vibe-shim 0.1.0\n'
  exit 0
fi

cat <<EOF
vibe wrapper fallback: official Vibe CLI is unavailable in this image.
Run 'vibe --setup' to initialize persistent shim state under ${state_dir}.
EOF
