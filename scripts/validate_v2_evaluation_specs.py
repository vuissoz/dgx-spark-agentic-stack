#!/usr/bin/env python3
"""Validate the initial v2 evaluation spec scaffold.

The files use JSON-subset YAML so this check has no external dependency.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]

SPEC_FILES = {
    "capabilities": Path("evaluation/spec/capabilities.yaml"),
    "architecture": Path("evaluation/spec/architecture.yaml"),
    "metrics": Path("evaluation/spec/metrics.yaml"),
    "promotion": Path("evaluation/spec/promotion.yaml"),
    "recovery": Path("evaluation/spec/recovery.yaml"),
    "retention": Path("evaluation/spec/retention.yaml"),
    "visible_corpus": Path("evaluation/corpora/visible/v2-walking-skeleton-v0/manifest.yaml"),
    "engineering_corpus": Path("evaluation/tasks/engineering/v2-changeability-v0/manifest.yaml"),
}

WALKING_SKELETON_JOURNEYS = {
    "bootstrap-doctor",
    "codex-repo-change",
    "context-isolation",
    "model-backend-failure",
    "snapshot-restore-rollback",
}

P0_GATE_IDS = {
    "p0-no-secret-or-data-leak",
    "p0-single-source-of-truth",
    "p0-recovery-proven",
    "p0-no-direct-backend-or-docker-sock",
    "p0-audit-correlated",
}

VALID_CLASSES = {"P0", "P1", "P2"}


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_json_subset_yaml(path: Path) -> dict[str, Any]:
    full_path = REPO_ROOT / path
    if not full_path.is_file():
        fail(f"missing required v2 evaluation spec: {path}")
    try:
        data = json.loads(full_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"{path} must remain JSON-subset YAML: {exc}")
    if not isinstance(data, dict):
        fail(f"{path} must contain a top-level object")
    if not isinstance(data.get("schema_version"), str) or not data["schema_version"].startswith("v2-"):
        fail(f"{path} must define schema_version starting with v2-")
    return data


def require_non_empty_string(item: dict[str, Any], key: str, context: str) -> None:
    if not isinstance(item.get(key), str) or not item[key].strip():
        fail(f"{context} must define non-empty string field '{key}'")


def validate_capabilities(data: dict[str, Any]) -> set[str]:
    capabilities = data.get("capabilities")
    if not isinstance(capabilities, list) or not capabilities:
        fail("capabilities spec must define at least one capability")

    ids: set[str] = set()
    p0_count = 0
    for item in capabilities:
        if not isinstance(item, dict):
            fail("each capability must be an object")
        context = f"capability {item.get('capability_id', '<missing>')}"
        for key in ("capability_id", "description", "class", "owner", "justification", "oracle", "corpus", "retirement_rule"):
            require_non_empty_string(item, key, context)
        capability_id = item["capability_id"]
        if capability_id in ids:
            fail(f"duplicate capability_id: {capability_id}")
        ids.add(capability_id)
        if item["class"] not in VALID_CLASSES:
            fail(f"{context} has invalid class {item['class']!r}")
        if item["class"] == "P0":
            p0_count += 1
        if not isinstance(item.get("metrics"), list) or not item["metrics"]:
            fail(f"{context} must list metrics")
        if not isinstance(item.get("dependencies"), list):
            fail(f"{context} dependencies must be a list")

    if p0_count < 3:
        fail("capabilities spec must include at least three P0 capabilities for the walking skeleton")
    return ids


def validate_visible_corpus(data: dict[str, Any], capability_ids: set[str]) -> None:
    journeys = data.get("journeys")
    if not isinstance(journeys, list):
        fail("visible corpus must define journeys")
    journey_ids = {item.get("journey_id") for item in journeys if isinstance(item, dict)}
    if journey_ids != WALKING_SKELETON_JOURNEYS:
        fail(f"visible corpus journeys must match {sorted(WALKING_SKELETON_JOURNEYS)}")
    for item in journeys:
        if not isinstance(item, dict):
            fail("each visible journey must be an object")
        context = f"journey {item.get('journey_id', '<missing>')}"
        for key in ("journey_id", "capability_id", "class", "oracle"):
            require_non_empty_string(item, key, context)
        if item["class"] not in VALID_CLASSES:
            fail(f"{context} has invalid class {item['class']!r}")
        if item["capability_id"] not in capability_ids:
            fail(f"{context} references unknown capability_id {item['capability_id']!r}")


def validate_promotion(data: dict[str, Any]) -> None:
    gates = data.get("mandatory_gates")
    if not isinstance(gates, list):
        fail("promotion spec must define mandatory_gates")
    gate_ids = {item.get("gate_id") for item in gates if isinstance(item, dict)}
    missing = P0_GATE_IDS - gate_ids
    if missing:
        fail(f"promotion spec is missing P0 gates: {sorted(missing)}")
    for item in gates:
        if not isinstance(item, dict):
            fail("each promotion gate must be an object")
        context = f"gate {item.get('gate_id', '<missing>')}"
        for key in ("gate_id", "class", "description"):
            require_non_empty_string(item, key, context)
        if item["class"] != "P0":
            fail(f"{context} must be class P0")


def validate_architecture(data: dict[str, Any]) -> None:
    boundaries = data.get("boundaries")
    truths = data.get("mutable_sources_of_truth")
    forbidden = data.get("forbidden_patterns")
    if not isinstance(boundaries, list) or len(boundaries) < 3:
        fail("architecture spec must define at least three boundaries")
    if not isinstance(truths, list) or len(truths) < 5:
        fail("architecture spec must define mutable sources of truth")
    if not isinstance(forbidden, list) or not forbidden:
        fail("architecture spec must define forbidden patterns")


def validate_engineering_corpus(data: dict[str, Any]) -> None:
    tasks = data.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        fail("engineering corpus must define tasks")
    tiers = {item.get("tier") for item in tasks if isinstance(item, dict)}
    if not {"quick", "complete"}.issubset(tiers):
        fail("engineering corpus must include quick and complete tasks")
    for item in tasks:
        if not isinstance(item, dict):
            fail("each engineering task must be an object")
        context = f"engineering task {item.get('task_id', '<missing>')}"
        for key in ("task_id", "tier", "class", "oracle"):
            require_non_empty_string(item, key, context)
        if item["class"] not in VALID_CLASSES:
            fail(f"{context} has invalid class {item['class']!r}")


def main() -> int:
    loaded = {name: load_json_subset_yaml(path) for name, path in SPEC_FILES.items()}
    capability_ids = validate_capabilities(loaded["capabilities"])
    validate_architecture(loaded["architecture"])
    validate_promotion(loaded["promotion"])
    validate_visible_corpus(loaded["visible_corpus"], capability_ids)
    validate_engineering_corpus(loaded["engineering_corpus"])

    for name in ("metrics", "recovery", "retention"):
        if len(loaded[name]) < 3:
            fail(f"{name} spec is too thin to be useful")

    print("OK: v2 evaluation specs validated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
