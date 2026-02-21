# Runbook: Dedicated VM for `strict-prod`

This runbook creates a dedicated VM for prod-like validation (`PLAN.md`, V1).

## 1. Prerequisites

- Host has Multipass installed (`multipass` command available).
- Host has enough free CPU/RAM/disk for your VM sizing.
- If GPU validation is required, your hypervisor path must expose GPU to the VM.

## 2. Create the VM

From the repository root:

```bash
./agent vm create --name agentic-strict-prod --cpus 12 --memory 48G --disk 200G
```

Memory is explicit and configurable by design (`--memory`).

### Useful flags

- Reuse existing VM instead of failing:

```bash
./agent vm create --name agentic-strict-prod --reuse-existing
```

- Enforce GPU visibility (`nvidia-smi` must work in VM):

```bash
./agent vm create --name agentic-strict-prod --memory 48G --require-gpu
```

- Skip guest package bootstrap:

```bash
./agent vm create --skip-bootstrap
```

- Preview only (no changes):

```bash
./agent vm create --memory 32G --dry-run
```

## 3. Enter the VM

```bash
multipass shell agentic-strict-prod
```

The repo is mounted by default at:

- `/home/ubuntu/dgx-spark-agentic-stack`

## 4. Bootstrap `strict-prod` inside the VM

```bash
export AGENTIC_PROFILE=strict-prod
cd /home/ubuntu/dgx-spark-agentic-stack
sudo ./deployments/bootstrap/init_fs.sh
sudo ./agent up core
sudo ./agent up agents,ui,obs,rag
sudo ./agent doctor
```

## 5. GPU check

Inside the VM:

```bash
nvidia-smi
```

If GPU is missing and you need strict GPU validation:
- stop and reconfigure passthrough in your hypervisor,
- rerun VM creation with `--require-gpu` to enforce the check.
