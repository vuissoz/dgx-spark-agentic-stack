#!/usr/bin/env python3
"""Run and validate the local n8n/Ollama doctor workflow without exposing n8n."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

WORKFLOW_NAME = "DOCTOR - n8n local Ollama validation"
WORKFLOW_ID = "DrN8nOllamaV001"
FINAL_NODE_NAME = "DOCTOR PASS"
EXPECTED_RESULT = {
    "success": True,
    "doctor_status": "PASS",
    "test_id": "N8N-DOCTOR-OLLAMA-001",
    "n8n_execution": "OK",
    "javascript_runtime": "OK",
    "ollama_connection": "OK",
    "qwen_inference": "OK",
    "json_parsing": "OK",
    "response_validation": "OK",
    "backend": "ollama",
    "model": "qwen3.8:27b",
}


def fail(message: str) -> None:
    raise RuntimeError(message)


def load_workflow(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"invalid n8n doctor workflow template: {exc}")
    if not isinstance(payload, dict):
        fail("n8n doctor workflow template must be a JSON object")
    return payload


def validate_template(path: Path) -> None:
    workflow = load_workflow(path)
    if workflow.get("id") != WORKFLOW_ID:
        fail(f"workflow id must be '{WORKFLOW_ID}'")
    if workflow.get("name") != WORKFLOW_NAME:
        fail(f"workflow name must be '{WORKFLOW_NAME}'")
    nodes = workflow.get("nodes")
    if not isinstance(nodes, list):
        fail("workflow nodes must be a list")
    names = {node.get("name") for node in nodes if isinstance(node, dict)}
    required = {
        "Manual Trigger",
        "Prepare Doctor Test Data",
        "Test JavaScript Runtime",
        "Ollama Qwen Local Inference",
        "Validate Ollama Response",
        FINAL_NODE_NAME,
    }
    missing = required - names
    if missing:
        fail(f"workflow is missing required nodes: {', '.join(sorted(missing))}")
    expected_connections = {
        "Manual Trigger": "Prepare Doctor Test Data",
        "Prepare Doctor Test Data": "Test JavaScript Runtime",
        "Test JavaScript Runtime": "Ollama Qwen Local Inference",
        "Ollama Qwen Local Inference": "Validate Ollama Response",
        "Validate Ollama Response": FINAL_NODE_NAME,
    }
    connections = workflow.get("connections")
    if not isinstance(connections, dict):
        fail("workflow connections must be an object")
    for source, target in expected_connections.items():
        try:
            connected = connections[source]["main"][0][0]["node"]
        except (KeyError, IndexError, TypeError):
            fail(f"workflow connection is missing: {source} -> {target}")
        if connected != target:
            fail(f"workflow connection must be {source} -> {target}")
    forbidden_types = ("agent", "tool", "executeCommand", "readWriteFile")
    for node in nodes:
        if not isinstance(node, dict):
            continue
        node_type = str(node.get("type", "")).lower()
        if any(token in node_type for token in forbidden_types):
            fail(f"workflow contains forbidden node type: {node.get('type')}")
    http_node = next(node for node in nodes if node.get("name") == "Ollama Qwen Local Inference")
    if http_node.get("type") != "n8n-nodes-base.httpRequest":
        fail("Ollama inference must use the local HTTP Request node")
    body = str((http_node.get("parameters") or {}).get("jsonBody", ""))
    if "qwen3.8:27b" not in body:
        fail("Ollama inference must use model qwen3.8:27b")
    if "ollama-gate:11435" not in str((http_node.get("parameters") or {}).get("url", "")):
        fail("Ollama inference must target ollama-gate")
    if "$env" in json.dumps(workflow, ensure_ascii=False):
        fail("workflow must not depend on n8n environment-variable access")


def parse_json_candidates(text: str) -> list[Any]:
    decoder = json.JSONDecoder()
    values: list[Any] = []
    for index, char in enumerate(text):
        if char not in "[{":
            continue
        try:
            value, _ = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        values.append(value)
    return values


def find_expected_result(value: Any) -> dict[str, Any] | None:
    if isinstance(value, dict):
        if value == EXPECTED_RESULT:
            return value
        for child in value.values():
            found = find_expected_result(child)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_expected_result(child)
            if found is not None:
                return found
    return None


def validate_execution_output(text: str) -> None:
    for candidate in parse_json_candidates(text):
        if find_expected_result(candidate) is not None:
            return
    fail("n8n doctor workflow did not produce the exact DOCTOR PASS JSON contract")


def stream_template_to_container(template: Path, container: str, container_path: str) -> None:
    subprocess.run(
        ["docker", "exec", "-i", container, "sh", "-c", f"umask 077; dd of={container_path} status=none"],
        check=True,
        input=template.read_text(encoding="utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
    )


def install_workflow(template: Path, container: str) -> None:
    container_path = "/tmp/agentic-n8n-doctor-workflow.json"
    try:
        stream_template_to_container(template, container, container_path)
        completed = subprocess.run(
            ["docker", "exec", container, "n8n", "import:workflow", f"--input={container_path}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60,
            check=False,
        )
    except subprocess.TimeoutExpired:
        fail("n8n doctor workflow installation exceeded timeout (60s)")
    except (OSError, subprocess.SubprocessError) as exc:
        fail(f"unable to install n8n doctor workflow: {exc}")
    finally:
        subprocess.run(
            ["docker", "exec", container, "sh", "-c", f"rm -f {container_path}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=15,
        )
    if completed.returncode != 0:
        tail = completed.stdout.strip().splitlines()[-1:] or ["no n8n output"]
        fail(f"n8n doctor workflow installation failed: {tail[0]}")


def run_workflow(container: str, timeout_seconds: int) -> None:
    try:
        completed = subprocess.run(
            [
                "docker", "exec",
                "-e", "N8N_RUNNERS_BROKER_PORT=5680",
                "-e", "N8N_RUNNERS_BROKER_LISTEN_ADDRESS=127.0.0.1",
                container,
                "n8n", "execute", f"--id={WORKFLOW_ID}", "--rawOutput",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired:
        fail(f"n8n doctor workflow exceeded timeout ({timeout_seconds}s)")
    except (OSError, subprocess.SubprocessError) as exc:
        fail(f"unable to launch n8n doctor workflow: {exc}")
    if completed.returncode != 0:
        fail("n8n doctor workflow execution failed; inspect './agent logs n8n'")
    validate_execution_output(completed.stdout)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workflow", type=Path, required=True)
    parser.add_argument("--container")
    parser.add_argument("--timeout-seconds", type=int, default=300)
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--validate-template", action="store_true")
    parser.add_argument("--validate-output-file", type=Path)
    args = parser.parse_args()
    try:
        validate_template(args.workflow)
        if args.validate_output_file is not None:
            validate_execution_output(args.validate_output_file.read_text(encoding="utf-8"))
        elif args.install:
            if not args.container:
                fail("--container is required when installing the workflow")
            install_workflow(args.workflow, args.container)
        elif not args.validate_template:
            if not args.container:
                fail("--container is required when executing the workflow")
            if args.timeout_seconds < 10:
                fail("--timeout-seconds must be at least 10")
            run_workflow(args.container, args.timeout_seconds)
        print("n8n local workflow: PASS")
        return 0
    except RuntimeError as exc:
        print(f"n8n local workflow: FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
