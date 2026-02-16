#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "python3" && "${2:-}" == "main.py" ]]; then
  if ! printf ' %s ' "$*" | grep -q ' --cpu '; then
    if ! python3 - <<'PY'
import sys
import torch

sys.exit(0 if torch.cuda.is_available() else 1)
PY
    then
      echo "WARN: torch CUDA backend unavailable; starting ComfyUI with --cpu fallback" >&2
      set -- "$@" --cpu
    fi
  fi
fi

exec "$@"
