# Live DGX Host Validation Checklist

This runbook documents the end-to-end validation steps required before promoting a v2 release from the development (rootless-dev) environment to a physical DGX Spark host. It complements PLAN §15.2 and §15.4 by defining the live runtime checks that cannot be validated statically.

## Pre-requisites

- Physical DGX Spark with NVIDIA GPU driver loaded (`nvidia-smi` works)
- Docker installed (rootless or rootful, matching target deployment mode)
- SSH access to the host
- Latest `dgx-spark-agentic-stack` repo cloned and on the candidate branch
- AGENTIC_PROFILE set to the target profile (`rootless-dev` for dev validation, `strict-prod` for production-like testing)

## Phase 1: Bootstrap & Infrastructure Validation

| # | Step | Command/Check | Pass Criteria |
|---|------|---------------|---------------|
| 1.1 | Host prerequisites | `./agent prereqs` | Exit code 0, all checks green |
| 1.2 | Filesystem layout | `./deployments/bootstrap/init_fs.sh` (rootless-dev) | Directories created under `${AGENTIC_ROOT:-/srv/agentic}` |
| 1.3 | Network isolation | `./agent up core` → check networks are internal | No public binding detected by `./agent doctor` |
| 1.4 | Ollama startup | Verify `ollama` container healthy | Health check passes, model list returns entries |

## Phase 2: Walking Skeleton End-to-End (§14 M3)

| # | Step | Command/Check | Pass Criteria |
|---|------|---------------|---------------|
| 2.1 | Full stack startup | `./agent first-up` (or `./agent up core,agents,ui,obs`) | All expected services reach healthy state within timeout |
| 2.2 | Doctor passes | `./agent doctor` | Exit code 0 — no warnings that are actionable |
| 2.3 | Codex context isolation | `agent codex` → create workspace → verify file visibility | Files accessible in workspace, secrets not exposed |
| 2.4 | CLI tool compatibility | Test each harness: Claude Code, Codex, OpenCode, KiloCode, Vibestral, Hermes | Tool call, streaming, and error handling work via Ollama-compatible endpoints |
| 2.5 | GitHub read access | `gh auth status` or equivalent from inside agent container | Successful authenticated API call to GitHub |
| 2.6 | HuggingFace cache download | Preload a small model (`ollama pull qwen3-coder:0.5b`) | Model pulled and cached in `${AGENTIC_ROOT}/ollama/models` |
| 2.7 | Session recovery | `agent ls` → see running sessions → reconnect | tmux session persists across SSH disconnect/reconnect |

## Phase 3: GPU & Resource Validation (§15.2)

| # | Step | Command/Check | Pass Criteria |
|---|------|---------------|---------------|
| 3.1 | GPU visibility in containers | `docker exec <ollama-container> nvidia-smi` | GPU listed, no errors |
| 3.2 | Model inference with GPU | `agent ollama-chat` → generate a response | Response generated with GPU acceleration visible in metrics |
| 3.3 | Memory pressure test | Run multiple models or high-context requests | No OOM kills; memory stays within limits defined in compose |
| 3.4 | TensorRT-LLM (if enabled) | Verify TRTLLM container starts and is healthy | Health check passes; model listed in `ollama-gate` routes |

## Phase 4: Security & Isolation Validation (§15.1)

| # | Step | Command/Check | Pass Criteria |
|---|------|---------------|---------------|
| 4.1 | No public binds | `ss -tlnp \| grep LISTEN` on host | Only ports bound to 127.0.0.1; no 0.0.0.0 bindings |
| 4.2 | No docker.sock mounts | `docker inspect <agent-container> \| grep docker.sock` | No socket mount found in any agent container |
| 4.3 | Secret file permissions | `ls -la ${AGENTIC_ROOT}/secrets/runtime/` | All secret files are mode 600 or 640, owned by root |
| 4.4 | Capabilities check | `docker inspect --format '{{.HostConfig.CapDrop}}' <container>` | ALL dropped; no dangerous cap_add in agent containers |
| 4.5 | Cross-project RAG isolation | Query RAG with project A's context → verify no project B docs returned | No cross-project document leakage (if RAG enabled) |

## Phase 5: Update, Rollback & Recovery (§14 M3/M4)

| # | Step | Command/Check | Pass Criteria |
|---|------|---------------|---------------|
| 5.1 | Image digests pinned | `./agent update` → verify release snapshot created | New release ID in releases dir with sbom.json, resolved images |
| 5.2 | Rollback | `./agent rollback all <previous-release-id>` → verify services restore | Services reach healthy state; digests match previous release |
| 5.3 | Doctor post-rollback | `./agent doctor` | Exit code 0 after rollback |
| 5.4 | SBOM integrity | Inspect `${AGENTIC_ROOT}/deployments/releases/<id>/sbom.json` | Valid JSON with image references and digests |

## Phase 6: Promotion Gates (§15.4)

Each gate must pass before promotion is authorized:

- **G3U** — Walking skeleton user journeys succeed end-to-end without infrastructure knowledge
- **P0 gates** — No secret leaks, single source of truth, proven recovery, no docker.sock/backend access, correlated audit
- **Pareto front** — Candidate improves at least one metric vs. baseline; no regression in P0/P1 metrics

## Automation Hooks

When running on a CI system or automated pipeline:

```bash
# Full validation run (dry-run on physical hardware):
export AGENTIC_PROFILE=rootless-dev
./deployments/bootstrap/init_fs.sh
./agent first-up
./agent doctor --check-tool-stream-e2e  # requires live container interaction
./agent sbom scan --release-dir "${AGENTIC_ROOT}/deployments/releases/$(python3 deployments/releases/resolve_latest.py --quiet)"
./agent evaluate validate-specs
./agent evaluate run-all

# Result: all exit codes must be 0 for promotion authorization.
```

## Known Limitations (Dry-Run)

Some validations can only be performed on actual hardware:
- GPU inference latency and throughput benchmarks (§15.2 Level 4 endurance tests)
- Real network failure simulation under load
- Temperature/throttling under sustained GPU usage
- Cross-user multi-tenant isolation (single-user DGX Spark)

Document results for each physical validation cycle in `docs/validation/` with date, host serial, driver version, and commit hash.
