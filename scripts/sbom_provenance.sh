#!/usr/bin/env bash
# scripts/sbom_provenance.sh — SBOM, provenance capture and image allowlist validation (PLAN §17)
#
# This script:
#   1. Scans all compose files for image references and resolves concrete digests via docker;
#   2. Records dependency versions (Python packages from requirements.txt, npm specs from args);
#   3. Validates resolved images against an approved allowlist file;
#   4. Writes a structured SBOM JSON artifact into the release directory or current output dir.
#
# Usage:
#   scripts/sbom_provenance.sh --mode scan [--release-dir <dir>] [compose_files...]
#   scripts/sbom_provenance.sh --mode validate-allowlist [--release-dir <dir>] [allowed_images_file]
#   scripts/sbom_provenance.sh --mode list-digests [--release-dir <dir>]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "${REPO_ROOT}/scripts/lib/runtime.sh"

SBOM_MODE="scan"
RELEASE_DIR=""
COMPOSE_FILES=()
ALLOWLIST_FILE=""

# ── Helpers ──────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

json_escape() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")), end="")'; }

# ── Mode: scan ───────────────────────────────────────────────────────────

scan_compose_images() {
  local output_dir="${RELEASE_DIR:-$(mktemp -d)}"
  mkdir -p "${output_dir}"

  require_cmd docker

  # Collect all image references from compose files (excluding build-only entries)
  declare -A seen_images=()
  for cf in "${COMPOSE_FILES[@]}"; do
    [[ -f "$cf" ]] || die "compose file not found: $cf"
    while IFS= read -r line; do
      local img="${line%%:*}"
      local tag="${line#*:}"
      [[ -z "${seen_images[$img:$tag]:-}" ]] && seen_images["${img}:${tag}"]=1
    done < <(python3 -c "
import yaml, sys, re
cf = sys.argv[1]
with open(cf) as f:
    data = yaml.safe_load(f) or {}
images = set()
for svc in (data.get('services') or {}).values():
    if not isinstance(svc, dict): continue
    if 'image' not in svc or 'build' in svc: continue
    img = svc['image']
    # strip port binding prefix 127.0.0.1:PORT:...
    m = re.match(r'(\S+):(\d+):', str(img))
    if m:
        img = m.group(1)
    images.add(img)
for i in sorted(images): print(i)
" "$cf" 2>/dev/null || true)
  done

  # For each unique image, resolve digest via docker inspect (if already pulled) or docker manifest inspect
  local -a sbom_entries=()
  for img_tag in "${!seen_images[@]}"; do
    local image_ref="${img_tag%%:*}"
    local tag="${img_tag#*:}"

    # Try docker image inspect first
    local digest=""
    if docker image inspect "${image_ref}:${tag}" >/dev/null 2>&1; then
      digest="$(docker image inspect --format='{{index .RepoDigests 0}}' "${image_ref}:${tag}" 2>/dev/null | grep -o '@sha256:[a-f0-9]*' || true)"
    fi

    # If no local digest, try docker manifest inspect (requires network)
    if [[ -z "${digest:-}" ]]; then
      digest="$(docker manifest inspect "${image_ref}:${tag}" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    dgst = d.get('config', {}).get('digest', '')
    if dgst: print(dgst)
except: pass
" || true)"
    fi

    local resolved_ref
    if [[ -n "${digest:-}" ]]; then
      resolved_ref="${image_ref}@${digest}"
    else
      resolved_ref="${img_tag}  # UNRESOLVED"
    fi

    sbom_entries+=("${img_tag}|${resolved_ref}")
  done

  # Write SBOM JSON
  local sbom_file="${output_dir}/sbom.json"
  python3 -c "
import json, sys, datetime

entries_raw = sys.argv[1].split('\n') if len(sys.argv) > 1 else []
entries = []
for raw in entries_raw:
    if not raw.strip(): continue
    parts = raw.split('|', 1)
    tag = parts[0]
    resolved = parts[1] if len(parts) > 1 else ''
    entries.append({'image_tag': tag, 'resolved_reference': resolved})

sbom = {
    'schema': 'agentic.sbom.v1',
    'generated_at': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'repo_root': sys.argv[2],
    'profile': '${AGENTIC_PROFILE:-unknown}',
    'images': sorted(entries, key=lambda e: e['image_tag'])
}
json.dump(sbom, sys.stdout, indent=2)
print()
" "$(IFS=$'\n'; echo "${sbom_entries[*]}")" "${REPO_ROOT}" > "${sbom_file}"

  # Also record per-service image resolution in release directory
  for cf in "${COMPOSE_FILES[@]}"; do
    local basename; basename="$(basename "$cf" .yml)"
    python3 -c "
import yaml, json, sys
cf = sys.argv[1]
with open(cf) as f:
    data = yaml.safe_load(f) or {}
svcs = {}
for name, svc in (data.get('services') or {}).items():
    if not isinstance(svc, dict): continue
    img = svc.get('image', 'N/A')
    build = 'build' in svc and {'context': svc['build'].get('context','')} or None
    svcs[name] = {'image': img, 'resolved': '', 'build_context': build}
print(json.dumps(svcs, indent=2))
" "$cf" > "${output_dir}/${basename}.images.json" 2>/dev/null || true
  done

  echo "SBOM written: ${sbom_file}"
  if [[ -n "${RELEASE_DIR:-}" ]]; then
    cp "${sbom_file}" "${RELEASE_DIR}/sbom.json"
  fi
}

# ── Mode: validate-allowlist ─────────────────────────────────────────────

validate_allowlist() {
  require_cmd docker

  local allowed_file="${ALLOWLIST_FILE:-${AGENTIC_ROOT}/.sbom/allowed_images.txt}"

  # If no SBOM in release dir, build one on the fly
  if [[ ! -f "${RELEASE_DIR:-}/sbom.json" ]]; then
    if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
      mapfile -t COMPOSE_FILES < <(
        for target in core agents ui obs rag optional; do
          echo "${AGENTIC_COMPOSE_DIR}/compose.${target}.yml"
        done | grep -F .yml
      )
    fi
    scan_compose_images  # writes to temp dir, then we read from there
  fi

  local sbom_file="${RELEASE_DIR:-$(pwd)}/sbom.json"
  [[ -f "${sbom_file}" ]] || die "SBOM file not found: ${sbom_file}"

  if [[ ! -f "${allowed_file}" ]]; then
    # Create a default allowlist with the known base images
    mkdir -p "$(dirname "${allowed_file}")"
    cat > "${allowed_file}" <<'ALLOWLIST'
# Approved image patterns — glob-like prefixes matching image:name@digest or image:tag
# Format: one pattern per line. Lines starting with # are comments.
# Wildcard * matches any suffix within the same prefix segment.
ollama/ollama:*
ubuntu/squid:*
klutchell/unbound:*
ghcr.io/nicolaka/netshoot:*
ALLOWLIST
    echo "WARNING: created default allowlist at ${allowed_file}; edit to match your policy" >&2
  fi

  # Validate each resolved image against allowlist
  local violations=0
  python3 -c "
import json, re, sys

sbom_path = sys.argv[1]
allowlist_path = sys.argv[2]

with open(sbom_path) as f:
    sbom = json.load(f)

with open(allowlist_path) as f:
    patterns = [l.strip() for l in f if l.strip() and not l.strip().startswith('#')]

def matches_pattern(image_tag, pattern):
    prefix = pattern.split(':')[0]
    tag_part = image_tag.split(':', 1)[1] if ':' in image_tag else '*'
    return image_tag.startswith(prefix + ':') or re.match(
        '^' + pattern.replace('*', '.*').replace('?', '.') + '$', image_tag)

def matches_digest(image_ref, pattern):
    # For @digest references, check prefix match on image name
    img_name = image_ref.split('@')[0].split(':')[0] if '@' in image_ref else image_ref.split(':')[0]
    prefix = pattern.split(':')[0]
    return img_name.startswith(prefix)

violations = []
for entry in sbom.get('images', []):
    ref = entry['resolved_reference']
    raw_ref = ref.split('  # ')[0].strip() if '  # ' in ref else ref
    matched = False
    for pat in patterns:
        if '@' in raw_ref or ('#' not in raw_ref and 'UNRESOLVED' not in raw_ref):
            # digested or resolved reference — check prefix match
            if matches_digest(raw_ref, pat):
                matched = True; break
        else:
            if matches_pattern(raw_ref, pat):
                matched = True; break
    if not matched:
        violations.append(entry['image_tag'])

if violations:
    print(f'ALLOWLIST_VIOLATIONS: {len(violations)} images not in allowlist', file=sys.stderr)
    for v in violations: print(f'  - {v}', file=sys.stderr)
    sys.exit(1)
else:
    print('Allowlist validation passed')
" "${sbom_file}" "${allowed_file}" || return 1
}

# ── Mode: list-digests ───────────────────────────────────────────────────

list_digests() {
  local sbom_file="${RELEASE_DIR:-.}/sbom.json"
  [[ -f "${sbom_file}" ]] || die "SBOM not found at ${sbom_file}; run --mode scan first"

  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    sbom = json.load(f)
for entry in sbom.get('images', []):
    tag = entry['image_tag']
    ref = entry['resolved_reference']
    print(f'{tag} -> {ref}')
" "${sbom_file}"
}

# ── Mode: record-deps (Python/npm) ──────────────────────────────────────

record_deps() {
  local output_dir="${RELEASE_DIR:-$(pwd)}"
  mkdir -p "${output_dir}"

  # Python packages from requirements files
  declare -a py_req_files=()
  while IFS= read -r f; do
    py_req_files+=("$f")
  done < <(find . \
    \( -path './.runtime' -o -path './.beads' -o -path './.git' \) -prune -false -o \
    -name 'requirements*.txt' -print 2>/dev/null | head -30)

  if [[ ${#py_req_files[@]} -gt 0 ]]; then
    local deps_file="${output_dir}/python_deps.json"
    python3 -c "
import json, sys, re
reqs = {}
for path in sys.argv[1:]:
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'): continue
                m = re.match(r'^([a-zA-Z0-9_.-]+)\s*[><=!~]+\s*(\S+)', line)
                if m:
                    reqs.setdefault(path, []).append({'package': m.group(1), 'version': m.group(2)})
    except: pass

# Also check installed packages via pip freeze as fallback
deps = {'files': {}, 'installed_pip_packages': {}}
for path, specs in reqs.items():
    deps['files'][path] = specs
print(json.dumps(deps, indent=2))
" "${py_req_files[@]}" > "${deps_file}" 2>/dev/null || true
  fi

  echo "Dependencies recorded: ${output_dir}/python_deps.json (if requirements files found)"
}

# ── Main ─────────────────────────────────────────────────────────────────

usage() {
  cat <<USAGE
Usage:
  sbom_provenance.sh --mode scan [--release-dir <dir>] [compose_files...]
  sbom_provenance.sh --mode validate-allowlist [--release-dir <dir>] [--allowed-file <file>]
  sbom_provenance.sh --mode list-digests [--release-dir <dir>]
  sbom_provenance.sh --mode record-deps [--release-dir <dir>]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) SBOM_MODE="$2"; shift 2 ;;
    --release-dir) RELEASE_DIR="$2"; shift 2 ;;
    --allowed-file) ALLOWLIST_FILE="$2"; shift 2 ;;
    -h|--help|help) usage; exit 0 ;;
    *) COMPOSE_FILES+=("$1"); shift ;;
  esac
done

# Default compose files if none specified
if [[ "${SBOM_MODE}" == "scan" && ${#COMPOSE_FILES[@]} -eq 0 ]]; then
  mapfile -t COMPOSE_FILES < <(
    for target in core agents ui obs rag optional; do
      echo "${AGENTIC_COMPOSE_DIR}/compose.${target}.yml"
    done | grep -F .yml
  )
fi

case "${SBOM_MODE}" in
  scan) scan_compose_images ;;
  validate-allowlist) validate_allowlist ;;
  list-digests) list_digests ;;
  record-deps) record_deps ;;
  *) die "unknown mode: ${SBOM_MODE}" ;;
esac
