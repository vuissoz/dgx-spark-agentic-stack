#!/usr/bin/env bash
set -euo pipefail

tool="$(basename "$0")"
path_file="${AGENTIC_WRAPPER_PATH_FILE:-/etc/agentic/${tool}-real-path}"
real_bin=""

if [[ -f "${path_file}" ]]; then
  real_bin="$(cat "${path_file}" 2>/dev/null || true)"
fi

if [[ -n "${real_bin}" && -x "${real_bin}" ]]; then
  resolved_real="$(readlink -f "${real_bin}" 2>/dev/null || printf '%s\n' "${real_bin}")"
  resolved_self="$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")"
  if [[ "${resolved_real}" != "${resolved_self}" ]]; then
    codex_should_auto_bypass_sandbox() {
      [[ "${tool}" == "codex" ]] || return 1
      case "${AGENTIC_CODEX_AUTO_BYPASS_SANDBOX:-1}" in
        0|false|FALSE|no|NO|off|OFF) return 1 ;;
      esac
      if [[ -n "${AGENTIC_CODEX_SANDBOX_PROBE_CMD:-}" ]]; then
        bash -lc "${AGENTIC_CODEX_SANDBOX_PROBE_CMD}" >/dev/null 2>&1
        return $?
      fi
      command -v unshare >/dev/null 2>&1 || return 1
      timeout 2 sh -lc 'unshare -Ur true' >/dev/null 2>&1
    }

    codex_passthrough_subcommand() {
      local arg
      for arg in "$@"; do
        case "${arg}" in
          -h|--help|-V|--version|completion|features|login|logout|mcp|mcp-server|app-server|debug)
            return 0
            ;;
        esac
      done
      return 1
    }

    if [[ "${tool}" == "codex" ]] && ! codex_passthrough_subcommand "$@"; then
      if ! codex_should_auto_bypass_sandbox; then
        bypass_args=()
        bypass_present=0
        skip_next=0
        for arg in "$@"; do
          if [[ "${skip_next}" -eq 1 ]]; then
            skip_next=0
            continue
          fi
          case "${arg}" in
            -a|--ask-for-approval|-s|--sandbox)
              skip_next=1
              ;;
            --full-auto)
              ;;
            --dangerously-bypass-approvals-and-sandbox)
              bypass_present=1
              bypass_args+=("${arg}")
              ;;
            *)
              bypass_args+=("${arg}")
              ;;
          esac
        done
        if [[ "${bypass_present}" -eq 0 ]]; then
          exec "${real_bin}" --dangerously-bypass-approvals-and-sandbox "${bypass_args[@]}"
        fi
      fi
    fi
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
