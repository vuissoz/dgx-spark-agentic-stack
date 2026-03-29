#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L13 skipped because AGENTIC_SKIP_L_TESTS=1"
  exit 0
fi

agent_bin="${REPO_ROOT}/agent"
[[ -f "${agent_bin}" ]] || fail "agent script missing: ${agent_bin}"

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

runtime_root="${tmp_root}/runtime"
fake_bin="${tmp_root}/fake-bin"
fake_bootstrap="${tmp_root}/fake-git-forge-bootstrap.sh"
mkdir -p "${runtime_root}" "${fake_bin}"

cat > "${fake_bin}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

log_file="${AGENTIC_ROOT}/docker.log"
mkdir -p "$(dirname "${log_file}")"
printf '%s\n' "$*" >> "${log_file}"

case "${1:-}" in
  info)
    exit 0
    ;;
  ps)
    exit 0
    ;;
  compose)
    exit 0
    ;;
  logs)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "${fake_bin}/docker"

cat > "${fake_bootstrap}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'bootstrap invoked\n' >> "${AGENTIC_ROOT}/git-forge-bootstrap.log"
SH
chmod +x "${fake_bootstrap}"

ls_output="$(
  PATH="${fake_bin}:${PATH}" \
  AGENTIC_ROOT="${runtime_root}" \
  AGENTIC_PROFILE=rootless-dev \
  bash "${agent_bin}" rootless-dev ls
)"

printf '%s\n' "${ls_output}" | grep -q $'^forgejo\toptional-forgejo\tmissing\tn/a\tn/a\t-\t-$' \
  || fail "agent ls must expose a forgejo surface row backed by optional-forgejo"
ok "agent ls exposes forgejo as a general surface target"

PATH="${fake_bin}:${PATH}" \
AGENTIC_ROOT="${runtime_root}" \
AGENTIC_PROFILE=rootless-dev \
bash "${agent_bin}" rootless-dev stop forgejo >/tmp/agent-l13-stop.out 2>&1 \
  || fail "agent stop forgejo failed"

grep -q -- 'compose --project-name agentic-dev -f .*/compose\.ui\.yml stop optional-forgejo' "${runtime_root}/docker.log" \
  || fail "agent stop forgejo must stop the optional-forgejo service through the ui compose file"
ok "agent stop forgejo routes to optional-forgejo"

PATH="${fake_bin}:${PATH}" \
AGENTIC_ROOT="${runtime_root}" \
AGENTIC_PROFILE=rootless-dev \
AGENT_GIT_FORGE_BOOTSTRAP_SCRIPT="${fake_bootstrap}" \
bash "${agent_bin}" rootless-dev start forgejo >/tmp/agent-l13-start.out 2>&1 \
  || fail "agent start forgejo failed"

grep -q -- 'compose --project-name agentic-dev -f .*/compose\.ui\.yml up -d --no-deps optional-forgejo' "${runtime_root}/docker.log" \
  || fail "agent start forgejo must start the optional-forgejo service without dependencies through the ui compose file"
grep -q '^bootstrap invoked$' "${runtime_root}/git-forge-bootstrap.log" \
  || fail "agent start forgejo must run the git-forge bootstrap"
ok "agent start forgejo routes to optional-forgejo"

PATH="${fake_bin}:${PATH}" \
AGENTIC_ROOT="${runtime_root}" \
AGENTIC_PROFILE=rootless-dev \
AGENTIC_SKIP_OPTIONAL_GATING=1 \
bash "${agent_bin}" rootless-dev down optional >/tmp/agent-l13-down.out 2>&1 \
  || fail "agent down optional failed"

if grep -q -- '--profile optional-git-forge' "${runtime_root}/docker.log"; then
  fail "agent down optional must not include git-forge now that forgejo is baseline"
fi
ok "agent down optional leaves the baseline forgejo service alone"

PATH="${fake_bin}:${PATH}" \
AGENTIC_ROOT="${runtime_root}" \
AGENTIC_PROFILE=rootless-dev \
bash "${agent_bin}" rootless-dev logs forgejo 2>/tmp/agent-l13-logs.err || true

grep -q -- 'logs --tail 200 -f optional-forgejo' "${runtime_root}/docker.log" \
  || fail "agent logs forgejo must normalize to optional-forgejo"
ok "agent logs forgejo resolves to the underlying optional-forgejo service"

ok "L13_forgejo_general_commands passed"
