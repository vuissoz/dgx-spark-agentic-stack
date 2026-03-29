#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${AGENTIC_SKIP_L_TESTS:-0}" == "1" ]]; then
  ok "L14 skipped because AGENTIC_SKIP_L_TESTS=1"
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
  info|ps|compose|logs)
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

PATH="${fake_bin}:${PATH}" \
AGENTIC_ROOT="${runtime_root}" \
AGENTIC_PROFILE=rootless-dev \
AGENTIC_OPTIONAL_MODULES=git-forge \
AGENTIC_SKIP_AGENT_IMAGE_BUILD=1 \
AGENT_GIT_FORGE_BOOTSTRAP_SCRIPT="${fake_bootstrap}" \
bash "${agent_bin}" rootless-dev up agents,ui,obs,rag >/tmp/agent-l14-up.out 2>&1 \
  || fail "agent up agents,ui,obs,rag failed when git-forge was enabled"

grep -q -- 'compose --project-name agentic-dev -f .*/compose\.agents\.yml -f .*/compose\.ui\.yml -f .*/compose\.obs\.yml -f .*/compose\.rag\.yml up -d' "${runtime_root}/docker.log" \
  || fail "baseline up must still launch the agents/ui/obs/rag compose files"
ok "baseline up launches the main compose files"

grep -q -- 'compose --project-name agentic-dev --profile optional-git-forge -f .*/compose\.optional\.yml up -d' "${runtime_root}/docker.log" \
  || fail "baseline up must also launch optional-forgejo when git-forge is enabled"
ok "baseline up launches git-forge alongside the baseline stacks"

grep -q '^bootstrap invoked$' "${runtime_root}/git-forge-bootstrap.log" \
  || fail "baseline up must run git-forge bootstrap before doctor-time convergence"
ok "baseline up runs git-forge bootstrap"

ok "L14_git_forge_baseline_up passed"
