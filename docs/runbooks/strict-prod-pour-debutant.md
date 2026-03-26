# Runbook: `strict-prod` pour debutant

Ce guide explique `strict-prod` sans jargon inutile.
Objectif: comprendre ce que ce mode change, savoir demarrer la stack proprement, et eviter les erreurs classiques.

## 1) `strict-prod`, c'est quoi?

`strict-prod` est le mode operationnel le plus proche du cahier des charges cible.

Ce que cela change:
- la racine runtime est `/srv/agentic`,
- les commandes se font en pratique avec `sudo`,
- les controles host reseau (`DOCKER-USER`) sont attendus,
- `./agent doctor` traite les derives de securite comme des erreurs bloquantes.

En une phrase:
- `rootless-dev` sert a iterer vite,
- `strict-prod` sert a exploiter et valider serieusement.

## 2) Ce que contient la stack actuelle en `strict-prod`

Le baseline est le meme que dans les autres docs, mais ici il est verifie de facon plus stricte.

Plans principaux:
1. `core`
2. `agents`
3. `ui`
4. `obs`
5. `rag`

Point important sur `core`:
- `core` inclut aussi `gate-mcp`,
- et le bloc OpenClaw: `openclaw`, `openclaw-gateway`, `openclaw-sandbox`, `openclaw-relay`.

## 3) Les reflexes a avoir tout de suite

- Toujours verifier le profil actif avec `./agent profile`.
- En `strict-prod`, preferer `sudo ./agent ...` ou `sudo -E ./agent ...`.
- Les fichiers persistants sont sous `/srv/agentic`.
- Si un runbook `rootless-dev` parle de `${HOME}/.local/share/agentic`, ce n'est pas le bon chemin pour toi.

## 4) Demarrage minimal

```bash
export AGENTIC_PROFILE=strict-prod
sudo ./deployments/bootstrap/init_fs.sh
sudo ./agent profile
sudo ./agent up core
sudo ./agent up agents,ui,obs,rag
sudo ./agent doctor
```

Version une commande:

```bash
export AGENTIC_PROFILE=strict-prod
sudo -E ./agent first-up
```

## 5) Comment savoir si tout va bien

Regle simple:
- `sudo ./agent doctor` doit finir sans erreur bloquante,
- `sudo ./agent ls` doit montrer une stack saine,
- les services web restent en loopback (`127.0.0.1`) seulement.

Si quelque chose ne va pas:

```bash
sudo ./agent logs <service>
```

Exemple:

```bash
sudo ./agent logs openwebui
```

## 6) Les fichiers importants

Chemins a retenir:
- `/srv/agentic/proxy/allowlist.txt`
- `/srv/agentic/openwebui/config/openwebui.env`
- `/srv/agentic/openhands/config/openhands.env`
- `/srv/agentic/secrets/runtime/`
- `/srv/agentic/deployments/releases/`
- `/srv/agentic/deployments/current`

Si tu modifies un fichier de configuration sous `/srv/agentic`, fais-le avec les privileges adaptes.

## 7) Mise a jour et rollback

Mise a jour traçable:

```bash
sudo ./agent update
```

Rollback exact:

```bash
sudo ./agent rollback all <release_id>
```

## 8) Les erreurs classiques

- Lancer `./agent up ...` sans `sudo` puis croire que la stack est casse.
- Confondre `/srv/agentic` et `${HOME}/.local/share/agentic`.
- Oublier que `core` contient aussi OpenClaw et `gate-mcp`.
- Modifier des secrets ou des fichiers de config sans permissions suffisantes.
- Utiliser un guide `rootless-dev` mot pour mot alors que tu es en `strict-prod`.

## 9) Si tu veux valider proprement

Le chemin le plus propre pour une validation prod-like est la VM dediee:
- `docs/runbooks/strict-prod-vm.md`

Pour la procedure complete:
- `docs/runbooks/first-time-setup.md`
- `docs/runbooks/profiles.md`

Pour une version encore plus courte:
- `docs/runbooks/onboarding-ultra-simple.strict-prod.fr.md`
- `docs/runbooks/onboarding-ultra-simple.strict-prod.en.md`
