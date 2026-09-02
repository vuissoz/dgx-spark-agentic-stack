#!/usr/bin/env bash
# scripts/update_harness_profiles.sh - Script pour régénérer harness_profiles.py
# Usage: ./scripts/update_harness_profiles.sh [--check|--force]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GENERATOR_SCRIPT="${REPO_ROOT}/scripts/generate_harness_profiles.py"
CONFIG_FILE="${REPO_ROOT}/src/agentic/implementations/harness_profiles_config.yaml"
OUTPUT_FILE="${REPO_ROOT}/src/agentic/implementations/harness_profiles.py"

usage() {
    cat <<USAGE
Usage: $0 [--check|--force|--help]

Options:
  --check    Vérifier si harness_profiles.py est à jour (exit 1 si obsolète)
  --force    Régénérer même si le fichier existe
  --help     Afficher cette aide

Description:
  Régénère harness_profiles.py à partir de harness_profiles_config.yaml.
  Les digests sont calculés dynamiquement à partir des spécifications npm/Git/URL.
USAGE
}

check_mode=false
force_mode=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            check_mode=true
            shift
            ;;
        --force)
            force_mode=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if ${check_mode}; then
    python3 "${GENERATOR_SCRIPT}" --check --config "${CONFIG_FILE}" --output "${OUTPUT_FILE}"
    exit $?
fi

echo "Regenerating harness_profiles.py from ${CONFIG_FILE}..."
python3 "${GENERATOR_SCRIPT}" ${force_mode:+--force} --config "${CONFIG_FILE}" --output "${OUTPUT_FILE}"

echo "Done. Verify with: python3 -c \"from src.agentic.implementations.harness_profiles import get_all_profiles; print(f'Loaded {len(get_all_profiles())} profiles')\""
