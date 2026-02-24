# Runbook: Dedicated VM for `strict-prod`

This runbook creates a dedicated VM for prod-like validation (`PLAN.md`, V1).

## 1. Prerequisites

- Host has Multipass installed (`multipass` command available).
- Host has enough free CPU/RAM/disk for your VM sizing.
- If GPU validation is required, your hypervisor path must expose GPU to the VM.

What is Multipass:
- Multipass is a lightweight VM manager (by Canonical) that lets you create and run Ubuntu VMs from the CLI.
- In this repo, `agent vm create`, `agent vm test`, and `agent vm cleanup` use Multipass as the VM provider.

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

## 3b. Check whether the VM is running

From the host:

```bash
multipass list
multipass info agentic-strict-prod
```

Expected:
- `State: Running` means the VM is up.
- `State: Stopped` or `State: Suspended` means it is not running.

## 4. Run the full validation campaign from the host

```bash
./agent vm test --name agentic-strict-prod
```

What this campaign does inside the VM:
- `strict-prod` bootstrap (`init_fs.sh`)
- `agent up core`
- `agent up agents,ui,obs,rag` (or degraded no-UI path if GPU is missing and allowed)
- `agent doctor`
- `agent update`
- `agent rollback all <release_id>`
- test selectors (default: `A,B,C,D,E,F,G,H,I,J,K`)
- final `agent doctor` + `agent ps`
- evidence capture under `/srv/agentic/deployments/validation/vm-strict-prod/<timestamp>/`

Useful flags:

- Require GPU and fail otherwise:

```bash
./agent vm test --name agentic-strict-prod --require-gpu
```

- Allow degraded run without GPU passthrough (explicit blocked markers are written in `gpu-status.txt`):

```bash
./agent vm test --name agentic-strict-prod --allow-no-gpu
```

- Restrict test selectors:

```bash
./agent vm test --name agentic-strict-prod --test-selectors A,B,C,F,G,J,K
```

- Preview only:

```bash
./agent vm test --name agentic-strict-prod --dry-run
```

## 5. Inspect generated evidence

From the host:

```bash
multipass exec agentic-strict-prod -- sudo ls -1 /srv/agentic/deployments/validation/vm-strict-prod
```

Inside the VM:

```bash
sudo ls -lah /srv/agentic/deployments/validation/vm-strict-prod/<timestamp>/
sudo cat /srv/agentic/deployments/validation/vm-strict-prod/<timestamp>/campaign.meta
```

## 6. Manual troubleshooting mode (optional)

If you want to run commands manually instead of `agent vm test`:

```bash
export AGENTIC_PROFILE=strict-prod
cd /home/ubuntu/dgx-spark-agentic-stack
sudo ./deployments/bootstrap/init_fs.sh
sudo ./agent up core
sudo ./agent up agents,ui,obs,rag
sudo ./agent doctor
```

## 7. Cleanup the dedicated VM

When the validation campaign is done, stop and delete only the target VM:

```bash
./agent vm cleanup --name agentic-strict-prod
```

Useful flags:

- Non-interactive mode:

```bash
./agent vm cleanup --name agentic-strict-prod --yes
```

- Preview only:

```bash
./agent vm cleanup --name agentic-strict-prod --dry-run
```

After `agent vm cleanup`, you can inspect deleted VM entries and reclaim disk:

```bash
multipass list --all
multipass purge
```

Note: `multipass purge` removes all VMs currently in `Deleted` state.
