#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

python3 - "${REPO_ROOT}" <<'PY'
import contextlib
import hashlib
import importlib.util
import io
import os
import pathlib
import stat
import sys
import tempfile
from argparse import Namespace
from unittest import mock

repo = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("secrets_assistant", repo / "scripts/secrets_assistant.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
inventory = repo / "config/secrets.inventory.json"
compose_optional = (repo / "compose/compose.optional.yml").read_text(encoding="utf-8")
assert "N8N_BASIC_AUTH_PASSWORD_FILE: /run/secrets/n8n.auth_password" in compose_optional
assert "N8N_BASIC_AUTH_PASSWORD:" not in compose_optional
assert "secrets/runtime/n8n.auth_password:/run/secrets/n8n.auth_password:ro" in compose_optional


class TTY(io.StringIO):
    def isatty(self):
        return True


def args(*, check=False, profiles="", modules="", rotate=None):
    return Namespace(
        inventory=inventory,
        check=check,
        profiles=profiles,
        modules=modules,
        rotate=rotate,
    )


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


with tempfile.TemporaryDirectory(prefix="agent-secrets-test-") as temporary:
    root = pathlib.Path(temporary)
    runtime = root / "secrets" / "runtime"
    os.environ["AGENTIC_ROOT"] = str(root)
    os.environ["AGENT_RUNTIME_UID"] = str(os.getuid())
    os.environ["AGENT_RUNTIME_GID"] = str(os.getgid())
    os.environ["COMPOSE_PROFILES"] = ""
    os.environ["AGENTIC_OPTIONAL_MODULES"] = ""

    # Non-interactive check is read-only, actionable, and never discloses values.
    stdout, stderr = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        assert module.run(args(check=True)) == 1
    assert "run './agent secrets'" in stderr.getvalue()
    assert not runtime.exists(), "--check must not create the secret tree"

    runtime.mkdir(parents=True, mode=0o700)
    secret_value = "SENSITIVE-existing-core-value-0123456789"
    for relative in ("gate_mcp.token", "openclaw.token", "openclaw.webhook_secret"):
        path = runtime / relative
        path.write_text(secret_value + "\n", encoding="utf-8")
        path.chmod(0o600)
    original = {path.name: digest(path) for path in runtime.iterdir()}

    # UI activation asks only for the missing ComfyUI secret and preserves valid files bit-for-bit.
    new_value = "SENSITIVE-new-comfy-password-0123456789"
    prompts = []
    def hidden_prompt(prompt):
        prompts.append(prompt)
        return new_value

    stdout, stderr = io.StringIO(), io.StringIO()
    with mock.patch.object(module.sys, "stdin", TTY()), mock.patch.object(module.getpass, "getpass", hidden_prompt), \
         contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        assert module.run(args(profiles="ui")) == 0
    assert len(prompts) == 2, prompts
    assert (runtime / "comfyui.auth_password").read_text(encoding="utf-8") == new_value + "\n"
    assert all(digest(runtime / name) == value for name, value in original.items())
    combined = stdout.getvalue() + stderr.getvalue()
    assert secret_value not in combined and new_value not in combined
    artifact = root / "deployments" / "releases" / "test" / "assistant.log"
    artifact.parent.mkdir(parents=True)
    artifact.write_text(combined, encoding="utf-8")
    assert secret_value not in artifact.read_text(encoding="utf-8")
    assert new_value not in artifact.read_text(encoding="utf-8")

    # Replaying the assistant is idempotent and makes no prompt.
    with mock.patch.object(module.sys, "stdin", TTY()), mock.patch.object(
        module.getpass, "getpass", side_effect=AssertionError("unexpected secret prompt")
    ):
        assert module.run(args(profiles="ui")) == 0
    assert all(digest(runtime / name) == value for name, value in original.items())

    # Wrong metadata is reported by --check and repaired interactively without content changes.
    comfy = runtime / "comfyui.auth_password"
    comfy_digest = digest(comfy)
    comfy.chmod(0o644)
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        assert module.run(args(check=True, profiles="ui")) == 1
    assert stat.S_IMODE(comfy.stat().st_mode) == 0o644
    with mock.patch.object(module.sys, "stdin", TTY()), mock.patch.object(
        module.getpass, "getpass", side_effect=AssertionError("unexpected secret prompt")
    ):
        assert module.run(args(profiles="ui")) == 0
    assert stat.S_IMODE(comfy.stat().st_mode) == 0o600 and digest(comfy) == comfy_digest

    # n8n-ai activates n8n authentication plus all four sandbox secrets.
    stdout, stderr = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        assert module.run(args(check=True, modules="n8n-ai")) == 1
    for secret_id in (
        "n8n-basic-auth-password",
        "n8n-sandbox-api-key",
        "n8n-sandbox-registration-token",
        "n8n-sandbox-runner-key",
        "n8n-sandbox-searxng-key",
    ):
        assert secret_id in stderr.getvalue()

    # An invalid existing value is not silently replaced.
    invalid = runtime / "n8n.auth_password"
    invalid.write_text("change-me\n", encoding="utf-8")
    invalid.chmod(0o600)
    before = digest(invalid)
    with mock.patch.object(module.sys, "stdin", TTY("n\n")), contextlib.redirect_stdout(io.StringIO()):
        assert module.run(args(modules="n8n")) == 1
    assert digest(invalid) == before

    # Rotation is a separate explicit action and still never prints the new value.
    rotated = "SENSITIVE-rotated-n8n-password-0123456789"
    stdout, stderr = io.StringIO(), io.StringIO()
    with mock.patch.object(module.sys, "stdin", TTY()), mock.patch.object(
        module.getpass, "getpass", side_effect=[rotated, rotated]
    ), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        assert module.run(args(rotate="n8n-basic-auth-password")) == 0
    assert invalid.read_text(encoding="utf-8") == rotated + "\n"
    assert rotated not in stdout.getvalue() + stderr.getvalue()

print("PASS: F35 secret assistant inventory, idempotence, profiles, validation, permissions, and no-disclosure")
PY
