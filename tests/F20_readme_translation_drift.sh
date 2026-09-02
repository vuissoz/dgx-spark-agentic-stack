#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd python3

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

python3 "${REPO_ROOT}/scripts/check_readme_translation_drift.py"
ok "readme translation drift check passes on repo state"

cp "${REPO_ROOT}/README.md" "${tmp_dir}/README.md"
cp "${REPO_ROOT}/README.en.md" "${tmp_dir}/README.en.md"
cp "${REPO_ROOT}/README.fr.md" "${tmp_dir}/README.fr.md"

python3 - "${tmp_dir}/README.fr.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "```bash\ncomfy model download \\\n"
if needle not in text:
    raise SystemExit("fixture does not contain expected ComfyUI direct download block")
before, marker, after = text.partition(needle)
_, fence, remainder = after.partition("\n```\n")
if not fence:
    raise SystemExit("fixture block is missing closing fence")
path.write_text(before + remainder, encoding="utf-8")
PY

set +e
python3 "${REPO_ROOT}/scripts/check_readme_translation_drift.py" \
  --readme-root "${tmp_dir}/README.md" \
  --readme-en "${tmp_dir}/README.en.md" \
  --readme-fr "${tmp_dir}/README.fr.md" >/tmp/agent-f20-readme-drift.out 2>&1
drift_rc=$?
set -e
[[ "${drift_rc}" -ne 0 ]] || fail "checker must fail when README.fr loses a mirrored code block"
grep -q 'event count differs' /tmp/agent-f20-readme-drift.out \
  || fail "checker must report structural drift explicitly"
ok "readme translation drift check catches EN/FR structure drift"

cp "${REPO_ROOT}/README.md" "${tmp_dir}/README.md"
cp "${REPO_ROOT}/README.en.md" "${tmp_dir}/README.en.md"
cp "${REPO_ROOT}/README.fr.md" "${tmp_dir}/README.fr.md"

python3 - "${tmp_dir}/README.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8").replace("](README.fr.md)", "](README.fr.MISSING)", 1)
path.write_text(text, encoding="utf-8")
PY

set +e
python3 "${REPO_ROOT}/scripts/check_readme_translation_drift.py" \
  --readme-root "${tmp_dir}/README.md" \
  --readme-en "${tmp_dir}/README.en.md" \
  --readme-fr "${tmp_dir}/README.fr.md" >/tmp/agent-f20-readme-root-link.out 2>&1
root_link_rc=$?
set -e
[[ "${root_link_rc}" -ne 0 ]] || fail "checker must fail when README.md drops README.fr.md link"
grep -q 'missing README links' /tmp/agent-f20-readme-root-link.out \
  || fail "checker must report missing root README links explicitly"
ok "readme translation drift check catches missing landing-page link"

ok "F20_readme_translation_drift passed"
