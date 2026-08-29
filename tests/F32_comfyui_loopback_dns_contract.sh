#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

compose_file="${REPO_ROOT}/compose/compose.ui.yml"
test_file="${REPO_ROOT}/tests/I1_comfyui.sh"
image_file="${REPO_ROOT}/deployments/images/comfyui-loopback/Dockerfile"

python3 - "${compose_file}" "${test_file}" "${image_file}" <<'PY' || fail "ComfyUI loopback restart/DNS/auth contract is incomplete"
from pathlib import Path
import sys

compose = Path(sys.argv[1]).read_text(encoding="utf-8")
test = Path(sys.argv[2]).read_text(encoding="utf-8")
image = Path(sys.argv[3]).read_text(encoding="utf-8")

start = compose.index("  comfyui-loopback:")
block = compose[start:compose.index("\nnetworks:", start)]
for expected in (
    "resolver 127.0.0.11 valid=5s ipv6=off;",
    "set $$comfyui_upstream comfyui;",
    "proxy_pass http://$$comfyui_upstream:8188;",
    "proxy_next_upstream error timeout invalid_header http_502 http_503 http_504;",
    "proxy_next_upstream_tries 3;",
    "127.0.0.1:${COMFYUI_HOST_PORT:-8188}:8188",
    "image: agentic/comfyui-loopback:local",
    "deployments/images/comfyui-loopback/Dockerfile",
    "openssl passwd -apr1 -stdin",
    "ComfyUI Basic Auth password hash is empty",
    "COMFYUI_AUTH_PASSWORD_FILE: /run/secrets/comfyui.auth_password",
    "secrets/runtime/comfyui.auth_password:/run/secrets/comfyui.auth_password:ro",
    "Authorization: Basic $$auth_header",
):
    assert expected in block, expected

assert "COMFYUI_AUTH_PASSWORD:" not in block
assert "COMFYUI_AUTH_PASSWORD:-change-me" not in block

assert "wait_for_loopback_api()" in test
assert "wait_for_loopback_api" in test[test.index("docker restart"):]
assert "/system_stats" in test
assert "assert_loopback_auth_contract" in test
assert "incorrect-password" in test
assert "leaks COMFYUI_AUTH_PASSWORD through docker inspect" in test
assert "apk add --no-cache openssl" in image
PY

ok "F32_comfyui_loopback_dns_contract passed"
