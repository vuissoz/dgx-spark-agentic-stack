#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import pathlib
import subprocess
import sys
import urllib.parse
import urllib.request


MANAGED_RUNTIME_INPUTS = (
    {
        "env": "AGENTIC_CODEX_CLI_NPM_SPEC",
        "arg": "CODEX_CLI_NPM_SPEC",
        "component": "codex-cli",
        "resolver": "npm_spec",
    },
    {
        "env": "AGENTIC_CLAUDE_CODE_NPM_SPEC",
        "arg": "CLAUDE_CODE_NPM_SPEC",
        "component": "claude-code",
        "resolver": "npm_spec",
    },
    {
        "env": "AGENTIC_OPENCODE_NPM_SPEC",
        "arg": "OPENCODE_NPM_SPEC",
        "component": "opencode",
        "resolver": "npm_spec",
    },
    {
        "env": "AGENTIC_PI_CODING_AGENT_NPM_SPEC",
        "arg": "PI_CODING_AGENT_NPM_SPEC",
        "component": "pi-coding-agent",
        "resolver": "npm_spec",
    },
    {
        "env": "AGENTIC_OPENCLAW_INSTALL_VERSION",
        "arg": "OPENCLAW_INSTALL_VERSION",
        "component": "openclaw-cli",
        "resolver": "npm_tag",
        "package": "openclaw",
    },
)


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def run(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if proc.returncode != 0:
        stderr = proc.stderr.strip()
        stdout = proc.stdout.strip()
        detail = stderr or stdout or f"exit={proc.returncode}"
        fail(f"command failed ({' '.join(cmd)}): {detail}")
    return proc.stdout


def split_npm_spec(spec: str) -> tuple[str, str]:
    if spec.startswith("@"):
        idx = spec.rfind("@")
        if idx <= 0:
            return spec, "latest"
        return spec[:idx], spec[idx + 1 :]
    if "@" not in spec:
        return spec, "latest"
    idx = spec.rfind("@")
    return spec[:idx], spec[idx + 1 :]


def fetch_npm_dist_tags(package: str) -> dict[str, str]:
    url = f"https://registry.npmjs.org/{urllib.parse.quote(package, safe='')}"
    try:
        with urllib.request.urlopen(url, timeout=20) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except Exception as exc:
        fail(f"unable to fetch npm metadata for {package}: {exc}")
    dist_tags = payload.get("dist-tags")
    if not isinstance(dist_tags, dict):
        fail(f"npm metadata for {package} does not expose dist-tags")
    return {str(key): str(value) for key, value in dist_tags.items()}


def resolve_npm_spec(requested: str) -> tuple[str, str | None]:
    package, version = split_npm_spec(requested)
    if version != "latest":
        return requested, None

    dist_tags = fetch_npm_dist_tags(package)
    resolved_version = dist_tags.get("latest")
    if not resolved_version:
        fail(f"npm package {package} has no 'latest' dist-tag")
    return f"{package}@{resolved_version}", resolved_version


def resolve_npm_tag(package: str, requested: str) -> tuple[str, str | None]:
    if requested != "latest":
        return requested, None
    dist_tags = fetch_npm_dist_tags(package)
    resolved_version = dist_tags.get("latest")
    if not resolved_version:
        fail(f"npm package {package} has no 'latest' dist-tag")
    return resolved_version, resolved_version


def resolve_runtime_inputs(compose_services: dict) -> tuple[list[dict], dict[str, str]]:
    entries: list[dict] = []
    resolved_env: dict[str, str] = {}

    for item in MANAGED_RUNTIME_INPUTS:
        env_key = item["env"]
        requested = os.environ.get(env_key, "").strip()
        if not requested:
            continue

        if item["resolver"] == "npm_spec":
            resolved, resolved_version = resolve_npm_spec(requested)
            requested_channel = "latest" if requested.endswith("@latest") or requested == split_npm_spec(requested)[0] else None
        else:
            resolved, resolved_version = resolve_npm_tag(str(item["package"]), requested)
            requested_channel = "latest" if requested == "latest" else None

        resolved_env[env_key] = resolved
        consumers = sorted(
            service_name
            for service_name, service_def in compose_services.items()
            if isinstance(service_def, dict)
            and isinstance(service_def.get("build"), dict)
            and isinstance(service_def["build"].get("args"), dict)
            and item["arg"] in service_def["build"]["args"]
        )
        entries.append(
            {
                "component": item["component"],
                "consumers": consumers,
                "env": env_key,
                "requested": requested,
                "requested_channel": requested_channel,
                "resolved": resolved,
                "resolved_version": resolved_version,
                "resolution_type": item["resolver"],
            }
        )

    return entries, resolved_env


def image_repo(ref: str) -> str:
    base = ref.split("@", 1)[0]
    last_slash = base.rfind("/")
    last_colon = base.rfind(":")
    if last_colon > last_slash:
        return base[:last_colon]
    return base


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


def resolve_image_digest(ref: str) -> str:
    run(["docker", "pull", ref])
    raw = run(["docker", "image", "inspect", "--format", "{{json .RepoDigests}}", ref]).strip()
    if not raw or raw == "null":
        fail(f"docker image {ref} does not expose any repo digest after pull")
    try:
        repo_digests = json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"unable to decode RepoDigests for {ref}: {exc}")
    if not isinstance(repo_digests, list) or not repo_digests:
        fail(f"docker image {ref} does not expose any repo digest after pull")
    repo_prefix = f"{image_repo(ref)}@sha256:"
    for digest in repo_digests:
        if isinstance(digest, str) and digest.startswith(repo_prefix):
            return digest
    for digest in repo_digests:
        if isinstance(digest, str) and "@sha256:" in digest:
            return digest
    fail(f"docker image {ref} does not expose a usable digest")


