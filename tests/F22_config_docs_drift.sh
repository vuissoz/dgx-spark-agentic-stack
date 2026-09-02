#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd python3

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

python3 "${REPO_ROOT}/scripts/check_config_docs_drift.py" --repo-root "${REPO_ROOT}"
ok "configuration docs drift check passes on repo state"

cp "${REPO_ROOT}/docs/runbooks/configuration-explained-beginners.en.md" "${tmp_dir}/configuration-explained-beginners.en.md"
cp "${REPO_ROOT}/docs/runbooks/configuration-expliquee-debutants.md" "${tmp_dir}/configuration-expliquee-debutants.md"

python3 - "${tmp_dir}/configuration-explained-beginners.en.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "| `OLLAMA_HOST_PORT` | Ollama API | `11434` |\n"
if needle not in text:
    raise SystemExit("fixture is missing OLLAMA_HOST_PORT row")
path.write_text(text.replace(needle, "", 1), encoding="utf-8")
PY

set +e
python3 "${REPO_ROOT}/scripts/check_config_docs_drift.py" \
  --repo-root "${REPO_ROOT}" \
  --doc-en "${tmp_dir}/configuration-explained-beginners.en.md" \
  --doc-fr "${tmp_dir}/configuration-expliquee-debutants.md" >/tmp/agent-f22-config-docs-missing.out 2>&1
missing_rc=$?
set -e
[[ "${missing_rc}" -ne 0 ]] || fail "checker must fail when a runtime schema variable disappears from the English runbook"
grep -q 'beginner configuration docs drifted' /tmp/agent-f22-config-docs-missing.out \
  || fail "checker must report EN/FR variable-set drift explicitly"
grep -q 'OLLAMA_HOST_PORT' /tmp/agent-f22-config-docs-missing.out \
  || fail "checker must name the drifted variable"
ok "configuration docs drift check catches EN/FR variable-set drift"

cp "${REPO_ROOT}/docs/runbooks/configuration-explained-beginners.en.md" "${tmp_dir}/configuration-explained-beginners.en.md"
cp "${REPO_ROOT}/docs/runbooks/configuration-expliquee-debutants.md" "${tmp_dir}/configuration-expliquee-debutants.md"

python3 - "${tmp_dir}/configuration-explained-beginners.en.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "| `TRTLLM_MODELS` | CSV list of model ids exposed by TRT-LLM | `https://huggingface.co/chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4` | shell |\n"
if needle not in text:
    raise SystemExit("fixture is missing TRTLLM_MODELS row")
replacement = "| `TRTLLM_GHOST_VAR` | obsolete example | `none` | shell |\n"
path.write_text(text.replace(needle, replacement, 1), encoding="utf-8")
PY

python3 - "${tmp_dir}/configuration-expliquee-debutants.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "| `TRTLLM_MODELS` | liste CSV de modeles exposes par TRT-LLM | `https://huggingface.co/chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4` | shell |\n"
if needle not in text:
    raise SystemExit("fixture is missing TRTLLM_MODELS row")
replacement = "| `TRTLLM_GHOST_VAR` | exemple obsolete | `none` | shell |\n"
path.write_text(text.replace(needle, replacement, 1), encoding="utf-8")
PY

set +e
python3 "${REPO_ROOT}/scripts/check_config_docs_drift.py" \
  --repo-root "${REPO_ROOT}" \
  --doc-en "${tmp_dir}/configuration-explained-beginners.en.md" \
  --doc-fr "${tmp_dir}/configuration-expliquee-debutants.md" >/tmp/agent-f22-config-docs-stale.out 2>&1
stale_rc=$?
set -e
[[ "${stale_rc}" -ne 0 ]] || fail "checker must fail when docs advertise a non-existent config variable"
grep -q 'no longer resolve to live repo sources' /tmp/agent-f22-config-docs-stale.out \
  || fail "checker must report stale documented variables explicitly"
grep -q 'TRTLLM_GHOST_VAR' /tmp/agent-f22-config-docs-stale.out \
  || fail "checker must name the stale variable"
ok "configuration docs drift check catches stale documented variables"

ok "F22_config_docs_drift passed"
