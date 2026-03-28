# Runbook: Git Forge Management

Status: planned target for `dgx-spark-agentic-stack-zu7n`, not implemented yet.

This runbook defines the intended operator workflow for the future internal Git forge module. It exists so the plan, runtime contract, and account model are explicit before implementation starts.

## Goal

Provide one self-hosted Git forge inside the stack so:

- the host operator can manage repositories through a loopback-only web UI;
- `openclaw`, `openhands`, `comfyui`, `claude`, `codex`, `opencode`, `vibestral`, `pi-mono`, and `goose` can share projects through normal Git operations;
- repository state and forge database survive restart, update, and rollback workflows.

## Service Model

Target design:

- compose profile: `optional-git-forge`
- service: `optional-forgejo` or equivalent Forgejo/Gitea-compatible forge
- host UI/API bind: `127.0.0.1:${GIT_FORGE_HOST_PORT:-13000}`
- agent access path: private Docker network service DNS, not public host networking
- default transport: internal HTTPS with token or PAT authentication
- forge SSH: disabled by default

Reason for the default transport choice:

- it avoids a second exposed ingress surface;
- token rotation is easier to automate than SSH key management for many agent identities;
- it matches the stack rule of minimizing exposed services and secrets sprawl.

## Runtime Paths

The forge should persist under `${AGENTIC_ROOT}/optional/git/`:

- `config/` for rendered forge configuration
- `state/` for runtime state that is not repository content
- `logs/` for operator/audit-facing logs
- `db/` for the persistent forge database
- `repositories/` for bare repositories and attachments
- `bootstrap/` for idempotent provisioning markers or manifests

Secrets stay outside git, under a runtime secret root such as `${AGENTIC_ROOT}/secrets/runtime/git-forge/`.

Recommended secret files:

- `system-manager.password`
- `<agent>.token` for each agent account
- optional rotation metadata file if the implementation needs reconciliation timestamps

All such files must remain `chmod 600` and out of version control.

## Onboarding Inputs

When the module is implemented, `./agent onboard` should make the forge configuration explicit instead of relying on hidden defaults.

Expected non-secret onboarding outputs:

- `AGENTIC_OPTIONAL_MODULES` includes `git-forge` when the operator enables it
- `GIT_FORGE_HOST_PORT` for the loopback UI/API bind
- `GIT_FORGE_ADMIN_USER` with default `system-manager`
- `GIT_FORGE_SHARED_NAMESPACE` for the shared organization/group used by stack-managed repositories
- `GIT_FORGE_ENABLE_PUSH_CREATE` (`0` by default, `1` only when the operator explicitly wants agents to create repos by push)

Expected secret onboarding outputs:

- the initial admin password or bootstrap token for `system-manager`
- one credential or token per agent account

These secrets must be materialized as separate root-only files under `${AGENTIC_ROOT}/secrets/runtime/git-forge/`, not written into the generated shell env file.

## Accounts and Roles

Required bootstrap identities:

- `system-manager`: system manager/admin role, intended for the human operator from the host side
- `openclaw`
- `openhands`
- `comfyui`
- `claude`
- `codex`
- `opencode`
- `vibestral`
- `pi-mono`
- `goose`

Expected role model:

- `system-manager` owns initial organization/repository bootstrap and can rotate/revoke agent credentials;
- agent accounts are non-admin service users;
- repository permissions should be explicit and minimal, but allow collaborative push/pull on shared project repos.

## Bootstrap Workflow

The intended bootstrap flow is:

1. Deploy the forge profile with loopback-only exposure.
2. Wait for healthcheck success.
3. Create or reconcile `system-manager`.
4. Create or reconcile the agent accounts.
5. Materialize per-account credentials outside git.
6. Create one shared organization or namespace for stack-managed projects.
7. Create an initial test repository and grant the expected agent access.
8. Record the resulting forge version and image digest in the release artifact.

The bootstrap must be idempotent. Re-running `agent update` must converge the state instead of creating duplicate users or repositories.

## Repository Sharing Workflow

The target operator flow for a shared project is:

1. `system-manager` creates the repository through the web UI or API.
2. The operator grants the required agent accounts push/pull access.
3. Each agent container receives only its own credential material.
4. Agents use standard Git commands against the internal forge URL:
   - `git clone`
   - `git fetch`
   - `git pull`
   - `git push`
5. Shared work happens through normal branches and remotes, not by bind-mounting another agent's workspace.

This keeps project exchange auditable and closer to real developer workflows.

## Rotation and Revocation

Credential management must support:

- rotating one agent token without touching the others;
- revoking one compromised agent account;
- re-issuing `system-manager` credentials without rewriting repository storage;
- updating secret files without storing the values in release artifacts or logs.

When tokens rotate, the implementation should refresh only the matching agent runtime secret, then restart or reconcile only the impacted service if necessary.

## Backup, Restore, and Rollback

The implementation should treat the forge as stateful data, not only as image/config:

- release artifacts must record the deployed image digest and forge version;
- repository storage and database snapshots must be included in the restore story;
- rollback must restore a coherent pair of database state and repositories, not only compose files;
- doctor/compliance must fail if the forge profile is enabled but DB/repos are not on persistent storage.

## Compliance Expectations

When the module is implemented, `./agent doctor` should verify at least:

- loopback-only host bind for the web UI;
- no `docker.sock` mount;
- hardening baseline (`cap_drop: ALL`, `no-new-privileges`, read-only rootfs where applicable);
- healthcheck presence;
- persistence paths under `${AGENTIC_ROOT}/optional/git/`;
- presence of `system-manager` plus the required agent accounts;
- release metadata contains the forge image digest.

## Open Points Kept Explicit

- Whether the forge uses SQLite or PostgreSQL internally is an implementation detail, but the database must stay on persistent storage.
- Whether the bootstrap creates one shared organization or one repo per project can remain configurable.
- SSH support is intentionally out of scope for the first implementation unless a later ADR accepts the extra exposure and key management burden.
