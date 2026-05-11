# Runbook: Utiliser `agentic-codex` (debutant)

Ce guide explique comment utiliser le service `agentic-codex` sans jargon.
Objectif: savoir ouvrir une session, comprendre `tmux`, et gerer correctement `mon-projet`.

## 1) `agentic-codex`, c'est quoi?

- C'est un conteneur de travail CLI dedie a l'usage Codex.
- Entree standard: `./agent codex [mon-projet]`.
- Le conteneur garde un etat persistant entre les sessions:
  - `${AGENTIC_ROOT}/codex/state`
  - `${AGENTIC_ROOT}/codex/logs`
  - `${AGENTIC_CODEX_WORKSPACES_DIR}`
- En `strict-prod`, `AGENTIC_ROOT=/srv/agentic`.
- En `rootless-dev`, `AGENTIC_ROOT=${HOME}/.local/share/agentic`.
- En `strict-prod`, le chemin workspace par defaut est `${AGENTIC_ROOT}/codex/workspaces`.
- En `rootless-dev`, le chemin workspace par defaut est `${AGENTIC_ROOT}/agent-workspaces/codex/workspaces`.

## 2) Prerequis minimum

Depuis le repo:

```bash
./agent up core
./agent up agents
./agent ls
```

Tu dois voir `codex` avec un statut `up` (ou equivalent) dans `./agent ls`.

## 3) `tmux`, c'est quoi (et pourquoi c'est important ici)?

`tmux` est un multiplexeur de terminal:
- il garde une session shell vivante en arriere-plan,
- meme si ta connexion SSH se coupe,
- et tu peux te re-attacher plus tard.

Dans cette stack:
- `agentic-codex` utilise une session `tmux` nommee `codex`,
- `./agent codex mon-projet` cree ou re-attache cette session.

Commandes utiles dans `tmux`:
- detacher sans fermer: `Ctrl+b`, puis `d`
- nouvelle fenetre: `Ctrl+b`, puis `c`
- fenetre suivante: `Ctrl+b`, puis `n`
- fenetre precedente: `Ctrl+b`, puis `p`

## 4) `mon-projet`: ce que ca veut dire concretement

`mon-projet` est le nom du dossier de travail dans l'espace `codex`.

Exemple:

```bash
./agent codex mon-projet
```

Le dossier vise est:
- dans le conteneur: `/workspace/mon-projet`
- sur l'hote: `${AGENTIC_CODEX_WORKSPACES_DIR}/mon-projet`

Comportement:
- si le dossier n'existe pas: il est cree automatiquement,
- si le dossier existe deja: tu reviens dans le meme dossier (historique de fichiers conserve).

Important:
- ce n'est pas un "objet projet" special de Docker ou Codex, c'est un dossier.
- tu peux y mettre un repo git existant, ou demarrer un nouveau projet vide.

## 5) Nouveau projet vs ancien projet

### Cas A: nouveau projet

```bash
./agent codex projet-neuf
```

Effet:
- creation de `${AGENTIC_CODEX_WORKSPACES_DIR}/projet-neuf`,
- ouverture/attache de la session `tmux` `codex`,
- positionnement dans `/workspace/projet-neuf`.

### Cas B: projet deja existant

```bash
./agent codex projet-neuf
```

Effet:
- aucun reset des fichiers,
- tu retrouves le meme dossier sur disque.

### Cas C: pas de nom fourni

```bash
./agent codex
```

Le nom est detecte automatiquement (ordre):
1. `AGENT_PROJECT_NAME` si defini,
2. nom du repo git courant,
3. sinon nom du dossier courant.

Le nom auto-detecte est nettoye (espaces/caracteres speciaux remplaces par `-`).

## 6) Pas a pas local (machine hote)

```bash
cd /home/vuissoz/wkdir/dgx-spark-agentic-stack
./agent up core
./agent up agents
./agent codex mon-projet
```

Une fois dans la session:

```bash
pwd
ls -la
```

La commande `codex` est incluse dans l'image agent par defaut; lance-la depuis ce shell.

## 7) Utilisation depuis un poste externe (Tailscale)

Pour `codex` (CLI), pas besoin de tunnel de port HTTP.
Le chemin normal est SSH sur l'hote Tailscale, puis `./agent codex`.

```bash
ssh -t <user>@<host-ou-ip-tailscale>
cd /home/vuissoz/wkdir/dgx-spark-agentic-stack
./agent codex mon-projet
```

Pour quitter sans arreter la session:
- `Ctrl+b`, puis `d`

Pour revenir plus tard:

```bash
ssh -t <user>@<host-ou-ip-tailscale>
cd /home/vuissoz/wkdir/dgx-spark-agentic-stack
./agent codex mon-projet
```

## 8) Commandes utiles au quotidien

```bash
./agent ls
./agent logs codex
./agent stop codex
```

Dans `./agent ls`, la colonne `runtime` de `codex` montre aussi le mode sandbox effectif:
- `sandbox=native-userns`: le sandbox namespace natif est disponible dans le conteneur.
- `sandbox=outer-container-bypass`: Codex bascule sur le fallback stack-managed; les workflows repo restent supportes, mais pas le sandbox userns natif.

Preparer la session sans attacher (automation):

```bash
AGENT_NO_ATTACH=1 ./agent codex mon-projet
```

## 9) Points de vigilance (debutant)

- `./agent codex` attache une session `tmux` unique nommee `codex`.
- Changer `mon-projet` change surtout le dossier courant de cette session.
- Si tu attaches la meme session depuis plusieurs terminaux, tu partages le meme environnement.
- Ne cherche pas `http://...` pour `codex`: c'est un service CLI, pas une UI web.

## 10) Troubleshooting rapide

- Erreur "service not running":
  - lance `./agent up agents`.
- Erreur de droits sur `${AGENTIC_ROOT}`:
  - verifier le profil avec `./agent profile`,
  - en `strict-prod`, executer les commandes avec privileges adaptes.
- Tu ne retrouves pas tes fichiers:
  - verifier le nom utilise dans `./agent codex <nom>`,
  - verifier le chemin `${AGENTIC_CODEX_WORKSPACES_DIR}/`.
