#!/usr/bin/env python3
"""src/agentic/control/config_schema.py — Environment variable schema validation with drift detection (§M4).

Provides:
- Type checking, range validation, and pattern matching for environment variables
- Drift detection against documented configuration
- Integration with check_config_docs_drift.py script

Conforms to PLAN.md §M4 (Fondation production) and §4 (sources de verite).

Usage:
    from agentic.control.config_schema import validate_config, check_drift, ENV_VAR_SCHEMA
    
    # Validate current environment
    result = validate_config()
    if not result.valid:
        print(f"Config validation failed: {result.errors}")
    
    # Check drift against known good configuration
    drift = check_drift()
    if drift.detected:
        print(f"Config drift detected: {drift.changes}")
"""

from __future__ import annotations

import os
import re
import json
import logging
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Optional

logger = logging.getLogger(__name__)


class ConfigSource(Enum):
    """Configuration variable sources."""
    ENVIRONMENT = "environment"
    FILE = "file"
    DEFAULT = "default"
    DERIVED = "derived"


class Severity(Enum):
    """Validation severity levels."""
    ERROR = "error"
    WARNING = "warning"
    INFO = "info"


@dataclass
class ValidationError:
    """Single configuration validation error."""
    var_name: str
    message: str
    severity: Severity = Severity.ERROR
    expected: Optional[str] = None
    actual: Optional[str] = None

    def __str__(self) -> str:
        return f"[{self.severity.value.upper()}] {self.var_name}: {self.message}"


@dataclass
class ValidationResult:
    """Result of configuration validation."""
    valid: bool = True
    errors: list[ValidationError] = field(default_factory=list)
    warnings: list[ValidationError] = field(default_factory=list)
    info: list[ValidationError] = field(default_factory=list)

    def add_error(self, error: ValidationError) -> None:
        self.valid = False
        self.errors.append(error)

    def add_warning(self, warning: ValidationError) -> None:
        self.warnings.append(warning)

    def add_info(self, info: ValidationError) -> None:
        self.info.append(info)

    def __str__(self) -> str:
        lines = []
        if self.valid:
            lines.append("Configuration is VALID")
        else:
            lines.append("Configuration is INVALID")
            lines.append(f"  Errors ({len(self.errors)}):")
            for e in self.errors:
                lines.append(f"    - {e}")
        if self.warnings:
            lines.append(f"  Warnings ({len(self.warnings)}):")
            for w in self.warnings:
                lines.append(f"    - {w}")
        if self.info:
            lines.append(f"  Info ({len(self.info)}):")
            for i in self.info:
                lines.append(f"    - {i}")
        return "\n".join(lines)


@dataclass
class DriftChange:
    """Single configuration drift change."""
    var_name: str
    change_type: str
    old_value: Optional[str] = None
    new_value: Optional[str] = None
    source: ConfigSource = ConfigSource.ENVIRONMENT

    def __str__(self) -> str:
        if self.change_type == "added":
            return f"+ {self.var_name} = {self.new_value} (source: {self.source.value})"
        elif self.change_type == "removed":
            return f"- {self.var_name} = {self.old_value}"
        else:
            return f"~ {self.var_name}: {self.old_value} -> {self.new_value}"


@dataclass
class DriftResult:
    """Result of configuration drift detection."""
    detected: bool = False
    changes: list[DriftChange] = field(default_factory=list)
    reference_timestamp: Optional[float] = None
    current_timestamp: float = field(default_factory=lambda: __import__("time").time())

    def __str__(self) -> str:
        if not self.detected:
            return "No configuration drift detected"
        lines = [f"Configuration drift detected ({len(self.changes)} changes):"]
        for change in self.changes:
            lines.append(f"  {change}")
        return "\n".join(lines)


