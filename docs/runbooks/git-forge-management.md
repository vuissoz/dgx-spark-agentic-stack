# Runbook: Git Forge Management

Status: implemented optional module for `dgx-spark-agentic-stack-zu7n`.

## Goal

Provide one self-hosted Git forge inside the stack so:

- the host operator can manage repositories through a loopback-only web UI;
- `openclaw`, `openhands`, `comfyui`, `claude`, `codex`, `opencode`, `vibestral`, `pi-mono`, and `goose` can share projects through normal Git operations;
- repository state and forge database survive restart, update, and rollback workflows.

## Service Model

- service: `optional-forgejo` using `codeberg.org/forgejo/forgejo:14-rootless`
- host UI/API bind: `127.0.0.1:${GIT_FORGE_HOST_PORT:-13010}`
- agent access path: private Docker network service DNS, not public host networking
- default transport: internal HTTP on the private Docker network with per-account password helpers
- forge SSH: disabled by default
- deployment path: converged together with `./agent up ui`, `./agent up agents,ui,obs,rag`, and `./agent first-up` so agent Git bootstrap exists before `./agent doctor`

Reason for the default transport choice:

- it avoids a second exposed ingress surface;
- token rotation is easier to automate than SSH key management for many agent identities;
- it matches the stack rule of minimizing exposed services and secrets sprawl.

## Runtime Paths

The forge persists under `${AGENTIC_ROOT}/optional/git/`:

- `config/` for rendered forge configuration
- `state/` for the Forgejo workdir, including the persistent SQLite DB and repositories
- `bootstrap/` for idempotent provisioning markers or manifests

Secrets stay outside git, under a runtime secret root such as `${AGENTIC_ROOT}/secrets/runtime/git-forge/`.

Recommended secret files:

- `system-manager.password`
- `<agent>.password` for each agent account
- optional rotation metadata file if the implementation needs reconciliation timestamps

Application/API secrets stay `chmod 600`; forge account password files stay `chmod 640` so the matching runtime group can read `/run/secrets/git-forge.password`.

## Onboarding Inputs

`./agent onboard` makes the forge configuration explicit instead of relying on hidden defaults.

Expected non-secret onboarding outputs:

- `GIT_FORGE_HOST_PORT` for the loopback UI/API bind
- `GIT_FORGE_ADMIN_USER` with default `system-manager`
- `GIT_FORGE_SHARED_NAMESPACE` for the shared organization/group used by stack-managed repositories
- `GIT_FORGE_ENABLE_PUSH_CREATE` (`0` by default, `1` only when the operator explicitly wants agents to create repos by push)

Expected secret onboarding outputs:

- the initial admin password or bootstrap token for `system-manager`
- one credential or token per agent account

These secrets are materialized as separate files under `${AGENTIC_ROOT}/secrets/runtime/git-forge/`, not written into the generated shell env file.

In addition, onboarding/runtime bootstrap should prepare each agent container so the first interactive shell can use the forge immediately:

- preconfigure `git config --global user.name` and `user.email` for the matching agent account
- preconfigure the internal forge base URL
- render a credential helper backed by `/run/secrets/git-forge.password`
- avoid any first-use prompt for the initial `git clone` or checkout of a forge-hosted project

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

The implemented bootstrap flow is:

1. Deploy the forge profile with loopback-only exposure.
2. Wait for healthcheck success.
3. Create or reconcile `system-manager`.
4. Create or reconcile the agent accounts.
5. Materialize per-account passwords outside git.
6. Create one shared organization or namespace for stack-managed projects.
7. Create an initial shared repository and team-scoped access.
8. Create and seed the managed reference repository `eight-queens-agent-e2e`.
9. Protect `main`, reserve `agent/<tool>` branches, and record the resulting
   forge metadata in bootstrap/release artifacts.

The bootstrap must be idempotent. Re-running `agent update` must converge the state instead of creating duplicate users or repositories.

