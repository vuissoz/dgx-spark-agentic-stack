#!/usr/bin/env python3
import argparse
import json
import pathlib
import sys


MUTABLE_RUNTIME_KEYS = {
    "AGENTIC_CODEX_CLI_NPM_SPEC": "@latest",
    "AGENTIC_CLAUDE_CODE_NPM_SPEC": "@latest",
    "AGENTIC_OPENCODE_NPM_SPEC": "@latest",
    "AGENTIC_PI_CODING_AGENT_NPM_SPEC": "@latest",
    "AGENTIC_OPENCLAW_INSTALL_VERSION": "latest",
}

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_ROOTLESS_BOOTSTRAP_WARNING = 2


def image_is_mutable(ref: str) -> bool:
    if not ref or "@sha256:" in ref:
        return False
    if ref.startswith("agentic/") or ref.endswith(":local"):
        return False
    base = ref.split("@", 1)[0]
    last_slash = base.rfind("/")
    last_colon = base.rfind(":")
    if last_colon <= last_slash:
        return True
    return base.endswith(":latest")


def load_release_reason(meta_path: pathlib.Path) -> str:
    if not meta_path.is_file():
        return ""
    for raw_line in meta_path.read_text(encoding="utf-8").splitlines():
        if raw_line.startswith("reason="):
            return raw_line.split("=", 1)[1].strip()
    return ""


def validate_resolution_manifest(resolution_path: pathlib.Path) -> list[str]:
    messages: list[str] = []
    try:
        payload = json.loads(resolution_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return [f"latest resolution manifest is unreadable: {exc}"]

    runtime_inputs = payload.get("runtime_inputs")
    docker_images = payload.get("docker_images")
    if not isinstance(runtime_inputs, list) or not isinstance(docker_images, list):
        return ["latest resolution manifest has an invalid schema"]

    for item in runtime_inputs:
        requested = str(item.get("requested") or "")
        resolved = str(item.get("resolved") or "")
        if requested.endswith("@latest") or requested == "latest":
            if not resolved or resolved == requested or resolved.endswith("@latest") or resolved == "latest":
                messages.append(
                    "runtime latest value is not deterministically resolved "
                    f"({item.get('env', 'unknown')}: {requested} -> {resolved or '<empty>'})"
                )

    for item in docker_images:
        requested = str(item.get("requested") or "")
        resolved = str(item.get("resolved") or "")
        service = str(item.get("service") or "unknown")
        if image_is_mutable(requested) and image_is_mutable(resolved):
            messages.append(
                f"service {service} still uses a mutable image after update ({requested} -> {resolved})"
            )

    return messages


def find_unresolved_latest_without_manifest(
    images_path: pathlib.Path, runtime_env_path: pathlib.Path
) -> list[str]:
    messages: list[str] = []

    if images_path.is_file():
        try:
            images = json.loads(images_path.read_text(encoding="utf-8"))
        except Exception as exc:
            messages.append(f"images manifest is unreadable: {exc}")
        else:
            if not isinstance(images, list):
                messages.append("images manifest has an invalid schema")
            else:
                for item in images:
                    service = str(item.get("service") or "unknown")
                    configured = str(item.get("configured_image") or "")
                    if image_is_mutable(configured):
                        messages.append(
                            "active release has no latest-resolution.json and "
                            f"service {service} still points to mutable image {configured}"
                        )

    if runtime_env_path.is_file():
        for raw_line in runtime_env_path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            expected = MUTABLE_RUNTIME_KEYS.get(key)
            if expected and value.strip().endswith(expected):
                messages.append(
                    "active release has no latest-resolution.json and "
                    f"runtime input {key} still requests {value.strip()}"
                )

    return messages


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--images", required=True)
    parser.add_argument("--runtime-env", required=True)
    parser.add_argument("--latest-resolution", required=True)
    parser.add_argument("--release-meta", required=True)
    parser.add_argument("--profile", required=True, choices=("strict-prod", "rootless-dev"))
    args = parser.parse_args()

    images_path = pathlib.Path(args.images)
    runtime_env_path = pathlib.Path(args.runtime_env)
    resolution_path = pathlib.Path(args.latest_resolution)
    release_meta_path = pathlib.Path(args.release_meta)

    if resolution_path.is_file():
        messages = validate_resolution_manifest(resolution_path)
        if messages:
            print("\n".join(messages))
            return EXIT_FAIL
        return EXIT_OK

    messages = find_unresolved_latest_without_manifest(images_path, runtime_env_path)
    if not messages:
        return EXIT_OK

    release_reason = load_release_reason(release_meta_path)
    if args.profile == "rootless-dev" and release_reason == "up-auto-bootstrap":
        for message in messages:
            print(f"rootless-dev bootstrap release is not fully traced yet: {message}")
        print(
            "rootless-dev first-up may continue; run 'agent update' after the first successful "
            "startup to materialize deterministic latest digests for rollback/audit."
        )
        return EXIT_ROOTLESS_BOOTSTRAP_WARNING

    print("\n".join(messages))
    return EXIT_FAIL


if __name__ == "__main__":
    raise SystemExit(main())
