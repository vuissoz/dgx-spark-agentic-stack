# Host prerequisites and diagnostics (Step A1)

This checklist validates host readiness before deploying the DGX Spark stack.

## Required tooling

- Docker Engine (daemon reachable)
- Docker Compose v2 (`docker compose`)
- NVIDIA driver + `nvidia-smi` on host
- NVIDIA Container Toolkit (containerized GPU access)
- `iptables` for `DOCKER-USER` enforcement (Step B)

## Minimal diagnostics

Run these commands and keep outputs for incident/debug reports:

```bash
docker version
docker compose version
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi
sudo iptables -S DOCKER-USER
```

Expected result:

- All commands exit with status 0.
- `docker run ... nvidia-smi` prints GPU inventory from inside the container.
- `iptables -S DOCKER-USER` returns chain rules (chain may be empty before deployment).

## Notes

- If the CUDA image is not present locally, Docker will pull it on first run.
- In air-gapped environments, preload required images before running step A tests.
- If host policy restricts writes to `/srv`, run bootstrap with `sudo`.
