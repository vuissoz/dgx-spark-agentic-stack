#!/usr/bin/env bash
set -euo pipefail

install_mode="${AGENT_CLI_INSTALL_MODE:-best-effort}"
npm_prefix="${AGENT_NPM_PREFIX:-/opt/agentic/npm-global}"
install_home="${AGENT_CLI_INSTALL_HOME:-/opt/agentic/install-home}"
openclaw_prefix="${OPENCLAW_PREFIX:-/opt/agentic/openclaw}"
codex_spec="${CODEX_CLI_NPM_SPEC:-@openai/codex@latest}"
claude_spec="${CLAUDE_CODE_NPM_SPEC:-@anthropic-ai/claude-code@latest}"
opencode_spec="${OPENCODE_NPM_SPEC:-opencode-ai@latest}"
kilocode_spec="${KILOCODE_CLI_NPM_SPEC:-@kilocode/cli@latest}"
pi_spec="${PI_CODING_AGENT_NPM_SPEC:-@mariozechner/pi-coding-agent@latest}"
openhands_install_script="${OPENHANDS_INSTALL_SCRIPT:-https://install.openhands.dev/install.sh}"
openclaw_install_script="${OPENCLAW_INSTALL_CLI_SCRIPT:-https://openclaw.ai/install-cli.sh}"
openclaw_install_version="${OPENCLAW_INSTALL_VERSION:-latest}"
vibe_install_script="${VIBE_INSTALL_SCRIPT:-https://mistral.ai/vibe/install.sh}"
hermes_git_url="${HERMES_AGENT_GIT_URL:-https://github.com/NousResearch/hermes-agent.git}"
hermes_git_ref="${HERMES_AGENT_GIT_REF:-v2026.4.3}"
hermes_git_sha="${HERMES_AGENT_GIT_SHA:-abf1e98f6253f6984479fe03d1098173a9b065a7}"
hermes_pip_extras="${HERMES_PIP_EXTRAS:-pty,cli}"
hermes_install_dir="${HERMES_INSTALL_DIR:-/opt/agentic/hermes-agent}"
hermes_venv_dir="${HERMES_VENV_DIR:-/opt/agentic/hermes-venv}"

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

version_lt() {
  local lhs="$1"
  local rhs="$2"
  local smallest

  smallest="$(printf '%s\n%s\n' "${lhs}" "${rhs}" | sort -V | head -n 1)"
  [[ "${smallest}" == "${lhs}" && "${lhs}" != "${rhs}" ]]
}

node_version() {
  local raw
  raw="$(node --version 2>/dev/null || true)"
  raw="${raw#v}"
  printf '%s\n' "${raw}"
}

ensure_node_version_at_least() {
  local minimum="$1"
  local current

  current="$(node_version)"
  if [[ -z "${current}" ]]; then
    fail_or_warn "node runtime is unavailable (required >= ${minimum} for pi CLI)"
    return 1
  fi

  if version_lt "${current}" "${minimum}"; then
    fail_or_warn "node runtime ${current} is below required ${minimum} for pi CLI"
    return 1
  fi

  return 0
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

install_hermes_cli() {
  local repo_url="$1"
  local repo_ref="$2"
  local repo_sha="$3"
  local extras="$4"
  local actual_sha=""
  local pip_target=""

  rm -rf "${hermes_install_dir}" "${hermes_venv_dir}"

  if ! git clone --depth 1 --branch "${repo_ref}" "${repo_url}" "${hermes_install_dir}"; then
    if ! git clone --depth 1 "${repo_url}" "${hermes_install_dir}"; then
      record_cli_path hermes "" "missing"
      fail_or_warn "unable to clone Hermes Agent from ${repo_url}@${repo_ref}"
      return 1
    fi
    (
      cd "${hermes_install_dir}"
      git fetch --depth 1 origin "${repo_ref}"
      git checkout --detach FETCH_HEAD
    ) || {
      record_cli_path hermes "" "missing"
      fail_or_warn "unable to checkout Hermes Agent ref ${repo_ref}"
      return 1
    }
  fi

  actual_sha="$(git -C "${hermes_install_dir}" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "${repo_sha}" && -n "${actual_sha}" && "${actual_sha}" != "${repo_sha}" ]]; then
    record_cli_path hermes "" "missing"
    fail_or_warn "Hermes Agent SHA mismatch: expected ${repo_sha}, got ${actual_sha}"
    return 1
  fi

  python3 -m venv "${hermes_venv_dir}" || {
    record_cli_path hermes "" "missing"
    fail_or_warn "unable to create Hermes virtualenv at ${hermes_venv_dir}"
    return 1
  }

  "${hermes_venv_dir}/bin/pip" install --no-cache-dir --upgrade pip setuptools wheel >/dev/null || {
    record_cli_path hermes "" "missing"
    fail_or_warn "unable to prepare Hermes virtualenv tooling"
    return 1
  }

  pip_target="${hermes_install_dir}"
  if [[ -n "${extras}" ]]; then
    pip_target="${pip_target}[${extras}]"
  fi

  if "${hermes_venv_dir}/bin/pip" install --no-cache-dir "${pip_target}"; then
    track_cli_after_install hermes "${hermes_venv_dir}/bin/hermes" \
      || fail_or_warn "Hermes install completed but executable was not found"
    cat > /etc/agentic/hermes-install-source <<EOF
url=${repo_url}
ref=${repo_ref}
sha=${actual_sha:-unknown}
extras=${extras}
install_dir=${hermes_install_dir}
venv_dir=${hermes_venv_dir}
EOF
    chmod 0644 /etc/agentic/hermes-install-source
  else
    record_cli_path hermes "" "missing"
    fail_or_warn "unable to install Hermes Agent from ${repo_url}@${repo_ref}"
  fi
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
install_npm_cli kilo "${kilocode_spec}"
if ensure_node_version_at_least "20.6.0"; then
  install_npm_cli pi "${pi_spec}"
else
  record_cli_path pi "" "missing"
fi

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

install_hermes_cli "${hermes_git_url}" "${hermes_git_ref}" "${hermes_git_sha}" "${hermes_pip_extras}" || true

for cli in codex claude opencode kilo pi vibe openhands openclaw hermes; do
  if [[ ! -f "/etc/agentic/${cli}-real-path" ]]; then
    record_cli_path "${cli}" "" "missing"
  fi
done

for readable_dir in "${npm_prefix}" "${install_home}" "${openclaw_prefix}" "${hermes_install_dir}" "${hermes_venv_dir}"; do
  [[ -e "${readable_dir}" ]] || continue
  chmod -R a+rX "${readable_dir}"
done
