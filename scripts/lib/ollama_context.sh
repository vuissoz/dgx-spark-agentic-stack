#!/usr/bin/env bash

parse_memory_to_bytes() {
  local raw_value="${1:-}"

  python3 - "${raw_value}" <<'PY'
import decimal
import re
import sys

raw = (sys.argv[1] or "").strip().lower()
match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([a-z]*)", raw)
if not match:
    raise SystemExit(1)

value = decimal.Decimal(match.group(1))
unit = match.group(2)
factors = {
    "": 1,
    "b": 1,
    "k": 1024,
    "kb": 1024,
    "ki": 1024,
    "kib": 1024,
    "m": 1024 ** 2,
    "mb": 1024 ** 2,
    "mi": 1024 ** 2,
    "mib": 1024 ** 2,
    "g": 1024 ** 3,
    "gb": 1024 ** 3,
    "gi": 1024 ** 3,
    "gib": 1024 ** 3,
    "t": 1024 ** 4,
    "tb": 1024 ** 4,
    "ti": 1024 ** 4,
    "tib": 1024 ** 4,
}
factor = factors.get(unit)
if factor is None:
    raise SystemExit(1)

print(int(value * factor))
PY
}

bytes_to_gib_ceil() {
  local bytes_value="${1:-0}"

  python3 - "${bytes_value}" <<'PY'
import sys

value = int(sys.argv[1] or "0")
gib = 1024 ** 3
print((value + gib - 1) // gib)
PY
}

ollama_context_estimate_report() {
  local model="$1"
  local requested_context="${2:-0}"
  local mem_limit_raw="${3:-}"
  local ollama_base_url="${AGENTIC_OLLAMA_ESTIMATOR_BASE_URL:-http://127.0.0.1:11434}"
  local tags_file="${AGENTIC_OLLAMA_ESTIMATOR_TAGS_FILE:-}"
  local show_file="${AGENTIC_OLLAMA_ESTIMATOR_SHOW_FILE:-}"

  python3 - "${model}" "${requested_context}" "${mem_limit_raw}" "${ollama_base_url}" "${tags_file}" "${show_file}" <<'PY'
import decimal
import json
import re
import sys
import urllib.error
import urllib.request

model, requested_context_raw, mem_limit_raw, base_url, tags_path, show_path = sys.argv[1:7]
requested_context = int(requested_context_raw or "0")


def load_json_from_file(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def load_json_from_url(url, payload=None):
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)


def first_suffix_number(payload, suffix):
    for key, value in payload.items():
        if key.endswith(suffix) and isinstance(value, (int, float)):
            return int(value)
    return 0


def parse_memory_to_bytes(raw):
    raw = (raw or "").strip().lower()
    if not raw:
      return 0
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([a-z]*)", raw)
    if not match:
        raise SystemExit(f"invalid memory value: {raw}")
    value = decimal.Decimal(match.group(1))
    unit = match.group(2)
    factors = {
        "": 1,
        "b": 1,
        "k": 1024,
        "kb": 1024,
        "ki": 1024,
        "kib": 1024,
        "m": 1024 ** 2,
        "mb": 1024 ** 2,
        "mi": 1024 ** 2,
        "mib": 1024 ** 2,
        "g": 1024 ** 3,
        "gb": 1024 ** 3,
        "gi": 1024 ** 3,
        "gib": 1024 ** 3,
        "t": 1024 ** 4,
        "tb": 1024 ** 4,
        "ti": 1024 ** 4,
        "tib": 1024 ** 4,
    }
    factor = factors.get(unit)
    if factor is None:
        raise SystemExit(f"invalid memory unit: {raw}")
    return int(value * factor)


try:
    if tags_path:
        tags_payload = load_json_from_file(tags_path)
    else:
        tags_payload = load_json_from_url(f"{base_url.rstrip('/')}/api/tags")

    if show_path:
        show_payload = load_json_from_file(show_path)
    else:
        show_payload = load_json_from_url(f"{base_url.rstrip('/')}/api/show", {"model": model})
except (OSError, ValueError, urllib.error.URLError, urllib.error.HTTPError) as exc:
    raise SystemExit(str(exc))

if isinstance(show_payload, dict) and show_payload.get("error"):
    raise SystemExit(f"api/show returned error for {model}: {show_payload.get('error')}")

models = tags_payload.get("models") or []
exact_match = None
base_match = None
base_slug = model.split(":", 1)[0]
model_size_bytes = 0

for entry in models:
    if not isinstance(entry, dict):
        continue
    name = str(entry.get("name", ""))
    if name == model:
        exact_match = entry
        break
    if name.split(":", 1)[0] == base_slug and base_match is None:
        base_match = entry

selected_entry = exact_match or base_match
if isinstance(selected_entry, dict):
    size_raw = selected_entry.get("size")
    if isinstance(size_raw, (int, float)):
        model_size_bytes = int(size_raw)

if model_size_bytes <= 0:
    raise SystemExit(f"unable to resolve model size for {model}")

model_info = show_payload.get("model_info") or {}
model_max_context = first_suffix_number(model_info, ".context_length")
if model_max_context <= 0 and requested_context > 0:
    model_max_context = requested_context
if model_max_context <= 0:
    raise SystemExit(f"unable to resolve model max context for {model}")

block_count = first_suffix_number(model_info, ".block_count")
kv_head_count = first_suffix_number(model_info, ".attention.head_count_kv")
if kv_head_count <= 0:
    kv_head_count = first_suffix_number(model_info, ".attention.head_count")
key_length = first_suffix_number(model_info, ".attention.key_length")
if key_length <= 0:
    embed_dim = first_suffix_number(model_info, ".embedding_length")
    head_count = first_suffix_number(model_info, ".attention.head_count")
    if embed_dim > 0 and head_count > 0:
        key_length = embed_dim // head_count

if block_count > 0 and kv_head_count > 0 and key_length > 0:
    kv_bytes_per_token = 2 * block_count * kv_head_count * key_length * 2
else:
    kv_bytes_per_token = 131072

safety_overhead_bytes = 1024 ** 3
estimated_required_bytes = 0
if requested_context > 0:
    estimated_required_bytes = model_size_bytes + (requested_context * kv_bytes_per_token) + safety_overhead_bytes

mem_limit_bytes = parse_memory_to_bytes(mem_limit_raw) if mem_limit_raw else 0
estimated_max_fitting_context = 0
if mem_limit_bytes > 0:
    available_kv_bytes = mem_limit_bytes - model_size_bytes - safety_overhead_bytes
    if available_kv_bytes > 0:
        estimated_max_fitting_context = available_kv_bytes // kv_bytes_per_token
    if estimated_max_fitting_context > model_max_context:
        estimated_max_fitting_context = model_max_context

print(f"model_max_context={model_max_context}")
print(f"kv_bytes_per_token={kv_bytes_per_token}")
print(f"model_size_bytes={model_size_bytes}")
print(f"safety_overhead_bytes={safety_overhead_bytes}")
print(f"estimated_required_bytes={estimated_required_bytes}")
print(f"mem_limit_bytes={mem_limit_bytes}")
print(f"estimated_max_fitting_context={estimated_max_fitting_context}")
PY
}

agentic_context_effective_budget() {
  local candidate=0
  local budget=0

  for candidate in "$@"; do
    [[ "${candidate}" =~ ^[0-9]+$ ]] || continue
    (( candidate > 0 )) || continue
    if (( budget == 0 || candidate < budget )); then
      budget="${candidate}"
    fi
  done

  printf '%s\n' "${budget}"
}

agentic_context_compaction_percent() {
  local raw_value="${1:-}"
  local fallback="${2:-}"

  if [[ "${raw_value}" =~ ^[0-9]+$ ]] && (( raw_value > 0 && raw_value < 100 )); then
    printf '%s\n' "${raw_value}"
  else
    printf '%s\n' "${fallback}"
  fi
}

agentic_context_compaction_report() {
  local context_budget="${1:-0}"
  local soft_percent="${2:-75}"
  local danger_percent="${3:-90}"
  local soft_tokens=0
  local danger_tokens=0

  soft_percent="$(agentic_context_compaction_percent "${soft_percent}" "75")"
  danger_percent="$(agentic_context_compaction_percent "${danger_percent}" "90")"

  if (( soft_percent >= danger_percent )); then
    soft_percent="75"
    danger_percent="90"
  fi

  if [[ "${context_budget}" =~ ^[0-9]+$ ]] && (( context_budget > 1 )); then
    soft_tokens="$(( context_budget * soft_percent / 100 ))"
    danger_tokens="$(( context_budget * danger_percent / 100 ))"

    if (( soft_tokens < 1 )); then
      soft_tokens=1
    elif (( soft_tokens >= context_budget )); then
      soft_tokens="$(( context_budget - 1 ))"
    fi

    if (( danger_tokens <= soft_tokens )); then
      danger_tokens="$(( soft_tokens + 1 ))"
    fi
    if (( danger_tokens >= context_budget )); then
      danger_tokens="$(( context_budget - 1 ))"
    fi
    if (( danger_tokens <= soft_tokens )); then
      soft_tokens="$(( context_budget - 2 ))"
      danger_tokens="$(( context_budget - 1 ))"
    fi
  fi

  printf 'context_budget_tokens=%s\n' "${context_budget}"
  printf 'soft_percent=%s\n' "${soft_percent}"
  printf 'danger_percent=%s\n' "${danger_percent}"
  printf 'soft_tokens=%s\n' "${soft_tokens}"
  printf 'danger_tokens=%s\n' "${danger_tokens}"
}
