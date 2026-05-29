#!/usr/bin/env bash
set -euo pipefail

exec whisper --language English --task transcribe "$@"
