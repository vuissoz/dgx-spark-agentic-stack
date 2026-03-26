# Onboarding Ultra-Simple `strict-prod` (FR)

Public vise: non-tech complet ou operateur debutant.
But: demarrer et verifier la stack en mode `strict-prod` sans se perdre dans les details.

## 1) En une phrase

`strict-prod` est le mode "serieusement exploitable": runtime sous `/srv/agentic`, commandes en pratique avec `sudo`, et controles de conformite plus stricts.

## 2) Ce qu'il faut retenir

1. Les donnees vivent sous `/srv/agentic`.
2. Les services restent exposes en `127.0.0.1` seulement.
3. `core` inclut aussi OpenClaw et `gate-mcp`.
4. `./agent doctor` doit etre vert avant de considerer le deploiement sain.

## 3) Les commandes minimales

```bash
export AGENTIC_PROFILE=strict-prod
sudo ./deployments/bootstrap/init_fs.sh
sudo ./agent profile
sudo -E ./agent first-up
sudo ./agent doctor
```

Si tu veux le chemin explicite:

```bash
sudo ./agent up core
sudo ./agent up agents,ui,obs,rag
```

## 4) Comment verifier rapidement

- `sudo ./agent doctor`
- `sudo ./agent ls`
- `sudo ./agent ps`

Si un service pose probleme:

```bash
sudo ./agent logs <service>
```

## 5) Regles simples

- Ne pas utiliser `rootless-dev` comme reference de chemins.
- Ne pas oublier `sudo`.
- Ne jamais exposer en `0.0.0.0`.
- Ne jamais monter `docker.sock`.

## 6) Mise a jour et retour arriere

```bash
sudo ./agent update
sudo ./agent rollback all <release_id>
```

## 7) Aller plus loin

- Guide debutant: `docs/runbooks/strict-prod-pour-debutant.md`
- Procedure complete: `docs/runbooks/first-time-setup.md`
- Validation VM: `docs/runbooks/strict-prod-vm.md`