# Schema definition for environment variables
ENV_VAR_SCHEMA: dict[str, dict[str, Any]] = {
    "DATABASE_URL": {"type": "string", "description": "PostgreSQL connection URL", "required": False, "pattern": r"^postgresql:\/\/.*", "category": "database"},
    "DATABASE_POOL_SIZE": {"type": "int", "description": "Database connection pool size", "required": False, "min": 1, "max": 100, "default": 5, "category": "database"},
    "DATABASE_TIMEOUT": {"type": "float", "description": "Database connection timeout in seconds", "required": False, "min": 0.5, "max": 300.0, "default": 30.0, "category": "database"},
    "DOCKER_HOST": {"type": "string", "description": "Docker daemon socket path", "required": True, "default": "unix:///var/run/docker.sock", "category": "docker"},
    "DOCKER_TLS_VERIFY": {"type": "bool", "description": "Enable TLS verification for Docker API", "required": False, "default": True, "category": "docker"},
    "DOCKER_USER": {"type": "string", "description": "User:group mapping for containers", "required": True, "default": "1000:1000", "pattern": r"^[0-9]+:[0-9]+$", "category": "docker"},
    "DOCKER_NETWORK": {"type": "string", "description": "Default Docker network", "required": False, "default": "agentic", "category": "docker"},
    "CONTROL_PLANE_HOST": {"type": "string", "description": "Control plane API host", "required": True, "default": "127.0.0.1", "category": "network"},
    "CONTROL_PLANE_PORT": {"type": "int", "description": "Control plane API port", "required": True, "min": 1024, "max": 65535, "default": 8000, "category": "network"},
    "CONTROL_PLANE_TOKEN": {"type": "string", "description": "Authentication token for control plane", "required": False, "min_length": 32, "category": "network"},
    "BIND_ADDRESS": {"type": "string", "description": "Default bind address for services", "required": True, "default": "127.0.0.1", "category": "network"},
    "SECRETS_DIR": {"type": "string", "description": "Directory for secrets and credentials", "required": True, "default": "/srv/agentic/gate/state", "category": "security"},
    "AUDIT_LOG_FILE": {"type": "string", "description": "Path to audit log file", "required": False, "default": "/var/log/agentic/audit.log", "category": "security"},
    "SESSION_TTL_SECONDS": {"type": "int", "description": "User session TTL", "required": False, "min": 60, "max": 86400, "default": 3600, "category": "security"},
    "MAX_SESSIONS_PER_USER": {"type": "int", "description": "Maximum sessions per user", "required": False, "min": 1, "max": 100, "default": 10, "category": "security"},
    "ENABLE_AUDIT_LOGGING": {"type": "bool", "description": "Enable audit logging", "required": False, "default": True, "category": "security"},
    "MODELS_DIR": {"type": "string", "description": "Directory for model checkpoints", "required": True, "default": "/srv/agentic/ollama/", "category": "models"},
    "DEFAULT_MODEL": {"type": "string", "description": "Default model for sessions", "required": False, "default": "llama3.2:3b", "category": "models"},
    "MODEL_TIMEOUT_SECONDS": {"type": "int", "description": "Model inference timeout", "required": False, "min": 60, "max": 7200, "default": 600, "category": "models"},
    "MAX_MODEL_MEMORY_GB": {"type": "int", "description": "Maximum memory for models", "required": False, "min": 4, "max": 128, "default": 40, "category": "models"},
    "AGENTIC_ROOT": {"type": "string", "description": "Base directory for agentic state", "required": True, "default": "/srv/agentic/", "category": "storage"},
    "WORKSPACE_BASE": {"type": "string", "description": "Base directory for workspaces", "required": False, "default": "/srv/agentic/workspaces/", "category": "storage"},
    "BACKUP_DIR": {"type": "string", "description": "Directory for backups", "required": False, "default": "/srv/agentic/backups/", "category": "storage"},
    "RETENTION_DAYS": {"type": "int", "description": "Backup retention period", "required": False, "min": 1, "max": 365, "default": 30, "category": "storage"},
}


def _convert_value(value: str, schema: dict[str, Any]) -> Any:
    var_type = schema.get("type", "string")
    try:
        if var_type == "int": return int(value)
        elif var_type == "float": return float(value)
        elif var_type == "bool": return value.lower() in ("true", "1", "yes", "on")
        else: return value
    except ValueError:
        return value


def _validate_value(value: Any, schema: dict[str, Any]) -> Optional[str]:
    var_type = schema.get("type", "string")
    var_name = schema.get("name", "unknown")
    if schema.get("required", False) and value is None:
        return f"Required variable {var_name} is not set"
    if value is None:
        return None
    if var_type == "int":
        if not isinstance(value, int): return f"{var_name} must be an integer, got {type(value).__name__}"
        if "min" in schema and value < schema["min"]: return f"{var_name} must be >= {schema['min']}, got {value}"
        if "max" in schema and value > schema["max"]: return f"{var_name} must be <= {schema['max']}, got {value}"
    elif var_type == "float":
        if not isinstance(value, (int, float)): return f"{var_name} must be a number, got {type(value).__name__}"
        if "min" in schema and value < schema["min"]: return f"{var_name} must be >= {schema['min']}, got {value}"
        if "max" in schema and value > schema["max"]: return f"{var_name} must be <= {schema['max']}, got {value}"
    elif var_type == "string":
        if "min_length" in schema and len(value) < schema["min_length"]: return f"{var_name} must be at least {schema['min_length']} characters"
        if "max_length" in schema and len(value) > schema["max_length"]: return f"{var_name} must be at most {schema['max_length']} characters"
        if "pattern" in schema and not re.match(schema["pattern"], value): return f"{var_name} must match pattern {schema['pattern']}"
        if "allowed_values" in schema:
            allowed = schema["allowed_values"]
            if str(value).upper() not in [v.upper() for v in allowed]: return f"{var_name} must be one of {allowed}, got {value}"
    elif var_type == "bool" and not isinstance(value, bool):
        return f"{var_name} must be a boolean, got {type(value).__name__}"
    return None


