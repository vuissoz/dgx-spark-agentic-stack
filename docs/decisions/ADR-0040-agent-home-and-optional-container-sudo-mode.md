# ADR-0040: Agent HOME Alignment and Optional In-Container Sudo Mode

## Context

Agent services run with runtime UID/GID overrides (commonly `1000:1000`) to keep host-mounted state writable.
The shared agent image sets `HOME=/home/agent`, but when runtime UID maps to another user (for example `ubuntu`), shells and CLIs can hit permission errors:

- `bash: /home/agent/.bash_profile: Permission denied`
- `codex` config read/write failures under `/home/agent/.codex`

In parallel, operators requested in-container `sudo` for agent workflows. With `no-new-privileges:true`, setuid escalation is intentionally blocked, so `sudo` cannot work.

## Decision

1. Pin agent runtime home to a writable, persistent path:
   - `HOME=/state/home` (`/state` is already a writable persisted mount).
   - Entry point bootstraps shell files and CLI config directories inside `/state/home`.

2. Keep hardened default posture:
   - `AGENTIC_AGENT_NO_NEW_PRIVILEGES=true` by default for agent services.

3. Add explicit opt-in sudo mode for all agent services:
   - `./agent sudo-mode on` sets `AGENTIC_AGENT_NO_NEW_PRIVILEGES=false` and redeploys `agents`.
   - `./agent sudo-mode off` restores hardened mode (`true`).
   - Agent base image installs `sudo` and configures passwordless sudo for in-image interactive users.

4. Extend compliance checks:
   - `agent doctor` validates `/state/home` wiring.
   - In sudo mode, `agent doctor` validates `sudo -n true` and the relaxed `no-new-privileges:false` expectation for agent services.

## Consequences

- Codex/agent shells no longer depend on `/home/agent` permissions when runtime UID differs.
- Default security baseline remains unchanged unless sudo mode is explicitly enabled.
- Enabling sudo mode is a deliberate hardening tradeoff limited to agent containers.
