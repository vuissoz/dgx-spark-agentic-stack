# ADR-0031 - Backlog 2oj/dvo hardening uniformity and deep doctor checks

Date: 2026-02-21

## Context

Backlog issues `dgx-spark-agentic-stack-2oj` and `dgx-spark-agentic-stack-dvo` highlighted two production-readiness gaps:

1. hardening was not fully uniform (some strict-prod services still defaulted to root, and several long-running services had no healthcheck),
2. `agent doctor` deep security checks were mostly focused on agents/optional services instead of all managed running services.

## Decision

1. Add missing healthchecks for long-running services previously uncovered:
   - `toolbox`, `unbound`, `node-exporter`, `cadvisor`, `dcgm-exporter`, `comfyui-loopback`, `optional-portainer`.
2. Move feasible strict-prod defaults to non-root:
   - `qdrant`, `ollama-gate`, `trtllm`, `prometheus`, `loki`, `node-exporter`, `toolbox`, `comfyui-loopback`.
3. Keep explicit root exceptions where technical constraints remain:
   - `ollama`: upstream default path `/root/.ollama` and model-store behavior.
   - `unbound`: privileged DNS bind on port 53 and internal privilege drop model.
   - `egress-proxy` (squid): startup model requires root before dropping to `proxy`.
   - `promtail`: host Docker log access path compatibility in strict-prod.
   - `cadvisor`: host cgroup/filesystem inspection requirements.
   - `dcgm-exporter`: NVIDIA device/driver telemetry access requirements.
4. Update runtime init ownership handling so non-root migrations remain functional:
   - `deployments/core/init_runtime.sh` now chowns gate/trtllm writable paths and gate provider key files to runtime uid/gid.
   - `deployments/rag/init_runtime.sh` now chowns qdrant writable paths to runtime uid/gid in root runs.
   - `deployments/obs/init_runtime.sh` now chowns prometheus/loki writable paths to runtime uid/gid in root runs.
5. Extend `agent doctor` to apply deep checks to every running managed service in the compose project:
   - healthcheck presence + healthy status,
   - docker.sock absence,
   - `cap_drop=ALL` and `no-new-privileges:true`,
   - read-only rootfs policy (with explicit exceptions),
   - non-root user policy (with explicit exceptions),
   - proxy env policy for services that must be proxy-enforced.

## Consequences

- Hardening and liveness checks are now consistently enforceable service-by-service in strict-prod.
- Root exceptions are explicit, constrained, and documented instead of implicit defaults.
- `agent doctor` output is more actionable for production go/no-go decisions because failures now identify the exact offending service and control.
