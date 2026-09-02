# Threat Model — DGX Spark Agentic Platform v2

**Status:** draft  
**Date:** 2026-07-13  

## Scope
Single-user DGX Spark deployment. All services bound to `127.0.0.1`. Access via Tailscale on host, proxied through loopback.

## Threat assumptions

| Threat | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Container breakout via docker.sock mount | Low | Critical | No container mounts docker.sock (AGENTS.md Règle zéro) |
| Public network exposure | Low | Critical | All binds to `127.0.0.1` (A3 test, doctor check) |
| Secret leakage in git or logs | Low | High | Secrets via root-only files; doctor scans for secrets |
| Cross-project data leak | Medium | High | Context isolation tested (V2_context_isolation_evidence) |
| Unauthorized model backend access | Medium | High | ModelBroker/router gate enforces policy; no direct backend access from agents |
| Egress bypass from containers | Low | Medium | DOCKER-USER iptables chain; agent proxy allowlist |
| Supply chain via untrusted images | Medium | Critical | Digest-pinned images; SBOM tracking (PLAN.md §17) |
| Model drift without detection | Low | Medium | ollama-drift-watch script monitors model changes |

## Security invariants (non-negotiable)

1. **No `docker.sock` mount** in any agent container — verified by A4 tests and doctor script.
2. **All binds on `127.0.0.1`** — verified by A3 test and doctor script.
3. **`cap_drop: ALL` + `no-new-privileges:true`** on all services (doctor check).
4. **`read_only: true`** on rootfs where possible, documented exceptions only (F21_forgejo_rootfs_exception_contract).
5. **Secrets in git** — never committed; doctor scans tracked files for secret patterns.
6. **No unrestricted egress** — egress flows through proxy with allowlist rules.

## References
- AGENTS.md — Règle zéro: ne pas bricoler la plateforme
- PLAN.md §15.1 — Contrats et sécurité
- PLAN.md §10 — Secrets, GitHub et Hugging Face
- `scripts/doctor.sh` — Automated compliance checks
