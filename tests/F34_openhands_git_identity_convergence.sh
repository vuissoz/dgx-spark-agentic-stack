#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd git
assert_cmd python3

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

python3 - "${REPO_ROOT}/deployments/optional/git_forge_bootstrap.py" "${tmp_dir}" <<'PY' \
  || fail "OpenHands Git identity convergence failed"
import importlib.util
import json
import pathlib
import sys

module_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("git_forge_bootstrap", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

state = root / "openhands" / "state"
home = state / "home"
state.mkdir(parents=True)
settings_path = state / "settings.json"
settings_path.write_text(
    json.dumps(
        {
            "git_user_name": "openhands",
            "git_user_email": "openhands@all-hands.dev",
            "llm_model": "local-model",
        }
    ),
    encoding="utf-8",
)
account = {
    "username": "openhands",
    "display_name": "OpenHands",
    "email": "openhands@forge.agentic.local",
    "host_home": home,
    "container_home": "/.openhands/home",
    "container_ssh_dir": "/.openhands/home/.ssh",
}

module.bootstrap_git_home(account)
settings = json.loads(settings_path.read_text(encoding="utf-8"))
assert settings["git_user_name"] == "OpenHands"
assert settings["git_user_email"] == "openhands@forge.agentic.local"
assert settings["llm_model"] == "local-model"

gitconfig = home / ".gitconfig"
assert module.run(["git", "config", "--file", str(gitconfig), "--get", "user.name"]).stdout.strip() == "OpenHands"
assert module.run(["git", "config", "--file", str(gitconfig), "--get", "user.email"]).stdout.strip() == "openhands@forge.agentic.local"

# A second pass must preserve the converged contents.
before = (settings_path.read_text(encoding="utf-8"), gitconfig.read_text(encoding="utf-8"))
module.bootstrap_git_home(account)
after = (settings_path.read_text(encoding="utf-8"), gitconfig.read_text(encoding="utf-8"))
assert after == before
PY

ok "F34 OpenHands Git identity convergence passed"
