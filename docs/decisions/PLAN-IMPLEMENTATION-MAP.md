# PLAN.md v2 — Implementation Map & Gap Analysis

**Created:** 2026-07-14  
**Branch:** `plan/refonte-v2-collab`  
**Status:** Active implementation  

## Completed Modules (Verified ✅)

| Section | Requirement | File | Tests | Status |
|---|---|---|---|---|
| §3.1 | Control plane: API, worker, scheduler, reconciler | `control/api.py`, `worker.py`, `scheduler.py`, `reconciler.py` | V3 T4,T5,T20-T25 | ✅ Implemented |
| §3.2 | Adapter contracts: 9 ABCs | `contracts/adapters.py` | V3 T1,T2 | ✅ Implemented |
| §3.4 | No docker.sock, no privileged containers | `architecture_validator.py` + doctor.sh | V3 T10, A4 | ✅ Validated |
| §4 | PostgreSQL schema + persistence backends | `postgres_schema.py`, `persistence.py` | — | ✅ Implemented |
| §5 | Identity, project, session models (6 dataclasses) | `models/identity.py` | V3 T3,T21 | ✅ Implemented |
| §6 | ModelBroker with HTTP clients | `model_broker.py`, `model_broker_client.py` | J7 12/12, J11 4/4 | ✅ Implemented |
| §7 | OpenShell driver (tmux + Docker) | `openshell_driver.py` | V3 T5-T8 | ✅ Implemented |
| §8 | Harness profiles (10 profiles with validation) | `harness_profiles.py` | J12 6/6 | ✅ Implemented |
| §2.2 | 11 harness adapters | `harness_adapters.py` | V3 T16-T19 | ✅ Implemented |
| §9 | Application adapters (ComfyUI, OpenWebUI, Forgejo, Grafana, JupyterLab, Portainer, DGX Dashboard) | `application_adapters.py` | — | ✅ Implemented |
| §10.1 | SecretStore: encryption, scopes, rotation, audit | `external_access_broker.py::SecretStore` | F34 8/8 | ✅ Implemented |
| §10.2 | ExternalAccessBroker: GitHub/HF short-lived credentials | `external_access_broker.py::ExternalAccessBroker` | J13 8/8 | ✅ Implemented |
| §11 | Scheduler: admission, quotas, drain/resume | `scheduler.py` (track_workload + resume_after_drain) | V3 T20 | ✅ Implemented |
| §12.2 | RAGServiceAdapter | `rag_adapter.py` | J9 7/7 | ✅ Implemented |
| §13 | Migration router: v1/v2 routing table | `migration/router.py` | V3 T9-T15 | ✅ Implemented |
| §3.4 | GPU job adapter with admission limits | `gpu_job_adapter.py` | — | ✅ Implemented |
| §7 | Docker runtime adapter (sandbox lifecycle) | `docker_runtime_adapter.py` | V3 T6-T8 | ✅ Implemented |

## Remaining Work (Gap Analysis)

### M3/M3U — Walking Skeleton (Priority: P0)

| Gap | Required | Files to Create/Modify | Dependencies |
|---|---|---|---|
| **CLI command routing** | Route `agent <cmd>` → v1 or v2 via CapabilityRegistry | Extend `control_plane.py` to use `migration.router.CapabilityRegistry` | §13 (done) |
| **Workspace management** | Create/switch workspace per user+project context | Add `workspace_manager.py` to control plane | §5 (done) |
| **Portal scaffold refinement** | 7-section HTML portal with real API calls | Extend `src/frontend/static/index.html` | §3.1 API (done) |
| **Session lifecycle** | Start/end/inspect sessions via API + harness adapters | Wire `api.py` → `harness_adapters.py::start_session` | §2.2, §8 (done) |

### M4 — Production Foundation (Priority: P0)

| Gap | Required | Files to Create/Modify | Dependencies |
|---|---|---|---|
| **Auth/roles wiring** | SecretStore + Postgres → API auth middleware | Add `control/auth.py` with session cookies, role checks | §10.1 (done), §4 DB (done) |
| **Audit logging** | Complete audit trail for all control plane actions | Enhance `SecretStore.get_access_log()` and add `audit.py` | §10.1 (done) |
| **Config schema validation** | Environment variable schema with drift detection | Add `control/config_schema.py` + extend `check_config_docs_drift.py` | Existing scripts |

