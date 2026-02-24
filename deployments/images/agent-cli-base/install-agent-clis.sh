#!/usr/bin/env bash
set -euo pipefail

install_mode="${AGENT_CLI_INSTALL_MODE:-best-effort}"
npm_prefix="${AGENT_NPM_PREFIX:-/opt/agentic/npm-global}"
install_home="${AGENT_CLI_INSTALL_HOME:-/opt/agentic/install-home}"
openclaw_prefix="${OPENCLAW_PREFIX:-/opt/agentic/openclaw}"
codex_spec="${CODEX_CLI_NPM_SPEC:-@openai/codex@latest}"
claude_spec="${CLAUDE_CODE_NPM_SPEC:-@anthropic-ai/claude-code@latest}"
opencode_spec="${OPENCODE_NPM_SPEC:-opencode-ai@latest}"
openhands_install_script="${OPENHANDS_INSTALL_SCRIPT:-https://install.openhands.dev/install.sh}"
openclaw_install_script="${OPENCLAW_INSTALL_CLI_SCRIPT:-https://openclaw.ai/install-cli.sh}"
openclaw_install_version="${OPENCLAW_INSTALL_VERSION:-latest}"
vibe_install_script="${VIBE_INSTALL_SCRIPT:-https://mistral.ai/vibe/install.sh}"

status_file="/etc/agentic/cli-install-status.tsv"

if [[ "${install_mode}" != "best-effort" && "${install_mode}" != "required" ]]; then
  echo "ERROR: AGENT_CLI_INSTALL_MODE must be best-effort or required (got '${install_mode}')" >&2
  exit 1
fi

install -d -m 0755 /etc/agentic "${npm_prefix}/bin" "${install_home}" "${openclaw_prefix}"
touch "${status_file}"
chmod 0644 "${status_file}"
: >"${status_file}"

warn() {
  echo "WARN: $*" >&2
}

fail_or_warn() {
  local message="$1"
  if [[ "${install_mode}" == "required" ]]; then
    echo "ERROR: ${message}" >&2
    exit 1
  fi
  warn "${message}"
}

record_cli_path() {
  local cli="$1"
  local real_path="${2:-}"
  local state="${3:-missing}"

  printf '%s\n' "${real_path}" >"/etc/agentic/${cli}-real-path"
  chmod 0644 "/etc/agentic/${cli}-real-path"
  printf '%s\t%s\t%s\n' "${cli}" "${state}" "${real_path:-none}" >>"${status_file}"
}

discover_bin() {
  local cli="$1"
  shift || true
  local candidate
  for candidate in "$@"; do
    [[ -n "${candidate}" ]] || continue
    if [[ -x "${candidate}" ]]; then
      readlink -f "${candidate}" 2>/dev/null || printf '%s\n' "${candidate}"
      return 0
    fi
  done

  candidate="$(command -v "${cli}" 2>/dev/null || true)"
  if [[ -n "${candidate}" && -x "${candidate}" ]]; then
    readlink -f "${candidate}" 2>/dev/null || printf '%s\n' "${candidate}"
    return 0
  fi
  return 1
}

track_cli_after_install() {
  local cli="$1"
  shift || true
  local real_bin=""
  if real_bin="$(discover_bin "${cli}" "$@")"; then
    record_cli_path "${cli}" "${real_bin}" "installed"
    return 0
  fi
  record_cli_path "${cli}" "" "missing"
  return 1
}

install_npm_cli() {
  local cli="$1"
  local spec="$2"

  if npm install -g --omit=dev --no-fund --no-audit "${spec}"; then
    track_cli_after_install "${cli}" "${npm_prefix}/bin/${cli}" || fail_or_warn "${cli} install succeeded but executable was not found"
  else
    record_cli_path "${cli}" "" "missing"
    fail_or_warn "unable to install ${cli} (${spec})"
  fi
}

run_script_install() {
  local script_url="$1"
  shift || true
  local script_path
  script_path="$(mktemp)"
  if ! curl -fsSL "${script_url}" -o "${script_path}"; then
    rm -f "${script_path}"
    return 1
  fi

  if HOME="${install_home}" bash "${script_path}" "$@"; then
    rm -f "${script_path}"
    return 0
  fi

  rm -f "${script_path}"
  return 1
}

export npm_config_prefix="${npm_prefix}"
export PATH="${npm_prefix}/bin:${PATH}"

install_npm_cli codex "${codex_spec}"
install_npm_cli claude "${claude_spec}"
install_npm_cli opencode "${opencode_spec}"

if run_script_install "${vibe_install_script}"; then
  track_cli_after_install vibe \
    "${install_home}/.local/bin/vibe" \
    "/root/.local/bin/vibe" \
    "${npm_prefix}/bin/vibe" \
    || fail_or_warn "vibe install script completed but executable was not found"
else
  record_cli_path vibe "" "missing"
  fail_or_warn "unable to install vibe from ${vibe_install_script}"
fi

if run_script_install "${openhands_install_script}"; then
  track_cli_after_install openhands \
    "${install_home}/.local/bin/openhands" \
    "${install_home}/.openhands/bin/openhands" \
    "/root/.local/bin/openhands" \
    || fail_or_warn "openhands install script completed but executable was not found"
else
  record_cli_path openhands "" "missing"
  fail_or_warn "unable to install openhands from ${openhands_install_script}"
fi

if run_script_install "${openclaw_install_script}" --prefix "${openclaw_prefix}" --version "${openclaw_install_version}" --no-onboard; then
  track_cli_after_install openclaw \
    "${openclaw_prefix}/bin/openclaw" \
    "${install_home}/.local/bin/openclaw" \
    "/root/.local/bin/openclaw" \
    || fail_or_warn "openclaw install script completed but executable was not found"
else
  record_cli_path openclaw "" "missing"
  fail_or_warn "unable to install openclaw from ${openclaw_install_script}"
fi

for cli in codex claude opencode vibe openhands openclaw; do
  if [[ ! -f "/etc/agentic/${cli}-real-path" ]]; then
    record_cli_path "${cli}" "" "missing"
  fi
done

chmod -R a+rX "${npm_prefix}" "${install_home}" "${openclaw_prefix}"
