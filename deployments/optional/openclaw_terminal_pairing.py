#!/usr/bin/env python3
"""Repair an OpenClaw CLI scope-upgrade bootstrap deadlock explicitly."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import tempfile
from typing import Any


ALLOWED_OPERATOR_SCOPES = {
    "operator.read",
    "operator.write",
    "operator.pairing",
}


def load_object(path: pathlib.Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise SystemExit(f"{path}: expected a JSON object")
    return payload


def write_object(path: pathlib.Path, payload: dict[str, Any]) -> None:
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def authorize(state_dir: pathlib.Path, request_id: str) -> dict[str, Any]:
    devices_dir = state_dir / "devices"
    pending_path = devices_dir / "pending.json"
    paired_path = devices_dir / "paired.json"
    auth_path = state_dir / "identity" / "device-auth.json"
    pending = load_object(pending_path)
    paired = load_object(paired_path)
    auth = load_object(auth_path)

    request = pending.get(request_id)
    if not isinstance(request, dict):
        raise SystemExit(f"pending OpenClaw request not found: {request_id}")
    device_id = request.get("deviceId")
    device = paired.get(device_id) if isinstance(device_id, str) else None
    if not isinstance(device, dict):
        raise SystemExit("scope upgrade is not for an already paired device")
    if request.get("role") != "operator" or device.get("role") != "operator":
        raise SystemExit("only operator CLI scope upgrades are supported")
    if request.get("publicKey") != device.get("publicKey"):
        raise SystemExit("pending request public key does not match the paired device")
    if request.get("clientId") != "cli" or request.get("clientMode") != "cli":
        raise SystemExit("pending request is not from the OpenClaw CLI")

    requested = request.get("scopes")
    if not isinstance(requested, list) or not requested:
        raise SystemExit("pending request has no scopes")
    requested_scopes = {scope for scope in requested if isinstance(scope, str)}
    if requested_scopes != set(requested) or not requested_scopes <= ALLOWED_OPERATOR_SCOPES:
        raise SystemExit(f"refusing unsupported operator scopes: {sorted(requested_scopes)}")

    approved = set(device.get("approvedScopes") or device.get("scopes") or [])
    updated_scopes = sorted(approved | requested_scopes)
    device["approvedScopes"] = updated_scopes
    device["scopes"] = updated_scopes
    role_token = (device.get("tokens") or {}).get("operator")
    if not isinstance(role_token, dict) or not isinstance(role_token.get("token"), str):
        raise SystemExit("paired operator token is missing")
    role_token["scopes"] = updated_scopes

    if auth.get("deviceId") != device_id:
        raise SystemExit("local CLI identity does not match the pending device")
    auth_token = (auth.get("tokens") or {}).get("operator")
    if not isinstance(auth_token, dict) or auth_token.get("token") != role_token.get("token"):
        raise SystemExit("local CLI operator token does not match the paired device")
    auth_token["scopes"] = updated_scopes

    del pending[request_id]
    write_object(paired_path, paired)
    write_object(auth_path, auth)
    write_object(pending_path, pending)
    return {
        "authorized": True,
        "requestId": request_id,
        "deviceId": device_id,
        "approvedScopes": updated_scopes,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", required=True, type=pathlib.Path)
    parser.add_argument("--request-id", required=True)
    args = parser.parse_args()
    print(json.dumps(authorize(args.state_dir, args.request_id), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
