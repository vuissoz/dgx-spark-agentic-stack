#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path
from typing import Any


STATUS_DIRS = ("pending", "approved", "denied", "expired")
DEFAULT_PENDING_TTL_SEC = 7 * 24 * 3600
DEFAULT_SESSION_TTL_SEC = 3600
DEFAULT_GLOBAL_TTL_SEC = 6 * 3600


def now_ts() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def epoch_now() -> int:
    return int(time.time())


def json_dumps(payload: Any) -> str:
    return json.dumps(payload, separators=(",", ":"), sort_keys=True)


def read_json_file(path: Path, fallback: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return fallback


def write_json_file_atomic(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json_dumps(payload), encoding="utf-8")
    tmp.replace(path)


def append_jsonl(path: str | Path | None, payload: dict[str, Any]) -> None:
    if not path:
        return
    log_path = Path(path)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as fh:
        fh.write(json_dumps(payload) + "\n")


def ensure_state_layout(state_dir: str | Path) -> Path:
    root = Path(state_dir)
    for name in STATUS_DIRS:
        (root / name).mkdir(parents=True, exist_ok=True)
    return root


def status_dir(root: Path, status: str) -> Path:
    if status not in STATUS_DIRS:
        raise ValueError(f"invalid approval status: {status}")
    return root / status


def record_path(root: Path, status: str, record_id: str) -> Path:
    return status_dir(root, status) / f"{record_id}.json"


def list_status_files(root: Path, status: str) -> list[Path]:
    base = status_dir(root, status)
    if not base.exists():
        return []
    return sorted(item for item in base.glob("*.json") if item.is_file())


def load_record(path: Path) -> dict[str, Any]:
    payload = read_json_file(path, {})
    if not isinstance(payload, dict):
        raise ValueError(f"invalid approval record: {path}")
    return payload


def find_record(root: Path, record_id: str, statuses: tuple[str, ...] = STATUS_DIRS) -> tuple[str, Path, dict[str, Any]] | None:
    for status in statuses:
        path = record_path(root, status, record_id)
        if path.exists():
            return status, path, load_record(path)
    return None


def unique_limited(items: list[str], value: str, *, limit: int = 8) -> list[str]:
    if not value:
        return items[:limit]
    normalized = [item for item in items if isinstance(item, str) and item]
    if value in normalized:
        normalized.remove(value)
    normalized.append(value)
    return normalized[-limit:]


def fingerprint(kind: str, value: str) -> str:
    digest = hashlib.sha256(f"{kind}\0{value}".encode("utf-8")).hexdigest()[:16]
    return f"apr-{digest}"


def iso_from_epoch(value: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(value))


def is_expired(record: dict[str, Any], now_epoch: int | None = None) -> bool:
    now_epoch = epoch_now() if now_epoch is None else now_epoch
    expires_at_epoch = int(record.get("expires_at_epoch", 0) or 0)
    return expires_at_epoch > 0 and expires_at_epoch <= now_epoch


def expire_record(
    root: Path,
    from_status: str,
    path: Path,
    record: dict[str, Any],
    *,
    audit_log: str | None = None,
    actor: str = "system",
    reason: str = "expired",
    now_epoch: int | None = None,
) -> dict[str, Any]:
    now_epoch = epoch_now() if now_epoch is None else now_epoch
    updated = dict(record)
    updated["status"] = "expired"
    updated["expired_from"] = from_status
    updated["expired_at"] = iso_from_epoch(now_epoch)
    updated["expired_at_epoch"] = now_epoch
    updated["expired_reason"] = reason
    updated["updated_at"] = iso_from_epoch(now_epoch)
    updated["updated_at_epoch"] = now_epoch
    updated["updated_by"] = actor
    dest = record_path(root, "expired", str(updated.get("id", path.stem)))
    write_json_file_atomic(dest, updated)
    path.unlink(missing_ok=True)
    append_jsonl(
        audit_log,
        {
            "ts": now_ts(),
            "module": "openclaw-approvals",
            "action": "expire",
            "decision": "allow",
            "approval_id": updated.get("id", ""),
            "kind": updated.get("kind", ""),
            "value": updated.get("value", ""),
            "scope": updated.get("scope", ""),
            "status_before": from_status,
            "reason": reason,
        },
    )
    return updated


def sweep_expired(
    state_dir: str | Path,
    *,
    audit_log: str | None = None,
    actor: str = "system",
    now_epoch: int | None = None,
) -> list[dict[str, Any]]:
    root = ensure_state_layout(state_dir)
    now_epoch = epoch_now() if now_epoch is None else now_epoch
    expired: list[dict[str, Any]] = []
    for status in ("pending", "approved", "denied"):
        for path in list_status_files(root, status):
            record = load_record(path)
            if not is_expired(record, now_epoch):
                continue
            expired.append(
                expire_record(
                    root,
                    status,
                    path,
                    record,
                    audit_log=audit_log,
                    actor=actor,
                    reason=str(record.get("expiry_reason", "ttl")),
                    now_epoch=now_epoch,
                )
            )
    return expired


def approval_counts(state_dir: str | Path) -> dict[str, int]:
    root = ensure_state_layout(state_dir)
    return {status: len(list_status_files(root, status)) for status in STATUS_DIRS}


def session_matches(record: dict[str, Any], session_id: str) -> bool:
    scope = str(record.get("scope", ""))
    if scope == "session":
        return bool(session_id) and session_id == str(record.get("session_id", ""))
    return True


def active_record_for_request(
    state_dir: str | Path,
    *,
    kind: str,
    value: str,
    session_id: str = "",
    audit_log: str | None = None,
) -> tuple[str, dict[str, Any]] | None:
    root = ensure_state_layout(state_dir)
    sweep_expired(root, audit_log=audit_log)
    record_id = fingerprint(kind, value)
    approved = find_record(root, record_id, ("approved",))
    if approved is not None:
        _status, _path, record = approved
        if session_matches(record, session_id):
            return "approved", record
    denied = find_record(root, record_id, ("denied",))
    if denied is not None:
        _status, _path, record = denied
        if session_matches(record, session_id):
            return "denied", record
    return None


def register_pending_request(
    state_dir: str | Path,
    *,
    kind: str,
    value: str,
    request_id: str,
    source: str,
    audit_log: str | None = None,
    session_id: str = "",
    model: str = "",
    metadata: dict[str, Any] | None = None,
    pending_ttl_sec: int = DEFAULT_PENDING_TTL_SEC,
) -> dict[str, Any]:
    root = ensure_state_layout(state_dir)
    sweep_expired(root, audit_log=audit_log)
    record_id = fingerprint(kind, value)
    existing = find_record(root, record_id, ("pending",))
    now_epoch = epoch_now()

    if existing is None:
        record = {
            "id": record_id,
            "status": "pending",
            "kind": kind,
            "value": value,
            "created_at": iso_from_epoch(now_epoch),
            "created_at_epoch": now_epoch,
            "first_seen_at": iso_from_epoch(now_epoch),
            "first_seen_at_epoch": now_epoch,
            "request_count": 0,
            "request_ids": [],
            "sessions": [],
            "models": [],
            "sources": [],
        }
    else:
        _status, _path, record = existing

    record["status"] = "pending"
    record["last_seen_at"] = iso_from_epoch(now_epoch)
    record["last_seen_at_epoch"] = now_epoch
    record["updated_at"] = iso_from_epoch(now_epoch)
    record["updated_at_epoch"] = now_epoch
    record["request_count"] = int(record.get("request_count", 0) or 0) + 1
    record["request_ids"] = unique_limited(list(record.get("request_ids", [])), request_id)
    record["sessions"] = unique_limited(list(record.get("sessions", [])), session_id)
    record["models"] = unique_limited(list(record.get("models", [])), model)
    record["sources"] = unique_limited(list(record.get("sources", [])), source)
    record["expires_at_epoch"] = now_epoch + max(1, int(pending_ttl_sec or DEFAULT_PENDING_TTL_SEC))
    record["expires_at"] = iso_from_epoch(int(record["expires_at_epoch"]))
    record["expiry_reason"] = "pending_ttl"
    if metadata:
        sanitized = {k: v for k, v in metadata.items() if v not in ("", None, [], {})}
        if sanitized:
            record["metadata"] = sanitized

    write_json_file_atomic(record_path(root, "pending", record_id), record)
    append_jsonl(
        audit_log,
        {
            "ts": now_ts(),
            "module": "openclaw-approvals",
            "action": "enqueue",
            "decision": "allow",
            "approval_id": record_id,
            "kind": kind,
            "value": value,
            "request_id": request_id,
            "session_id": session_id,
            "source": source,
            "status": "pending",
        },
    )
    return record


def _resolve_session_id(record: dict[str, Any], requested: str) -> str:
    requested = str(requested or "").strip()
    if requested:
        return requested
    sessions = [item for item in record.get("sessions", []) if isinstance(item, str) and item]
    if len(sessions) == 1:
        return sessions[0]
    raise ValueError("session-scoped decision requires --session-id when queue entry spans multiple sessions")


def move_record(
    root: Path,
    *,
    src_status: str,
    dest_status: str,
    record: dict[str, Any],
) -> dict[str, Any]:
    record_id = str(record.get("id", ""))
    if not record_id:
        raise ValueError("approval record is missing id")
    write_json_file_atomic(record_path(root, dest_status, record_id), record)
    record_path(root, src_status, record_id).unlink(missing_ok=True)
    return record


def approve_record(
    state_dir: str | Path,
    *,
    record_id: str,
    actor: str,
    scope: str,
    session_id: str = "",
    ttl_sec: int | None = None,
    audit_log: str | None = None,
) -> dict[str, Any]:
    root = ensure_state_layout(state_dir)
    sweep_expired(root, audit_log=audit_log)
    resolved = find_record(root, record_id, ("pending", "denied", "approved"))
    if resolved is None:
        raise ValueError(f"approval id not found: {record_id}")
    src_status, _path, record = resolved

    scope = str(scope).strip().lower()
    if scope not in {"session", "global"}:
        raise ValueError("approve scope must be 'session' or 'global'")

    now_epoch = epoch_now()
    updated = dict(record)
    updated["status"] = "approved"
    updated["scope"] = scope
    updated["updated_at"] = iso_from_epoch(now_epoch)
    updated["updated_at_epoch"] = now_epoch
    updated["updated_by"] = actor
    updated["approved_at"] = iso_from_epoch(now_epoch)
    updated["approved_at_epoch"] = now_epoch
    updated["approval_status_before"] = src_status
    if scope == "session":
        updated["session_id"] = _resolve_session_id(record, session_id)
        effective_ttl = max(1, int(ttl_sec or DEFAULT_SESSION_TTL_SEC))
        updated["expiry_reason"] = "approval_ttl"
        updated["expires_at_epoch"] = now_epoch + effective_ttl
        updated["expires_at"] = iso_from_epoch(int(updated["expires_at_epoch"]))
    else:
        updated["session_id"] = ""
        effective_ttl = max(1, int(ttl_sec or DEFAULT_GLOBAL_TTL_SEC))
        updated["expiry_reason"] = "approval_ttl"
        updated["expires_at_epoch"] = now_epoch + effective_ttl
        updated["expires_at"] = iso_from_epoch(int(updated["expires_at_epoch"]))

    move_record(root, src_status=src_status, dest_status="approved", record=updated)
    append_jsonl(
        audit_log,
        {
            "ts": now_ts(),
            "module": "openclaw-approvals",
            "action": "approve",
            "decision": "allow",
            "approval_id": record_id,
            "kind": updated.get("kind", ""),
            "value": updated.get("value", ""),
            "scope": updated.get("scope", ""),
            "session_id": updated.get("session_id", ""),
            "updated_by": actor,
        },
    )
    return updated


def deny_record(
    state_dir: str | Path,
    *,
    record_id: str,
    actor: str,
    scope: str,
    session_id: str = "",
    ttl_sec: int | None = None,
    reason: str = "",
    audit_log: str | None = None,
) -> dict[str, Any]:
    root = ensure_state_layout(state_dir)
    sweep_expired(root, audit_log=audit_log)
    resolved = find_record(root, record_id, ("pending", "approved", "denied"))
    if resolved is None:
        raise ValueError(f"approval id not found: {record_id}")
    src_status, _path, record = resolved

    scope = str(scope).strip().lower()
    if scope not in {"session", "global"}:
        raise ValueError("deny scope must be 'session' or 'global'")

    now_epoch = epoch_now()
    updated = dict(record)
    updated["status"] = "denied"
    updated["scope"] = scope
    updated["updated_at"] = iso_from_epoch(now_epoch)
    updated["updated_at_epoch"] = now_epoch
    updated["updated_by"] = actor
    updated["denied_at"] = iso_from_epoch(now_epoch)
    updated["denied_at_epoch"] = now_epoch
    updated["denial_reason"] = str(reason or "").strip()
    if scope == "session":
        updated["session_id"] = _resolve_session_id(record, session_id)
    else:
        updated["session_id"] = ""
    if ttl_sec is not None and int(ttl_sec) > 0:
        updated["expiry_reason"] = "denial_ttl"
        updated["expires_at_epoch"] = now_epoch + int(ttl_sec)
        updated["expires_at"] = iso_from_epoch(int(updated["expires_at_epoch"]))
    else:
        updated["expiry_reason"] = ""
        updated["expires_at_epoch"] = 0
        updated["expires_at"] = ""

    move_record(root, src_status=src_status, dest_status="denied", record=updated)
    append_jsonl(
        audit_log,
        {
            "ts": now_ts(),
            "module": "openclaw-approvals",
            "action": "deny",
            "decision": "allow",
            "approval_id": record_id,
            "kind": updated.get("kind", ""),
            "value": updated.get("value", ""),
            "scope": updated.get("scope", ""),
            "session_id": updated.get("session_id", ""),
            "updated_by": actor,
            "reason": updated.get("denial_reason", ""),
        },
    )
    return updated


def append_allowlist_entry(path: str | Path, value: str) -> bool:
    allowlist = Path(path)
    allowlist.parent.mkdir(parents=True, exist_ok=True)
    existing: set[str] = set()
    if allowlist.exists():
        for line in allowlist.read_text(encoding="utf-8").splitlines():
            entry = line.strip()
            if not entry or entry.startswith("#"):
                continue
            existing.add(entry)
    if value in existing:
        return False
    with allowlist.open("a", encoding="utf-8") as fh:
        if allowlist.stat().st_size > 0:
            fh.write("\n")
        fh.write(value)
        fh.write("\n")
    return True


def promote_record(
    state_dir: str | Path,
    *,
    record_id: str,
    actor: str,
    dm_allowlist_file: str,
    tool_allowlist_file: str,
    audit_log: str | None = None,
) -> dict[str, Any]:
    root = ensure_state_layout(state_dir)
    sweep_expired(root, audit_log=audit_log)
    resolved = find_record(root, record_id, ("pending", "approved", "denied"))
    if resolved is None:
        raise ValueError(f"approval id not found: {record_id}")
    src_status, _path, record = resolved

    kind = str(record.get("kind", "")).strip()
    value = str(record.get("value", "")).strip()
    if kind == "dm_target":
        target_file = dm_allowlist_file
    elif kind == "tool":
        target_file = tool_allowlist_file
    else:
        raise ValueError(f"promotion is unsupported for approval kind: {kind}")

    now_epoch = epoch_now()
    appended = append_allowlist_entry(target_file, value)
    updated = dict(record)
    updated["status"] = "approved"
    updated["scope"] = "persistent"
    updated["session_id"] = ""
    updated["updated_at"] = iso_from_epoch(now_epoch)
    updated["updated_at_epoch"] = now_epoch
    updated["updated_by"] = actor
    updated["promoted_at"] = iso_from_epoch(now_epoch)
    updated["promoted_at_epoch"] = now_epoch
    updated["promoted_file"] = str(target_file)
    updated["promoted_appended"] = appended
    updated["expires_at_epoch"] = 0
    updated["expires_at"] = ""
    updated["expiry_reason"] = ""

    move_record(root, src_status=src_status, dest_status="approved", record=updated)
    append_jsonl(
        audit_log,
        {
            "ts": now_ts(),
            "module": "openclaw-approvals",
            "action": "promote",
            "decision": "allow",
            "approval_id": record_id,
            "kind": kind,
            "value": value,
            "updated_by": actor,
            "promoted_file": str(target_file),
            "allowlist_appended": appended,
        },
    )
    return updated


def record_summary(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": str(record.get("id", "")),
        "status": str(record.get("status", "")),
        "kind": str(record.get("kind", "")),
        "value": str(record.get("value", "")),
        "scope": str(record.get("scope", "")),
        "session_id": str(record.get("session_id", "")),
        "request_count": int(record.get("request_count", 0) or 0),
        "first_seen_at": str(record.get("first_seen_at", "")),
        "last_seen_at": str(record.get("last_seen_at", "")),
        "expires_at": str(record.get("expires_at", "")),
        "updated_by": str(record.get("updated_by", "")),
    }


def print_records(records: list[dict[str, Any]], as_json: bool) -> int:
    if as_json:
        print(json.dumps({"items": [record_summary(item) for item in records]}, indent=2, sort_keys=True))
        return 0

    if not records:
        print("no approval records")
        return 0

    for record in records:
        summary = record_summary(record)
        print(
            "{status:<8} {id} {kind} {value} scope={scope} session={session} requests={count} expires={expires}".format(
                status=summary["status"] or "-",
                id=summary["id"],
                kind=summary["kind"],
                value=summary["value"],
                scope=summary["scope"] or "-",
                session=summary["session_id"] or "-",
                count=summary["request_count"],
                expires=summary["expires_at"] or "-",
            )
        )
    return 0


def iter_records(state_dir: str | Path, statuses: list[str]) -> list[dict[str, Any]]:
    root = ensure_state_layout(state_dir)
    results: list[dict[str, Any]] = []
    for status in statuses:
        for path in list_status_files(root, status):
            payload = load_record(path)
            if not isinstance(payload, dict):
                continue
            results.append(payload)
    results.sort(key=lambda item: (str(item.get("status", "")), str(item.get("last_seen_at", item.get("updated_at", ""))), str(item.get("id", ""))))
    return results


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Manage durable OpenClaw approvals queue")
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--audit-log", default="")
    parser.add_argument("--actor", default=os.environ.get("USER", "unknown"))

    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("ensure-state")

    list_parser = sub.add_parser("list")
    list_parser.add_argument("--status", default="all", choices=["pending", "approved", "denied", "expired", "all"])
    list_parser.add_argument("--json", action="store_true")

    approve_parser = sub.add_parser("approve")
    approve_parser.add_argument("record_id")
    approve_parser.add_argument("--scope", required=True, choices=["session", "global"])
    approve_parser.add_argument("--session-id", default="")
    approve_parser.add_argument("--ttl-sec", type=int, default=None)

    deny_parser = sub.add_parser("deny")
    deny_parser.add_argument("record_id")
    deny_parser.add_argument("--scope", required=True, choices=["session", "global"])
    deny_parser.add_argument("--session-id", default="")
    deny_parser.add_argument("--ttl-sec", type=int, default=None)
    deny_parser.add_argument("--reason", default="")

    promote_parser = sub.add_parser("promote")
    promote_parser.add_argument("record_id")
    promote_parser.add_argument("--dm-allowlist-file", required=True)
    promote_parser.add_argument("--tool-allowlist-file", required=True)

    sub.add_parser("counts")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = ensure_state_layout(args.state_dir)
    sweep_expired(root, audit_log=args.audit_log, actor=args.actor)

    if args.command == "ensure-state":
        print(str(root))
        return 0

    if args.command == "list":
        statuses = list(STATUS_DIRS) if args.status == "all" else [args.status]
        return print_records(iter_records(root, statuses), args.json)

    if args.command == "counts":
        print(json.dumps(approval_counts(root), indent=2, sort_keys=True))
        return 0

    try:
        if args.command == "approve":
            payload = approve_record(
                root,
                record_id=args.record_id,
                actor=args.actor,
                scope=args.scope,
                session_id=args.session_id,
                ttl_sec=args.ttl_sec,
                audit_log=args.audit_log,
            )
        elif args.command == "deny":
            payload = deny_record(
                root,
                record_id=args.record_id,
                actor=args.actor,
                scope=args.scope,
                session_id=args.session_id,
                ttl_sec=args.ttl_sec,
                reason=args.reason,
                audit_log=args.audit_log,
            )
        elif args.command == "promote":
            payload = promote_record(
                root,
                record_id=args.record_id,
                actor=args.actor,
                dm_allowlist_file=args.dm_allowlist_file,
                tool_allowlist_file=args.tool_allowlist_file,
                audit_log=args.audit_log,
            )
        else:
            raise ValueError(f"unsupported command: {args.command}")
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    print(json.dumps(record_summary(payload), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