## Repository Sharing Workflow

The operator flow for a shared project is:

1. `system-manager` creates the repository through the web UI or API.
2. The operator grants the required agent accounts push/pull access.
3. Each agent container receives only its own credential material plus its pre-rendered Git identity/auth configuration.
4. On first shell attach, agents can already use standard Git commands against the internal forge URL:
   - `git clone`
   - repository checkout immediately after clone without credential prompt
   - `git fetch`
   - `git pull`
   - `git push`
5. Shared work happens through normal branches and remotes, not by bind-mounting another agent's workspace.

This keeps project exchange auditable and closer to real developer workflows.

## Reference E2E Repository

Because git-forge is part of the baseline stack, bootstrap also reconciles one
stack-managed reference repository:

- name: `eight-queens-agent-e2e`
- namespace: `${GIT_FORGE_SHARED_NAMESPACE}`
- contract:
  - problem statement lives in the repository itself,
  - Python target implementation under `src/`,
  - verification through `python3 -m pytest -q`,
  - branch policy stored in `.agentic/reference-e2e.manifest.json`

Managed branch rules:

- `main` is protected and only `system-manager` stays on the push allowlist,
- the following branches are prepared for agent runs:
  - `agent/codex`
  - `agent/openclaw`
  - `agent/claude`
  - `agent/opencode`
  - `agent/openhands`
  - `agent/pi-mono`
  - `agent/goose`
  - `agent/vibestral`

Each managed agent home now also receives:

- `AGENTIC_GIT_FORGE_REFERENCE_REPOSITORY`
- `AGENTIC_GIT_FORGE_REFERENCE_CLONE_URL`
- `AGENTIC_GIT_FORGE_REFERENCE_HOST_CLONE_URL`
- `AGENTIC_GIT_FORGE_REFERENCE_BRANCH`

## Repository-driven E2E Runner

The non-interactive orchestrator is:

- `./agent repo-e2e`

Typical invocations:

```bash
# plan only
AGENTIC_PROFILE=rootless-dev ./agent repo-e2e --dry-run

# real run with full artefacts
AGENTIC_PROFILE=rootless-dev ./agent repo-e2e \
  --artifacts-dir "${AGENTIC_ROOT}/deployments/validation/agent-repo-e2e/manual-$(date -u +%Y%m%dT%H%M%SZ)"

# opt-in destructive reset of the selected agent branches back to main
AGENTIC_PROFILE=rootless-dev ./agent repo-e2e \
  --reset-agent-branches \
  --artifacts-dir "${AGENTIC_ROOT}/deployments/validation/agent-repo-e2e/from-scratch-$(date -u +%Y%m%dT%H%M%SZ)"
```

The runner stores:

- one artefact directory per agent,
- stdout/stderr of prepare/invoke/verify steps,
- git status and diff after the run,
- `summary.json` with a unified per-agent result schema,
- `doctor.json` with consolidated failure classes.

The runner prepares the checkout, but the agent instruction itself must perform:

- `git pull --ff-only` on its reserved `agent/<tool>` branch,
- the code change and `python3 -m pytest -q`,
- `git commit`,
- `git push` back to its own branch.

When `--reset-agent-branches` is set, the runner first performs an explicit,
destructive preflight on the stack-managed Forgejo reference repository
`eight-queens-agent-e2e`:

- it verifies that `main` still contains the seeded problem-only baseline
  (`solve_eight_queens()` remains unimplemented);
- it force-resets only the selected `agent/<tool>` remote branches to the exact
  `main` commit;
- it records preflight artefacts under `_preflight/` before invoking any agent;
- each prepared workspace must start from that reset commit and still fail
  `python3 -m pytest -q` before the agent fixes the code.

Without the flag, the runner leaves remote agent branches untouched.

The runner then verifies that:

- the branch head changed relative to the prepared checkout,
- local `HEAD` matches `origin/agent/<tool>`,
- the worktree is clean after the push.

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