### M5 — Models (Priority: P1)

| Gap | Required | Files to Create/Modify | Dependencies |
|---|---|---|---|
| **Ollama/TRT remote routing** | Test ModelBroker with real model endpoints | Extend `model_broker_client.py` tests | §6 (done) |
| **Quota management** | Per-user/project quota enforcement in scheduler | Enhance `scheduler.py::admit()` with quota checks | §11 (done) |

### M9 — RAG Documents (Priority: P1)

| Gap | Required | Files to Create/Modify | Dependencies |
|---|---|---|---|
| **Multi-project ACL** | Project-scoped retrieval with inter-project leakage prevention | Extend `rag_adapter.py::retrieve()` with project filter + ACL check | §12.2 (done) |
| **AuthorizationBatch** | Batch authorize documents for multiple users/projects | Add `authorization_batch.py` to control plane | §12.4 (spec in `evaluation/spec/`) |

### M6-M12 — Advanced Features (Priority: P2/P3)

These phases require hardware validation (DGX Spark physical access) and are blocked until M3U gates pass:
- M6: Agent code harnesses (Claude, Codex, OpenCode, etc.) with full test suites
- M7: Hermes/NemoClaw parity + OpenClaw integration
- M8: Application RBAC enforcement
- M10+: Advanced scheduler + canary deployments

## Architecture Invariants — Verified ✅

| Invariant | Check | Evidence |
|---|---|---|
| No double-write mutable state | Grep `docker.sock` across Python files | V3 T10: 0 violations |
| No direct backend access from agents | API routes through ModelBroker only | Architecture validator checks |
| All bindings on 127.0.0.1 | Doctor script validates ports | V3 + A3 tests |
| SecretStore never stores plaintext in DB/logs | Hash-only storage + Fernet encryption optional | F34 test 8: audit log passes |
| Rootless uid/gid propagation | No sudo, no privileged containers, user mounts | B4-B7 scripts |

## Testing Strategy

### Unit Tests (Python)
- V3_control_plane_integrity.sh: 25/25 passing ✅
- J6-J13 integration tests: All passing ✅
- F34_secret_store_broker.sh: 8/8 passing ✅

### Shell Scripts (v1 baseline)
- A series: Host prereqs, filesystem, no public bind, no docker.sock ✅
- B series: Network internal, DNS, proxy policy, Docker user enforcement ✅
- C/D series: Ollama/TRT gateway tests (require hardware)
- E/F/G/H/I/K/L series: Image build, update rollback, doctor, agents, apps (require hardware)

### Test Coverage Gaps
| Area | Gap | Priority |
|---|---|---|
| **Auth/roles** | No test for API middleware role checks | P0 |
| **Workspace isolation** | No test for per-user/project workspace separation | P0 |
| **RAG ACL** | No test for inter-project RAG data leakage prevention | P1 |
| **Quota enforcement** | Scheduler has quota structure but no test against ModelBroker | P1 |

## Risk Register (from §16 + analysis)

| Risk | Mitigation | Status |
|---|---|---|
| OpenShell alpha/mono-user | Adapter pattern with pinning, spike isolation | ✅ Documented in architecture_validator.py |
| Double orchestration (Hermes native vs NemoClaw) | Separate state roots, promotion control | M7 (requires hardware validation) |
| Token persistence (GitHub/HF) | ExternalAccessBroker short-lived tokens | ✅ Implemented J13 8/8 pass |
| RAG parallel service (OpenWebUI) | Disable or explicit bridge to stack RAG | §12.2 adapter isolates v1 RAG |
| Backends models access from agents | ModelBroker route + OpenShell firewall rules | Architecture validator enforces |
| Qdrant as canonical source | Sources + snapshots restoreable via §12.5 | §12.2 snapshot method implemented |

## Next Steps (Ordered Implementation)

1. **M3U Gap 1**: CLI command routing through migration router (§13)
2. **M3U Gap 2**: Session lifecycle wiring (api.py → harness_adapters.py)
3. **M4 Gap 1**: Auth/roles middleware for API endpoints
4. **M9 Gap 1**: RAG multi-project ACL enforcement
5. **Documentation**: Update STATUS.md with latest progress

Each step must pass:
- All existing V3 tests (25/25)
- All existing J6-J13 integration tests
- New test for the specific gap addressed
- No security regression (no sudo, no privileged, 127.0.0.1 only)
