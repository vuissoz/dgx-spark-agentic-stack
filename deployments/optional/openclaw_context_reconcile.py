#!/usr/bin/env python3
import argparse
import json
import math
from pathlib import Path
from typing import Any


DEFAULT_PROVIDER_ID = "custom-ollama-gate-11435"


def load_json(path: Path, *, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{path}: invalid JSON ({exc})") from exc


def write_json(path: Path, payload: Any, *, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(payload, indent=2, sort_keys=False) + "\n"
    current = None
    if path.exists():
      current = path.read_text(encoding="utf-8")
    if current == rendered:
        return
    tmp = path.with_name(f"{path.name}.tmp")
    tmp.write_text(rendered, encoding="utf-8")
    tmp.chmod(mode)
    tmp.replace(path)


def clamp_max_tokens(current: Any, context_window: int) -> int:
    if isinstance(current, int) and current > 0:
        return min(current, context_window)
    return min(4096, context_window)


def ensure_provider_model_registry(
    payload: dict[str, Any],
    *,
    provider_id: str,
    model_id: str,
    context_window: int,
) -> bool:
    changed = False
    providers = payload.setdefault("providers", {})
    if not isinstance(providers, dict):
        providers = {}
        payload["providers"] = providers
        changed = True

    provider = providers.setdefault(provider_id, {})
    if not isinstance(provider, dict):
        provider = {}
        providers[provider_id] = provider
        changed = True

    models = provider.setdefault("models", [])
    if not isinstance(models, list):
        models = []
        provider["models"] = models
        changed = True

    target = None
    for item in models:
        if isinstance(item, dict) and item.get("id") == model_id:
            target = item
            break
    if target is None:
        for item in models:
            if isinstance(item, dict):
                target = item
                break
    if target is None:
        target = {}
        models.append(target)
        changed = True

    expected_name = f"{model_id} (Custom Provider)"
    expected_max_tokens = clamp_max_tokens(target.get("maxTokens"), context_window)

    expected_fields = {
        "id": model_id,
        "name": expected_name,
        "contextWindow": context_window,
        "maxTokens": expected_max_tokens,
        "input": ["text"],
        "cost": {
            "input": 0,
            "output": 0,
            "cacheRead": 0,
            "cacheWrite": 0,
        },
        "reasoning": False,
    }
    if provider.get("api"):
        expected_fields["api"] = provider["api"]

    for key, value in expected_fields.items():
        if target.get(key) != value:
            target[key] = value
            changed = True
    return changed


def ensure_state_file(
    payload: dict[str, Any],
    *,
    provider_id: str,
    model_id: str,
    context_window: int,
) -> bool:
    changed = False
    models = payload.setdefault("models", {})
    if not isinstance(models, dict):
        models = {}
        payload["models"] = models
        changed = True
    providers = models.setdefault("providers", {})
    if not isinstance(providers, dict):
        providers = {}
        models["providers"] = providers
        changed = True
    provider_payload = {"providers": providers}
    if ensure_provider_model_registry(
        provider_payload,
        provider_id=provider_id,
        model_id=model_id,
        context_window=context_window,
    ):
        changed = True
    return changed


def recompute_session_usage(record: dict[str, Any], context_window: int) -> bool:
    changed = False
    total_tokens = record.get("totalTokens")
    if isinstance(total_tokens, (int, float)):
        total = int(total_tokens)
        remaining = max(context_window - total, 0)
        percent = math.floor((total * 100) / context_window) if context_window > 0 else None
        if record.get("remainingTokens") != remaining:
            record["remainingTokens"] = remaining
            changed = True
        if record.get("percentUsed") != percent:
            record["percentUsed"] = percent
            changed = True
    return changed


def ensure_sessions_file(
    payload: dict[str, Any],
    *,
    provider_id: str,
    model_id: str,
    context_window: int,
) -> bool:
    changed = False
    for session in payload.values():
        if not isinstance(session, dict):
            continue
        if session.get("modelProvider") != provider_id or session.get("model") != model_id:
            continue
        if session.get("contextTokens") != context_window:
            session["contextTokens"] = context_window
            changed = True
        if recompute_session_usage(session, context_window):
            changed = True
    return changed


def reconcile_paths(
    *,
    state_file: Path,
    state_dir: Path,
    provider_id: str,
    model_id: str,
    context_window: int,
) -> dict[str, int]:
    updated = {"state_files": 0, "model_registries": 0, "session_indexes": 0}

    state_payload = load_json(state_file, default={})
    if not isinstance(state_payload, dict):
        raise SystemExit(f"{state_file}: expected a JSON object")
    if ensure_state_file(
        state_payload,
        provider_id=provider_id,
        model_id=model_id,
        context_window=context_window,
    ):
        write_json(state_file, state_payload, mode=0o600)
        updated["state_files"] += 1

    for models_path in state_dir.glob(".openclaw/agents/*/agent/models.json"):
        payload = load_json(models_path, default={})
        if not isinstance(payload, dict):
            raise SystemExit(f"{models_path}: expected a JSON object")
        if ensure_provider_model_registry(
            payload,
            provider_id=provider_id,
            model_id=model_id,
            context_window=context_window,
        ):
            write_json(models_path, payload, mode=0o600)
            updated["model_registries"] += 1

    for sessions_path in state_dir.glob(".openclaw/agents/*/sessions/sessions.json"):
        payload = load_json(sessions_path, default={})
        if not isinstance(payload, dict):
            raise SystemExit(f"{sessions_path}: expected a JSON object")
        if ensure_sessions_file(
            payload,
            provider_id=provider_id,
            model_id=model_id,
            context_window=context_window,
        ):
            write_json(sessions_path, payload, mode=0o600)
            updated["session_indexes"] += 1

    return updated


def inspect_paths(
    *,
    state_file: Path,
    state_dir: Path,
    provider_id: str,
    model_id: str,
    context_window: int,
) -> list[str]:
    issues: list[str] = []

    def expect_model_registry(path: Path, payload: dict[str, Any]) -> None:
        providers = payload.get("providers")
        if not isinstance(providers, dict):
            issues.append(f"{path}: providers missing")
            return
        provider = providers.get(provider_id)
        if not isinstance(provider, dict):
            issues.append(f"{path}: provider {provider_id} missing")
            return
        models = provider.get("models")
        if not isinstance(models, list):
            issues.append(f"{path}: provider {provider_id} models missing")
            return
        target = None
        for item in models:
            if isinstance(item, dict) and item.get("id") == model_id:
                target = item
                break
        if target is None:
            issues.append(f"{path}: provider {provider_id} model {model_id} missing")
            return
        if target.get("contextWindow") != context_window:
            issues.append(
                f"{path}: provider {provider_id} model {model_id} contextWindow={target.get('contextWindow')} expected={context_window}"
            )

    state_payload = load_json(state_file, default={})
    if not isinstance(state_payload, dict):
        raise SystemExit(f"{state_file}: expected a JSON object")
    models = state_payload.get("models")
    if not isinstance(models, dict):
        issues.append(f"{state_file}: models missing")
    else:
        registry = {"providers": models.get("providers")}
        if isinstance(models.get("providers"), dict):
            expect_model_registry(state_file, registry)
        else:
            issues.append(f"{state_file}: models.providers missing")

    for models_path in state_dir.glob(".openclaw/agents/*/agent/models.json"):
        payload = load_json(models_path, default={})
        if not isinstance(payload, dict):
            raise SystemExit(f"{models_path}: expected a JSON object")
        expect_model_registry(models_path, payload)

    for sessions_path in state_dir.glob(".openclaw/agents/*/sessions/sessions.json"):
        payload = load_json(sessions_path, default={})
        if not isinstance(payload, dict):
            raise SystemExit(f"{sessions_path}: expected a JSON object")
        for key, session in payload.items():
            if not isinstance(session, dict):
                continue
            if session.get("modelProvider") != provider_id or session.get("model") != model_id:
                continue
            if session.get("contextTokens") != context_window:
                issues.append(
                    f"{sessions_path}: session {key} contextTokens={session.get('contextTokens')} expected={context_window}"
                )
    return issues


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Reconcile stack-managed OpenClaw context metadata")
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_common(subparser: argparse.ArgumentParser) -> None:
        subparser.add_argument("--state-file", type=Path, required=True)
        subparser.add_argument("--state-dir", type=Path, required=True)
        subparser.add_argument("--provider-id", default=DEFAULT_PROVIDER_ID)
        subparser.add_argument("--model-id", required=True)
        subparser.add_argument("--context-window", type=int, required=True)

    reconcile = subparsers.add_parser("reconcile")
    add_common(reconcile)

    check = subparsers.add_parser("check")
    add_common(check)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.context_window < 2048:
        raise SystemExit("--context-window must be >= 2048")

    if args.command == "reconcile":
        updated = reconcile_paths(
            state_file=args.state_file,
            state_dir=args.state_dir,
            provider_id=args.provider_id,
            model_id=args.model_id,
            context_window=args.context_window,
        )
        print(json.dumps(updated, sort_keys=True))
        return 0

    issues = inspect_paths(
        state_file=args.state_file,
        state_dir=args.state_dir,
        provider_id=args.provider_id,
        model_id=args.model_id,
        context_window=args.context_window,
    )
    if issues:
        print(json.dumps({"issues": issues}, sort_keys=True))
        return 1
    print(json.dumps({"issues": []}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
