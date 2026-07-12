#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

plugin_file="${REPO_ROOT}/examples/optional/openclaw-chat-status-plugin/index.js"

python3 - "${plugin_file}" <<'PY' || fail "OpenClaw chat status plugin may disclose raw transport details"
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
assert 'text: "OpenClaw status is temporarily unavailable."' in source
assert "error.message" not in source
assert "String(error)" not in source
assert "STATUS_URL" not in source[source.index("catch (_error)"):]
assert "Return a sanitized operator summary" in source
PY

ok "F33_openclaw_chat_status_sanitization_contract passed"
