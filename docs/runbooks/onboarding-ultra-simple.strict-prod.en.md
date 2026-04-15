# Ultra-Simple `strict-prod` Onboarding (EN)

Target audience: non-technical users or junior operators.
Goal: start and verify the stack in `strict-prod` without reading the full operational runbooks first.

## 1) One-sentence summary

`strict-prod` is the "serious operations" mode: runtime under `/srv/agentic`, commands usually run with `sudo`, and compliance checks are stricter.
In the current repo state, it is mainly the final prod-like validation path rather than the fastest daily workflow.

## 2) What to remember

1. Persistent data lives under `/srv/agentic`.
2. Services still bind to `127.0.0.1` only.
3. `core` also includes OpenClaw and `gate-mcp`.
4. `ui` also converges Forgejo, even though the Compose service names still use `optional-forgejo*`.
5. `./agent doctor` must pass before you consider the deployment healthy.

## 3) Minimum commands

```bash
export AGENTIC_PROFILE=strict-prod
sudo ./deployments/bootstrap/init_fs.sh
sudo ./agent profile
sudo -E ./agent first-up
sudo ./agent doctor
```

If you want the explicit step-by-step path:

```bash
sudo ./agent up core
sudo ./agent up agents,ui,obs,rag
```

## 4) Quick verification

- `sudo ./agent doctor`
- `sudo ./agent ls`
- `sudo ./agent ps`

If one service fails:

```bash
sudo ./agent logs <service>
```

## 5) Simple rules

- Do not use `rootless-dev` path examples as-is.
- Do not forget `sudo`.
- Never expose services on `0.0.0.0`.
- Never mount `docker.sock`.

## 6) Update and rollback

```bash
sudo ./agent update
sudo ./agent rollback all <release_id>
```

## 7) Next docs

- Beginner guide: `docs/runbooks/strict-prod-pour-debutant.md`
- Full setup: `docs/runbooks/first-time-setup.md`
- VM validation path: `docs/runbooks/strict-prod-vm.md`
