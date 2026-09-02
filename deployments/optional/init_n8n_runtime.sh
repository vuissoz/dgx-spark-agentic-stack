#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible entry point. n8n now shares the optional runtime
# initializer so its ownership migration and activation request stay aligned.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/init_runtime.sh" "$@"