def validate_variable(var_name: str, schema: dict[str, Any], env_value: Optional[str] = None) -> Optional[ValidationError]:
    if env_value is None:
        env_value = os.environ.get(var_name)
    schema_with_name = {**schema, "name": var_name}
    converted_value = _convert_value(env_value, schema_with_name) if env_value is not None else None
    error_msg = _validate_value(converted_value, schema_with_name)
    if error_msg:
        severity = Severity.ERROR if schema_with_name.get("required", False) else Severity.WARNING
        return ValidationError(var_name=var_name, message=error_msg, severity=severity, expected=str(schema_with_name.get("default", "")), actual=env_value)
    return None


def validate_config(include_optional: bool = True, category: Optional[str] = None) -> ValidationResult:
    result = ValidationResult()
    for var_name, schema in ENV_VAR_SCHEMA.items():
        if category and schema.get("category") != category:
            continue
        if not include_optional and not schema.get("required", False):
            continue
        error = validate_variable(var_name, schema)
        if error:
            if error.severity == Severity.ERROR: result.add_error(error)
            elif error.severity == Severity.WARNING: result.add_warning(error)
            else: result.add_info(error)
    return result


class ConfigSnapshot:
    def __init__(self, variables: dict[str, str], timestamp: float):
        self.variables = variables
        self.timestamp = timestamp
    def to_dict(self) -> dict[str, Any]:
        return {"variables": self.variables, "timestamp": self.timestamp}
    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "ConfigSnapshot":
        return cls(variables=data.get("variables", {}), timestamp=data.get("timestamp", 0))
    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=2)


_reference_snapshot: Optional[ConfigSnapshot] = None


def capture_reference_snapshot() -> ConfigSnapshot:
    global _reference_snapshot
    variables = {var: os.environ.get(var, "") for var in ENV_VAR_SCHEMA.keys()}
    _reference_snapshot = ConfigSnapshot(variables, __import__("time").time())
    return _reference_snapshot


def load_reference_snapshot(path: str) -> Optional[ConfigSnapshot]:
    global _reference_snapshot
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        _reference_snapshot = ConfigSnapshot.from_dict(data)
        return _reference_snapshot
    except (FileNotFoundError, json.JSONDecodeError) as e:
        logger.warning(f"Failed to load reference snapshot: {e}")
        return None


def save_reference_snapshot(path: str) -> bool:
    global _reference_snapshot
    if _reference_snapshot is None:
        capture_reference_snapshot()
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(_reference_snapshot.to_json())
        return True
    except Exception as e:
        logger.warning(f"Failed to save reference snapshot: {e}")
        return False


def check_drift(reference_path: Optional[str] = None, current_env: Optional[dict[str, str]] = None) -> DriftResult:
    global _reference_snapshot
    result = DriftResult()
    if reference_path:
        load_reference_snapshot(reference_path)
    elif _reference_snapshot is None:
        return result
    if current_env is None:
        current_env = os.environ
    for var_name in ENV_VAR_SCHEMA.keys():
        old_value = _reference_snapshot.variables.get(var_name, "")
        new_value = current_env.get(var_name, "")
        if old_value != new_value:
            change_type = "added" if not old_value and new_value else "removed" if old_value and not new_value else "modified"
            result.changes.append(DriftChange(var_name=var_name, change_type=change_type, old_value=old_value or None, new_value=new_value or None))
    result.detected = len(result.changes) > 0
    result.reference_timestamp = _reference_snapshot.timestamp if _reference_snapshot else None
    return result


def get_all_schema_variables() -> set[str]:
    return set(ENV_VAR_SCHEMA.keys())


def get_schema_categories() -> set[str]:
    return set(schema.get("category", "uncategorized") for schema in ENV_VAR_SCHEMA.values())


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Validate configuration schema and check drift.")
    parser.add_argument("--validate", action="store_true", help="Validate current configuration")
    parser.add_argument("--drift", action="store_true", help="Check configuration drift")
    parser.add_argument("--category", help="Only validate variables in this category")
    args = parser.parse_args()
    if args.validate:
        result = validate_config(category=args.category)
        print(result)
        exit(0 if result.valid else 1)
    if args.drift:
        drift = check_drift()
        print(drift)
        exit(0 if not drift.detected else 1)
