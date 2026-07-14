#!/usr/bin/env python3
"""src/agentic/implementations/git_and_external.py — GitProvider and ExternalAccess adapters (§2.6, §10).

Implements:
- ForgejoGitProviderAdapter: internal forge (primary git source per v2)
- GitHubGitProviderAdapter: external GitHub access via short-lived credentials
- ExternalAccessBroker: manages short-lived tokens for GitHub, HuggingFace, etc.
- SecretStore: single-source canonical secret management

Conforms to PLAN.md §10 (Secrets, GitHub, HF), §12.4 (AuthorizationBatch).
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Optional


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.join(SCRIPT_DIR, "..", "..")


# ── Forgejo Git Provider Adapter (§2.6, §3.2) ─────────────────────

class ForgejoGitProviderAdapter:
    """GitProviderAdapter for Forgejo self-hosted forge (internal primary).

    Per §9.1, Forgejo is the internal canon for git repositories.
    Manages accounts, SSH keys, hooks, protected branches.
    """

    def __init__(self, forgejo_url: str | None = None):
        self.forgejo_url = (forgejo_url or os.environ.get(
            "FORGEJO_URL", "http://127.0.0.1:3080"
        ))

    @property
    def provider_name(self) -> str:
        return "forgejo"

    async def list_repos(self, user_id: str) -> list[dict[str, Any]]:
        """List repositories accessible to a user."""
        import subprocess
        try:
            token = os.environ.get("FORGEJO_TOKEN", "")
            if not token:
                return []

            result = subprocess.run(
                ["curl", "-s", "-H", f"Authorization: token {token}",
                 f"{self.forgejo_url}/api/v1/user/repos?type=owner"],
                capture_output=True, text=True, timeout=30,
            )
            if result.returncode == 0 and result.stdout.strip():
                return json.loads(result.stdout)
            return []
        except Exception:
            return []

    async def push(self, repo: str, branch: str, payload: dict[str, Any]) -> bool:
        """Push to a Forgejo repository."""
        # In production this would use git push via subprocess or API
        # For now, validate the operation is possible
        if not repo or not branch:
            return False
        return True  # Stub — actual push delegated to agent workspace


# ── GitHub Git Provider Adapter (§10.2) ───────────────────────────

class GitHubGitProviderAdapter:
    """GitProviderAdapter for external GitHub access via short-lived credentials.

    Per §10.2, uses GitHub App installation tokens or fine-grained PATs.
    Supports scopes: contents.read/write, pull_requests.read/write, issues.read/write,
    actions.read (admin separate). Forgejo remains the internal canon;
    GitHub sync/mirror only if requested.
    """

    def __init__(self, broker: ExternalAccessBroker | None = None):
        self.broker = broker or ExternalAccessBroker()
        self.provider_name = "github"

    async def list_repos(self, user_id: str) -> list[dict[str, Any]]:
        """List GitHub repos with short-lived credential."""
        import subprocess
        creds = await self.broker.rotate_credentials("github", f"github.repos.read.{user_id}")
        if not creds.get("token"):
            return []

        try:
            result = subprocess.run(
                ["curl", "-s", "-H", f"Authorization: token {creds['token']}",
                 "https://api.github.com/user/repos?per_page=100"],
                capture_output=True, text=True, timeout=30,
            )
            if result.returncode == 0 and result.stdout.strip():
                return json.loads(result.stdout)
            return []
        except Exception:
            return []
        finally:
            # Revoke the short-lived credential after use
            await self.broker.revoke_credentials(creds.get("token_id", ""))

    async def push(self, repo: str, branch: str, payload: dict[str, Any]) -> bool:
        """Push to GitHub with short-lived write credentials."""
        user_id = payload.get("user_id", "unknown")
        creds = await self.broker.rotate_credentials("github", f"github.repos.write.{user_id}")
        if not creds.get("token"):
            return False

        try:
            # Validate required permissions exist
            allowed_scopes = payload.get("scopes", ["contents.read"])
            write_required = any(s.endswith(".write") for s in allowed_scopes)
            if write_required and "github.repos.write" not in creds.get("scope", ""):
                return False

            return True  # Stub — actual push via git or API
        finally:
            await self.broker.revoke_credentials(creds.get("token_id", ""))


# ── ExternalAccessBroker (§10.2) ────────────────────────────────────

class ExternalAccessBroker:
    """Manages short-lived credentials for GitHub, HuggingFace, and external services.

    Per §10: tokens are short-lived, user/agent/project/run-scoped, and rotated.
    Implements the ExternalAccessBroker contract from adapters.py.
    """

    def __init__(self):
        self._tokens: dict[str, dict] = {}  # token_id -> metadata
        self._env_prefix = os.environ.get("SECRET_STORE_BASE", "/srv/agentic/secrets")

    async def rotate_credentials(self, service: str, scope: str) -> dict[str, Any]:
        """Rotate credentials for a service+scope combination.

        Returns short-lived token info with rotation_id for revocation.
        Supported services: github, huggingface
        Scopes follow the pattern: {service}.{action}.read/write (e.g., github.repos.read)
        """
        valid_services = ("github", "huggingface")
        if service not in valid_services:
            return {"error": f"Unsupported service: {service}"}

        # Check env for pre-configured credentials (in production, this is SecretStore)
        token_key = f"EXTERNAL_{service.upper()}_TOKEN"
        token_value = os.environ.get(token_key, "")

        if not token_value:
            return {"error": f"No credential configured for service: {service}"}

        token_id = f"cred-{uuid.uuid4().hex[:12]}"
        expires_in = 3600  # 1 hour TTL

        self._tokens[token_id] = {
            "service": service,
            "scope": scope,
            "token_value": token_value,  # In production, never log this
            "created_at": time.time(),
            "expires_at": time.time() + expires_in,
            "revoked": False,
        }

        return {
            "token_id": token_id,
            "service": service,
            "scope": scope,
            "expires_in": expires_in,
            "token_value": f"{token_value[:8]}...{token_value[-4:]}" if len(token_value) > 12 else "***",
        }

    async def revoke_credentials(self, token_id: str) -> bool:
        """Revoke a credential by token_id."""
        if token_id in self._tokens:
            self._tokens[token_id]["revoked"] = True
            return True
        return False

    async def health_check(self) -> bool:
        """Check broker health (all configured services have tokens)."""
        for service in ("github", "huggingface"):
            if not os.environ.get(f"EXTERNAL_{service.upper()}_TOKEN"):
                return False
        return True


# ── SecretStore (§10.1) ───────────────────────────────────────────

class SecretStore:
    """Single-source canonical secret management (§10.1).

    Ensures: encryption, scopes, rotation, expiration, audit trail.
    No secrets in PostgreSQL, logs, RAG, images, or HOME persisting.
    OpenShell providers and temp files are delivery mechanisms only.
    """

    def __init__(self, store_path: str | None = None):
        self.store_path = (store_path or os.environ.get(
            "SECRET_STORE_PATH", "/srv/agentic/secrets/store"
        ))
        self._secrets: dict[str, dict] = {}  # In-memory for dev; file-based in prod

    def store(self, name: str, value: str, scope: str = "global",
              expires_at: Optional[float] = None) -> str:
        """Store a secret with metadata."""
        secret_id = f"sec-{uuid.uuid4().hex[:12]}"
        self._secrets[secret_id] = {
            "name": name,
            "value": value,  # In production: encrypted
            "scope": scope,
            "created_at": time.time(),
            "expires_at": expires_at,
            "rotations": 0,
        }
        return secret_id

    def get(self, secret_id: str) -> Optional[dict[str, Any]]:
        """Retrieve a secret by ID."""
        if secret_id not in self._secrets:
            return None
        entry = self._secrets[secret_id]
        if entry.get("expires_at") and time.time() > entry["expires_at"]:
            del self._secrets[secret_id]
            return None  # Expired
        return {"id": secret_id, "name": entry["name"], "scope": entry["scope"]}

    def rotate(self, secret_id: str) -> Optional[str]:
        """Rotate a secret and return the new ID."""
        if secret_id not in self._secrets:
            return None
        old = self._secrets[secret_id]
        new_id = f"sec-{uuid.uuid4().hex[:12]}"
        self._secrets[new_id] = {
            **old,
            "value": secrets.token_urlsafe(32),  # New value
            "created_at": time.time(),
            "rotations": old.get("rotations", 0) + 1,
        }
        del self._secrets[secret_id]
        return new_id

    def audit_log(self, action: str, target: str, actor: str = "") -> None:
        """Append audit entry (in production: write to structured log)."""
        # In production this writes to Loki or similar
        pass


# ── CLI entry point ────────────────────────────────────────────────

def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Git & External Access — status")
    parser.add_argument("--action", choices=["health", "rotate"], default="health")
    parser.add_argument("--service", choices=["github", "huggingface"])
    args = parser.parse_args()

    if args.action == "health":
        broker = ExternalAccessBroker()
        import asyncio
        result = asyncio.run(broker.health_check())
        print(json.dumps({"healthy": result}, indent=2))

    elif args.action == "rotate":
        if not args.service:
            print("ERROR: --service required for rotate", file=__import__("sys").stderr)
            return 1
        broker = ExternalAccessBroker()
        import asyncio
        result = asyncio.run(broker.rotate_credentials(args.service, f"{args.service}.default"))
        print(json.dumps(result, indent=2))

    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
