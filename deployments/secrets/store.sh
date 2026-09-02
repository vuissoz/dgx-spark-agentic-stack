#!/usr/bin/env bash
# deployments/secrets/store.sh — Minimal Secure SecretStore (PLAN.md §10)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/scripts/lib/runtime.sh"

AGENTIC_SECRET_STORE="${AGENTIC_ROOT:-/srv/agentic}/secrets/store.jsonl"
AGENTIC_SECRET_AUDIT_LOG="${AGENTIC_ROOT:-/srv/agentic}/secrets/audit.log"
DEFAULT_EXPIRATION_SEC="${AGENTIC_SECRET_DEFAULT_TTL_SEC:-3600}"

log_audit() {
  local action="$1" key="$2" user="${USER:-unknown}" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "${AGENTIC_SECRET_AUDIT_LOG}")"
  echo "{\"ts\":\"${ts}\",\"user\":\"${user}\",\"action\":\"${action}\",\"key\":\"${key}\"}" >>"${AGENTIC_SECRET_AUDIT_LOG}" 2>/dev/null || true
}

ensure_store_exists() {
  mkdir -p "$(dirname "${AGENTIC_SECRET_STORE}")" 2>/dev/null || true
  if [[ ! -f "${AGENTIC_SECRET_STORE}" ]]; then
    touch "${AGENTIC_SECRET_STORE}"
    chmod 0600 "${AGENTIC_SECRET_STORE}"
  fi
  mkdir -p "$(dirname "${AGENTIC_SECRET_AUDIT_LOG}")" 2>/dev/null || true
  touch "${AGENTIC_SECRET_AUDIT_LOG}" 2>/dev/null || true
  chmod 0600 "${AGENTIC_SECRET_AUDIT_LOG}" 2>/dev/null || true
}

store_get() {
  local key="$1" scope="${2:-*}" expiration_sec="${3:-${DEFAULT_EXPIRATION_SEC}}"
  ensure_store_exists
  log_audit "get" "${key}"
  
  local raw_value expiry_status value
  set +e
  raw_value="$(python3 -c "
import sys, json, time
store=sys.argv[1]; key=sys.argv[2]; scope=sys.argv[3]; ttl=int(sys.argv[4])
now=time.time(); found=None
try:
    with open(store) as f:
        for l in f:
            l=l.strip()
            if not l: continue
            try: o=json.loads(l)
            except: continue
            if o.get('key')==key and (o.get('scope')==scope or scope=='*'): found=o
    if not found: print('NOT_FOUND'); sys.exit(0)
    ct=found.get('created_epoch',now)
    if now-ct>=ttl: print('EXPIRED'); sys.exit(0)
    val=found.get('value','')
    if not val: print('MISSING_VAL'); sys.exit(1)
    print(f'OK {val}')
except SystemExit as e: raise SystemExit(e.code)
except Exception as e: print(f'ERR {e}'); sys.exit(1)
" "${AGENTIC_SECRET_STORE}" "${key}" "${scope}" "${expiration_sec}")" || true
  set -e
  
  expiry_status="${raw_value%% *}"
  value="${raw_value#* }"
  
  if [[ "${expiry_status}" == "NOT_FOUND" ]]; then echo "SECRET_NOT_FOUND: ${key}" >&2; return 1; fi
  if [[ "${expiry_status}" == "EXPIRED" || "${expiry_status}" == "MISSING_VAL" ]]; then echo "SECRET_EXPIRED: ${key}" >&2; log_audit "get_expired" "${key}"; return 1; fi
  printf '%s\n' "${value}"
}

store_set() {
  local key="$1" value="$2" scope="${3:-*}"
  ensure_store_exists
  log_audit "set" "${key}"
  
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local created_epoch; created_epoch="$(date +%s)"
  
  if [[ -s "${AGENTIC_SECRET_STORE}" ]]; then tail -c 1 "${AGENTIC_SECRET_STORE}" | read -r _ || echo "" >> "${AGENTIC_SECRET_STORE}"; fi
  
  local safe_key safe_value safe_scope
  safe_key="${key//\'/\'\\\'\'}"
  safe_value="${value//\'/\'\\\'\'}"
  safe_scope="${scope//\'/\'\\\'\'}"
  
  echo "{\"ts\":\"${ts}\",\"user\":\"${USER:-unknown}\",\"action\":\"set\",\"key\":\"${safe_key}\",\"scope\":\"${safe_scope}\",\"value\":\"${safe_value}\",\"created\":\"${ts}\",\"created_epoch\":${created_epoch}}" >> "${AGENTIC_SECRET_STORE}"
  
  python3 -c "
import json
store = '''${AGENTIC_SECRET_STORE}'''
key, scope = '${safe_key}', '${safe_scope}'
all_objects = []
matched_indices = []
with open(store) as f:
    for i, line in enumerate(f):
        line = line.strip()
        if not line: continue
        try: obj = json.loads(line)
        except: continue
        all_objects.append((i, obj))
        if obj.get('key') == key and obj.get('scope') == scope:
            matched_indices.append(i)

keep_set = set(matched_indices[-3:])
filtered_lines = []
for i, obj in all_objects:
    if i not in matched_indices or i in keep_set:
        filtered_lines.append(obj)

with open(store+'.tmp', 'w') as f:
    for o in filtered_lines:
        f.write(json.dumps(o) + chr(10))
" 2>/dev/null || true
  
  [[ -f "${AGENTIC_SECRET_STORE}.tmp" ]] && mv "${AGENTIC_SECRET_STORE}.tmp" "${AGENTIC_SECRET_STORE}"
  chmod 0600 "${AGENTIC_SECRET_STORE}"
  
  log_audit "rotated" "${key}"
}

store_generate() {
  local key="$1" scope="${2:-*}" length="${3:-32}"
  local value
  value="$(openssl rand -hex "${length}" 2>/dev/null || od -An -N"${length}" -tx1 /dev/urandom | tr -d ' \n')"
  store_set "${key}" "${value}" "${scope}"
  printf '%s\n' "${value}"
}

store_list() {
  ensure_store_exists
  python3 -c "
import json
lines = set()
with open('${AGENTIC_SECRET_STORE}') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try: obj = json.loads(line); lines.add((obj.get('key'), obj.get('scope')))
        except: pass
for k, s in sorted(lines): print(f'{k} (scope: {s})')
"
}

case "${1:-help}" in
  get)   shift; store_get "$@" ;;
  set)   shift; store_set "$@" ;;
  generate) shift; store_generate "$@" ;;
  list)  shift; store_list "$@" ;;
  *)     echo "Usage: store.sh {get|set|generate|list} [key] [scope]" >&2; exit 1 ;;
esac
