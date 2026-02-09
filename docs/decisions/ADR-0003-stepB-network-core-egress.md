# ADR-0003: Step B network core with internal mesh and host-level anti-bypass

## Status
Accepted

## Context
Step B requires a private Docker network, internal DNS, a controlled egress proxy, and host-level enforcement in `DOCKER-USER` to prevent bypass.

The implementation must remain compatible with the existing repository structure (`compose/`, `deployments/`, `scripts/`, `tests/`) and keep security defaults strict.

## Decision
- Introduce `compose/compose.core.yml` with:
  - `agentic` bridge network in `internal: true`,
  - dual-homed `unbound` and `egress-proxy` services (`agentic` + `agentic-egress`),
  - a `toolbox` container on `agentic` for network tests.
- Use multi-arch images compatible with DGX Spark ARM hosts:
  - `klutchell/unbound:latest` for DNS,
  - `ubuntu/squid:latest` for egress proxy.
- Keep hardening baseline (`cap_drop: [ALL]`, `no-new-privileges`) with minimal capability exceptions required by daemons:
  - `unbound`: `NET_BIND_SERVICE`, `SETUID`, `SETGID`,
  - `egress-proxy`: `SETUID`, `SETGID`.
- Add idempotent runtime bootstrap `deployments/core/init_runtime.sh`:
  - provisions `unbound.conf`, `squid.conf`, and `allowlist.txt` from `examples/core/` only when files are missing.
- Add idempotent firewall policy script `deployments/net/apply_docker_user.sh`:
  - installs a dedicated chain `AGENTIC-DOCKER-USER`,
  - allows only `ESTABLISHED,RELATED`, `DNS -> unbound`, and `HTTP(S) -> egress-proxy`,
  - ends with rate-limited `LOG` and `DROP` to prove enforcement.
- Integrate policy application in `agent up core` and optional repair in `agent doctor --fix-net`.

## Consequences
- Security posture is strict by default: `agent up core` now requires enough privileges to apply iptables policy.
- Operators can preserve local customizations because runtime config files are never overwritten once created.
- Step B acceptance is testable by dedicated scripts `tests/B1_*` to `tests/B4_*`.
