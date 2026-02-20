# Security Runbook: OpenClaw Sandbox Egress Pattern (Compose)

This runbook documents a tight egress pattern for upstream OpenClaw gateway deployments in Docker Compose, adapted to this repository guardrails:
- no `docker.sock` mount in containers,
- loopback-only host binds,
- deny-by-default sandbox networking,
- proxy-enforced outbound policy.

## Scope and Guardrails

- The `optional-openclaw` + `optional-openclaw-sandbox` services shipped by this repository implement a minimal optional API/sandbox pair, not the upstream OpenClaw gateway runtime.
- For upstream OpenClaw gateway deployments, keep sandbox traffic fail-closed:
  - default sandbox network is `none`,
  - when egress is needed, force traffic through a dedicated proxy path.
- Do not mount `/var/run/docker.sock` in gateway or helper containers in this repository context.
  - Use a controlled host-side launcher API if sandbox containers must be created dynamically.

## Baseline: No Sandbox Network

Recommended default in OpenClaw config:

```json
{
  "agents": {
    "defaults": {
      "sandbox": {
        "mode": "all",
        "scope": "session",
        "workspaceAccess": "none",
        "docker": {
          "network": "none",
          "capDrop": [
            "ALL"
          ],
          "readOnlyRoot": true,
          "tmpfs": [
            "/tmp",
            "/var/tmp",
            "/run"
          ]
        }
      }
    }
  }
}
```

Result: sandboxed tools have no outbound connectivity by default.

## Controlled Egress Override

When a workflow requires outbound access, switch sandbox network to a dedicated egress segment and set proxy environment variables in sandbox containers.

```json
{
  "agents": {
    "defaults": {
      "sandbox": {
        "docker": {
          "network": "sbx_egress",
          "env": {
            "HTTP_PROXY": "http://egress-proxy:3128",
            "HTTPS_PROXY": "http://egress-proxy:3128",
            "NO_PROXY": "localhost,127.0.0.1,openclaw-gateway"
          }
        }
      }
    }
  }
}
```

Operational note:
- Enforce policy at network and proxy layers, not only via env vars.
- Known upstream behavior can make env injection or `HTTP_PROXY` handling inconsistent in some code paths.

## Compose Network Pattern

Use an isolated network dedicated to sandbox egress mediation:

```yaml
networks:
  internal:
    internal: true
  sbx_egress:
    internal: true
```

Recommended topology:
- sandbox containers attach only to `sbx_egress`,
- `egress-proxy` attaches to `sbx_egress` and to the minimum network needed for upstream access,
- no other sandbox network attachment is allowed.

If host-level enforcement is available, keep a `DOCKER-USER` policy that blocks direct outbound flows that bypass the proxy.

## Browser Service Caveat

Upstream OpenClaw browser-related listeners are typically derived from gateway port:
- `18789` gateway,
- `18791` browser control (`gateway.port + 2`),
- `18792` relay (`gateway.port + 3`),
- optional CDP range `18800-18899`.

These are often loopback-bound. Loopback inside the gateway container is not reachable by sibling sandbox containers by default.

Safer practice:
- keep browser control loopback-only,
- do not widen binds to `0.0.0.0` as a shortcut,
- if browser tooling must be reachable from sandboxed contexts, use explicit allowlists and controlled host/port wiring.

## Verification

Host listener check:

```bash
lsof -nP -iTCP -sTCP:LISTEN | egrep ':(18789|18791|18792|188[0-9]{2})'
ss -lntp | egrep ':(18789|18791|18792|188[0-9]{2})'
```

Proxy bypass check from a sandbox container (without proxy vars):

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
  curl -fsS --noproxy "*" --max-time 8 https://example.com >/dev/null
```

Expected result:
- direct egress fails,
- outbound requests succeed only through allowed proxy routes.
