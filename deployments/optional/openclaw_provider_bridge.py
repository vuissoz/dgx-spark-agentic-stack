#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
from typing import Any


def now_ts() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def env_flag(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def load_json(path: pathlib.Path, *, default: dict[str, Any] | None = None) -> dict[str, Any]:
    if not path.exists():
        return {} if default is None else json.loads(json.dumps(default))
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{path}: invalid JSON ({exc})") from exc
    if not isinstance(payload, dict):
        raise SystemExit(f"{path}: expected a JSON object")
    return payload


def _render_json(payload: dict[str, Any]) -> str:
    return json.dumps(payload, indent=2, sort_keys=False) + "\n"


def write_json(path: pathlib.Path, payload: dict[str, Any], *, mode: int = 0o640) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rendered = _render_json(payload)
    if path.exists():
        try:
            current = path.read_text(encoding="utf-8")
        except OSError:
            current = None
        else:
            if current == rendered:
                try:
                    os.chmod(path, mode)
                except OSError:
                    pass
                return
    fd, tmp_name = tempfile.mkstemp(prefix=f"{path.name}.", dir=str(path.parent))
    tmp_path = pathlib.Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(rendered)
        os.chmod(tmp_path, mode)
        tmp_path.replace(path)
    finally:
        if tmp_path.exists():
            tmp_path.unlink(missing_ok=True)


def read_token_file(path_value: str) -> str:
    path = pathlib.Path(path_value)
    if not path.exists() or not path.is_file():
        return ""
    return path.read_text(encoding="utf-8").strip()


def secret_ref(env_name: str) -> dict[str, str]:
    return {"source": "env", "provider": "default", "id": env_name}


def resolve_openclaw_wrapper() -> str:
    candidate = os.environ.get("OPENCLAW_WRAPPER_BIN", "").strip() or "openclaw"
    return candidate


def run_openclaw_command(argv: list[str], *, timeout_sec: int = 180) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.setdefault("OPENCLAW_CAPTURE_LAYER_STATE_ON_EXIT", "0")
    return subprocess.run(
        argv,
        check=False,
        capture_output=True,
        env=env,
        text=True,
        timeout=timeout_sec,
    )


def plugin_records() -> list[dict[str, Any]]:
    proc = run_openclaw_command([resolve_openclaw_wrapper(), "plugins", "list", "--json", "--verbose"], timeout_sec=60)
    if proc.returncode != 0:
        return []
    text = proc.stdout.strip()
    if not text:
        return []
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return []
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        entries = payload.get("plugins")
        if isinstance(entries, list):
            return [item for item in entries if isinstance(item, dict)]
    return []


def plugin_matches(entry: dict[str, Any], needle: str) -> bool:
    lowered = needle.lower()
    for key in ("id", "name", "packageName", "installSpec", "sourcePath", "installPath"):
        value = entry.get(key)
        if isinstance(value, str) and lowered in value.lower():
            return True
    return False


def ensure_whatsapp_plugin(plugin_spec: str) -> tuple[bool, str]:
    for entry in plugin_records():
        if plugin_matches(entry, "whatsapp") or plugin_matches(entry, plugin_spec):
            return True, "already_installed"

    proc = run_openclaw_command([resolve_openclaw_wrapper(), "plugins", "install", "--pin", plugin_spec], timeout_sec=240)
    if proc.returncode != 0:
        summary = (proc.stderr or proc.stdout or f"exit {proc.returncode}").strip().splitlines()
        return False, summary[-1] if summary else f"exit {proc.returncode}"

    for entry in plugin_records():
        if plugin_matches(entry, "whatsapp") or plugin_matches(entry, plugin_spec):
            return True, "installed"
    return False, "install_completed_but_plugin_not_detected"


def build_bridge_config() -> tuple[dict[str, Any], dict[str, Any]]:
    channels: dict[str, Any] = {}
    status: dict[str, Any] = {
        "ready": True,
        "synced_at": now_ts(),
        "providers": {},
        "warnings": [],
    }

    telegram_token = read_token_file(os.environ.get("OPENCLAW_PROVIDER_BRIDGE_TELEGRAM_TOKEN_FILE", "/run/secrets/telegram.bot_token"))
    channels["telegram"] = {
        "enabled": True,
        "botToken": secret_ref("TELEGRAM_BOT_TOKEN"),
    } if telegram_token else None
    status["providers"]["telegram"] = {
        "configured": bool(telegram_token),
        "mode": "long-polling",
        "secret_file": os.environ.get("OPENCLAW_PROVIDER_BRIDGE_TELEGRAM_TOKEN_FILE", "/run/secrets/telegram.bot_token"),
    }

    discord_token = read_token_file(os.environ.get("OPENCLAW_PROVIDER_BRIDGE_DISCORD_TOKEN_FILE", "/run/secrets/discord.bot_token"))
    channels["discord"] = {
        "enabled": True,
        "token": secret_ref("DISCORD_BOT_TOKEN"),
    } if discord_token else None
    status["providers"]["discord"] = {
        "configured": bool(discord_token),
        "mode": "gateway",
        "secret_file": os.environ.get("OPENCLAW_PROVIDER_BRIDGE_DISCORD_TOKEN_FILE", "/run/secrets/discord.bot_token"),
    }

    slack_bot_token = read_token_file(os.environ.get("OPENCLAW_PROVIDER_BRIDGE_SLACK_BOT_TOKEN_FILE", "/run/secrets/slack.bot_token"))
    slack_app_token = read_token_file(os.environ.get("OPENCLAW_PROVIDER_BRIDGE_SLACK_APP_TOKEN_FILE", "/run/secrets/slack.app_token"))
    slack_signing_secret = read_token_file(
        os.environ.get("OPENCLAW_PROVIDER_BRIDGE_SLACK_SIGNING_SECRET_FILE", "/run/secrets/slack.signing_secret")
    )
    if slack_bot_token and slack_app_token:
        channels["slack"] = {
            "enabled": True,
            "mode": "socket",
            "botToken": secret_ref("SLACK_BOT_TOKEN"),
            "appToken": secret_ref("SLACK_APP_TOKEN"),
        }
        status["providers"]["slack"] = {
            "configured": True,
            "mode": "socket",
            "secret_files": {
                "bot": os.environ.get("OPENCLAW_PROVIDER_BRIDGE_SLACK_BOT_TOKEN_FILE", "/run/secrets/slack.bot_token"),
                "app": os.environ.get("OPENCLAW_PROVIDER_BRIDGE_SLACK_APP_TOKEN_FILE", "/run/secrets/slack.app_token"),
            },
        }
    elif slack_bot_token and slack_signing_secret:
        channels["slack"] = {
            "enabled": True,
            "mode": "http",
            "botToken": secret_ref("SLACK_BOT_TOKEN"),
            "signingSecret": secret_ref("SLACK_SIGNING_SECRET"),
        }
        status["providers"]["slack"] = {
            "configured": True,
            "mode": "http",
            "secret_files": {
                "bot": os.environ.get("OPENCLAW_PROVIDER_BRIDGE_SLACK_BOT_TOKEN_FILE", "/run/secrets/slack.bot_token"),
                "signing": os.environ.get(
                    "OPENCLAW_PROVIDER_BRIDGE_SLACK_SIGNING_SECRET_FILE",
                    "/run/secrets/slack.signing_secret",
                ),
            },
        }
    else:
        if slack_bot_token or slack_app_token or slack_signing_secret:
            status["warnings"].append(
                "slack secrets are incomplete; provide SLACK_BOT_TOKEN with either SLACK_APP_TOKEN (socket) or SLACK_SIGNING_SECRET (http)"
            )
        status["providers"]["slack"] = {
            "configured": False,
            "mode": "socket" if slack_bot_token or slack_app_token else "",
            "secret_files": {
                "bot": os.environ.get("OPENCLAW_PROVIDER_BRIDGE_SLACK_BOT_TOKEN_FILE", "/run/secrets/slack.bot_token"),
                "app": os.environ.get("OPENCLAW_PROVIDER_BRIDGE_SLACK_APP_TOKEN_FILE", "/run/secrets/slack.app_token"),
                "signing": os.environ.get(
                    "OPENCLAW_PROVIDER_BRIDGE_SLACK_SIGNING_SECRET_FILE",
                    "/run/secrets/slack.signing_secret",
                ),
            },
        }

    whatsapp_enabled = env_flag("OPENCLAW_PROVIDER_BRIDGE_WHATSAPP_ENABLE", False)
    whatsapp_plugin_spec = os.environ.get("OPENCLAW_PROVIDER_BRIDGE_WHATSAPP_PLUGIN_SPEC", "@openclaw/whatsapp").strip()
    whatsapp_status: dict[str, Any] = {
        "configured": False,
        "enabled": whatsapp_enabled,
        "plugin": whatsapp_plugin_spec,
    }
    if whatsapp_enabled:
        ok, reason = ensure_whatsapp_plugin(whatsapp_plugin_spec)
        whatsapp_status["configured"] = ok
        whatsapp_status["plugin_status"] = reason
        if ok:
            channels["whatsapp"] = {"enabled": True}
        else:
            status["warnings"].append(f"whatsapp plugin bootstrap failed: {reason}")
            status["ready"] = False
    status["providers"]["whatsapp"] = whatsapp_status

    normalized_channels = {key: value for key, value in channels.items() if isinstance(value, dict)}
    payload: dict[str, Any] = {"_agentic": {"generated_at": status["synced_at"], "managed_by": "openclaw-provider-bridge"}}
    if normalized_channels:
        payload["channels"] = normalized_channels
    return payload, status


def sync_once(bridge_file: pathlib.Path, status_file: pathlib.Path) -> int:
    payload, status = build_bridge_config()
    write_json(bridge_file, payload, mode=0o640)
    write_json(status_file, status, mode=0o640)
    return 0 if status.get("ready") is True else 1


def main() -> int:
    bridge_file = pathlib.Path(
        os.environ.get("OPENCLAW_PROVIDER_BRIDGE_FILE", "/config/bridge/openclaw.provider-bridge.json")
    )
    status_file = pathlib.Path(
        os.environ.get("OPENCLAW_PROVIDER_BRIDGE_STATUS_FILE", "/state/provider-bridge-status.json")
    )
    interval_sec = float(os.environ.get("OPENCLAW_PROVIDER_BRIDGE_SYNC_INTERVAL_SEC", "30") or 30)

    last_rc = 0
    while True:
        try:
            last_rc = sync_once(bridge_file, status_file)
        except subprocess.TimeoutExpired as exc:
            status = {"ready": False, "synced_at": now_ts(), "providers": {}, "warnings": [f"provider sync timed out: {exc}"]}
            write_json(status_file, status, mode=0o640)
            last_rc = 1
        except Exception as exc:  # pragma: no cover - defensive runtime guard
            status = {"ready": False, "synced_at": now_ts(), "providers": {}, "warnings": [str(exc)]}
            write_json(status_file, status, mode=0o640)
            last_rc = 1

        sys.stdout.flush()
        sys.stderr.flush()
        time.sleep(max(interval_sec, 5.0))

    return last_rc


if __name__ == "__main__":
    sys.exit(main())
