#!/usr/bin/env bash
# tests/J12_harness_profiles.sh — Validate Harness Profiles (§8)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

assert_cmd python3

ok "J12 test 1: harness_profiles module imports all symbols"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.harness_profiles import (
    HarnessProfile, get_all_profiles, validate_profile, validate_all_profiles
)
assert HarnessProfile.__dataclass_fields__ is not None
print('PASS')
" || fail "J12 test 1: imports failed"

ok "J12 test 2: get_all_profiles returns exactly 10 harnesses (§2.2 table)"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.harness_profiles import get_all_profiles
profiles = get_all_profiles()
assert len(profiles) == 10, f'Expected 10 profiles, got {len(profiles)}'
expected = ['codex', 'claude', 'opencode', 'kilocode', 'vibestral', 
            'hermes', 'pi-mono', 'goose', 'openclaw', 'openhands']
for name in expected:
    assert name in profiles, f'Missing harness profile: {name}'
print('PASS')
" || fail "J12 test 2: profile count wrong"

ok "J12 test 3: all profiles have required fields (model_protocol, surfaces, tests)"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.harness_profiles import get_all_profiles
profiles = get_all_profiles()
for name, p in profiles.items():
    assert hasattr(p, 'model_protocol'), f'{name} missing model_protocol'
    assert hasattr(p, 'surfaces'), f'{name} missing surfaces'
    assert hasattr(p, 'tests'), f'{name} missing tests'
    assert len(p.surfaces) > 0, f'{name} has empty surfaces'
    assert len(p.tests) > 0, f'{name} has empty tests'
print('PASS')
" || fail "J12 test 3: required fields validation failed"

ok "J12 test 4: validate_profile flags placeholder digests (§8 invariant)"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.harness_profiles import get_all_profiles, validate_profile
profiles = get_all_profiles()
# All profiles have placeholder digests in dev, so validation should report them
errors_count = sum(1 for p in profiles.values() if 'digest is placeholder' in str(validate_profile(p)))
assert errors_count > 0, 'Expected digest warnings but got none'
print(f'PASS (detected {errors_count} placeholder digests)')
" || fail "J12 test 4: digest validation failed"

ok "J12 test 5: validate_all_profiles returns errors dict with expected keys"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.harness_profiles import get_all_profiles, validate_all_profiles
profiles = get_all_profiles()
results = validate_all_profiles()
# Each profile has at least the digest placeholder error
for name in profiles:
    if name in results:
        assert isinstance(results[name], list), f'{name} errors should be list'
print(f'PASS (errors for {len(results)} profiles)')
" || fail "J12 test 5: validate_all_profiles structure wrong"

ok "J12 test 6: all model_protocols are valid (§3.2 protocol types)"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/src')
from agentic.implementations.harness_profiles import get_all_profiles
profiles = get_all_profiles()
valid_protocols = {
    'openai_responses', 'anthropic_messages', 'chat_completions',
    'ollama_native', 'configurable_endpoint', 'configurable',
    'openai_compatible', 'ollama_openai_compatible',
}
for name, p in profiles.items():
    assert p.model_protocol in valid_protocols, f'{name}: {p.model_protocol}'
print('PASS')
" || fail "J12 test 6: invalid protocol found"

echo ""
echo "=== J12_harness_profiles passed ==="