def resolve_docker_images(compose_services: dict) -> list[dict]:
    entries: list[dict] = []
    for service_name, service_def in sorted(compose_services.items()):
        if not isinstance(service_def, dict):
            continue
        requested = str(service_def.get("image") or "").strip()
        if not image_is_mutable(requested):
            continue
        resolved = resolve_image_digest(requested)
        entries.append(
            {
                "requested": requested,
                "requested_channel": "latest" if requested.endswith(":latest") else None,
                "resolution_type": "docker_digest",
                "resolved": resolved,
                "service": service_name,
            }
        )
    return entries


def load_compose_services(project_name: str, compose_files: list[str]) -> dict:
    cmd = ["docker", "compose", "--project-name", project_name]
    for compose_file in compose_files:
        cmd.extend(["-f", compose_file])
    cmd.extend(["config", "--format", "json"])
    try:
        payload = json.loads(run(cmd))
    except json.JSONDecodeError as exc:
        fail(f"unable to decode docker compose config output: {exc}")
    services = payload.get("services")
    if not isinstance(services, dict):
        fail("docker compose config did not return a services object")
    return services


def write_runtime_env(path: pathlib.Path, values: dict[str, str]) -> None:
    with path.open("w", encoding="utf-8") as fh:
        for key in sorted(values):
            fh.write(f"{key}={values[key]}\n")


def write_compose_override(path: pathlib.Path, docker_entries: list[dict]) -> None:
    with path.open("w", encoding="utf-8") as fh:
        if not docker_entries:
            fh.write("services: {}\n")
            return
        fh.write("services:\n")
        for entry in docker_entries:
            fh.write(f"  {entry['service']}:\n")
            fh.write(f"    image: {entry['resolved']}\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-name", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("-f", "--compose-file", action="append", dest="compose_files", default=[])
    args = parser.parse_args()

    if not args.compose_files:
        fail("at least one compose file is required")

    output_dir = pathlib.Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    compose_services = load_compose_services(args.project_name, args.compose_files)
    runtime_inputs, resolved_env = resolve_runtime_inputs(compose_services)
    docker_images = resolve_docker_images(compose_services)

    write_runtime_env(output_dir / "runtime.resolved.env", resolved_env)
    write_compose_override(output_dir / "compose.resolved.override.yml", docker_images)

    payload = {
        "schema_version": 1,
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "docker_images": docker_images,
        "runtime_inputs": runtime_inputs,
    }
    with (output_dir / "latest-resolution.json").open("w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
        fh.write("\n")


if __name__ == "__main__":
    main()
