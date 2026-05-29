#!/usr/bin/env bash
set -euo pipefail

exec whisper --language French --task transcribe "$@"
