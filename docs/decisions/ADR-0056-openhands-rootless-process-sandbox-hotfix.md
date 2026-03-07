# ADR-0056: OpenHands rootless process sandbox hotfix

Date: 2026-03-07
Status: Accepted

## Context

In `rootless-dev`, OpenHands `1.3` was reachable on port `3000` but conversation startup failed with:

- `500: Agent Server Failed to start properly`
- or later `500`/disconnect during `/api/conversations`

Observed causes in this stack:

1. Process-sandbox readiness relied on `psutil.STATUS_RUNNING`, while the spawned agent process is usually `sleeping`, causing false negatives and startup race/errors.
2. Health checks and sandbox URLs are rewritten to `host.docker.internal`; without explicit loopback mapping and proxy bypass this breaks in rootless networking/proxy contexts.
3. Default OpenHands agent tools include browser tooling that hard-requires Chromium; the upstream image used here does not ship Chromium, causing `/api/conversations` failures.

## Decision

For the `openhands` service in `compose/compose.ui.yml`:

1. Pin writable runtime home dirs:
   - `HOME=/.openhands/home`
   - `AGENT_HOME=/.openhands/home`
   - `XDG_CONFIG_HOME` and `XDG_CACHE_HOME` under `/.openhands/home`
2. Force reliable local loopback path for sandbox self-checks:
   - `extra_hosts: host.docker.internal:127.0.0.1`
   - include `host.docker.internal` in `NO_PROXY`
3. Mount local hotfix patches (read-only) into OpenHands app code:
   - `deployments/patches/openhands/process_sandbox_service.py`
   - `deployments/patches/openhands/live_status_app_conversation_service.py`
4. Keep process-sandbox startup poll frequency explicit:
   - `OH_APP_CONVERSATION_SANDBOX_STARTUP_POLL_FREQUENCY=0`
5. Disable automatic git init in empty workspace (not guaranteed in this image):
   - `OH_APP_CONVERSATION_INIT_GIT_IN_EMPTY_WORKSPACE=0`
6. Override process sandbox spec entry (`OH_SANDBOX_SPEC_SPECS_0`) with explicit `working_dir=/workspace` and `OH_CONVERSATIONS_PATH=/workspace/conversations`.

## Consequences

- OpenHands no longer fails on the initial "Agent Server Failed to start properly" path in rootless mode.
- Conversation startup can reach `READY` without Chromium dependency.
- This is a tactical upstream hotfix. When OpenHands upstream addresses these behaviors, remove local code mounts and revert to stock image behavior.
