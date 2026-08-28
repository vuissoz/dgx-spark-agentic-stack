# ADR-0151 — n8n sandbox in a local Multipass VM

## Status

Accepted. Supersedes ADR-0150.

## Context

The official n8n Sandbox Service uses an API, a Docker-in-Docker runner and
one container per workspace. Its production Linux path requires Sysbox on the
Docker host. The DGX Spark host runs a recent NVIDIA kernel, Docker and
containerd combination for which Sysbox has unresolved compatibility risks.
Changing that host runtime could also interrupt the GPU stack.

The host already provides Multipass 1.16 with its QEMU backend and KVM
acceleration. NVIDIA does not support GPU passthrough on DGX Spark, but the
sandbox does not need a GPU because inference remains on host Ollama.

## Decision

- Run all sandbox components in a dedicated CPU-only Multipass VM named
  `agentic-n8n-sandbox`.
- Default to 4 vCPU, 8 GiB RAM and a 60 GiB sparse disk.
- Install Sysbox only in the guest and run the official DinD runner with
  `runtime: sysbox-runc`, never `privileged: true`.
- Never mount the host Docker socket or host directories into the VM.
- Keep mTLS bootstrap, API state, registry, image seed, runner state and inner
  Docker state inside the VM.
- Bind the API only to the private Multipass IPv4 address. Permit only the n8n
  container IP to reach that address on TCP 8080 through `DOCKER-USER`.
- Keep the API and registry on an internal guest network. Give the runner a
  dedicated fail-closed egress bridge whose only permitted application path is
  the monitored host Squid proxy.
- Publish Squid only on host loopback. Reach it from the VM through a dedicated
  SSH key restricted to `permitopen="127.0.0.1:3128"`; do not bind a proxy port
  on LAN, Tailscale, or all host interfaces.
- Derive the sandbox image in the private guest registry with native proxy
  configuration for apt, npm, pip, Git, curl, and wget. Present the non-routed
  RFC5737 address `192.0.2.1:3128` inside sandboxes and DNAT it only inside the
  guest, because upstream n8n policy intentionally blocks RFC1918 targets.
- Drop every other forwarded flow from sandbox subnets at both the inner runner
  and guest layers. The Squid allowlist and access log remain the source of
  policy and egress observability.
- The ARM64 `latest` runner image observed on 2026-08-28 serves its HTTP
  exec/file channel without the TLS behavior already documented upstream.
  Use HTTP plus the runner API key only on the guest `internal` bridge until
  an aligned ARM64 image is published. Registration and SandboxControl gRPC
  remain mTLS. Never publish the runner port.
- Keep Ollama/Qwen and SearXNG in the host stack; configure n8n automatically
  with the dynamically resolved private VM endpoint.
- Provide explicit VM lifecycle commands. Destruction requires `--yes` and a
  deleted Multipass VM remains recoverable until an explicit purge.

## Consequences

The VM is capped at 8 GiB of the DGX unified memory by default; the measured
idle footprint after provisioning is about 570 MiB. Its sparse disk is capped
at 60 GiB and initially consumed about 4.4 GiB in the tested installation.
Package caches and workspaces increase both values. Startup is slower than
a host container, but host Docker, CUDA and the NVIDIA runtime remain
unchanged. Guest compromise is constrained by a hardware-virtualized kernel
boundary, at the cost of backing up VM-resident sandbox state separately. Host
Squid logs identify sandbox-VM traffic and destinations, but not individual
sandbox IDs because the restricted SSH tunnel is the aggregation point.
