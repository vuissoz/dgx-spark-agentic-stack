# Runbook: OpenClaw explique pour debutants

Ce document explique OpenClaw en termes simples.
Il est destine aux debutants qui veulent comprendre:
- ce que fait OpenClaw dans cette stack,
- comment il est configure,
- comment l'executer de maniere sure.

Pour la procedure operationnelle complete en `rootless-dev`, voir:
- `docs/runbooks/openclaw-onboarding-rootless-dev.md`

## 1. Ce qu'est OpenClaw (dans cette stack)

OpenClaw peut etre vu comme une couche API controlee pour la messagerie et l'automatisation.
Dans ce depot, OpenClaw est deploie comme module optionnel avec trois services:
- `optional-openclaw`: service API principal,
- `optional-openclaw-sandbox`: backend d'execution d'outils restreint,
- `optional-openclaw-relay`: relay webhook provider avec queue durable et injection locale.

Modele mental simple:
1. une requete arrive sur OpenClaw,
2. OpenClaw authentifie et valide,
3. OpenClaw verifie les allowlists de politique,
4. si une action outil est necessaire, il transmet au sandbox,
5. les logs d'audit sont ecrits.

## 2. Pourquoi il y a trois conteneurs

## `optional-openclaw` (API)
- recoit les requetes API,
- applique le token d'auth et le secret webhook,
- verifie l'allowlist DM et le contrat d'endpoints,
- enregistre les evenements d'audit.

## `optional-openclaw-sandbox` (execution)
- execute les actions outils autorisees dans un perimetre plus strict,
- utilise une allowlist dediee,
- n'est pas expose sur une interface hote publique.

## `optional-openclaw-relay` (ingress provider + queue)
- recoit les webhooks providers signes (`/v1/providers/<provider>/webhook`),
- persiste les evenements en queue fichiers durable,
- re-injecte vers le webhook OpenClaw local avec retries/dead-letter.

Pourquoi cette separation:
- reduire le blast radius,
- separer les concerns API et execution,
- faciliter l'audit de politique.

## 3. Bases securite a connaitre

Protections actives par defaut:
- exposition hote en loopback uniquement (`127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`),
- aucun montage `docker.sock`,
- `cap_drop: ALL`,
- `security_opt: no-new-privileges:true`,
- secrets lus depuis des fichiers sous `${AGENTIC_ROOT}/secrets/runtime`.

Signification debutant:
- `cap_drop: ALL`: retire les capabilities Linux elevees du conteneur,
- `no-new-privileges`: les processus internes ne peuvent pas gagner plus de privileges ensuite,
- bind hote loopback: acces local machine uniquement (pas d'exposition Internet directe).

## 4. Fichiers de configuration principaux

Les fichiers OpenClaw sont generes/prepares sous `${AGENTIC_ROOT}`. Ils sont tous importants, mais pas pour la meme raison:

- secrets d'authentification (`openclaw.token`, `openclaw.webhook_secret`),
- politiques d'autorisation (`dm_allowlist.txt`, `tool_allowlist.txt`),
- contrat runtime (`integration-profile.current.json`),
- preuve d'intention operateur (`openclaw.request`).

Si un de ces fichiers est absent, vide, invalide, ou trop permissif en droits, le module peut etre refuse au demarrage.

### 4.1 `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`

Role:
- token Bearer exige pour les appels API proteges (exemple: `POST /v1/dm`).

Format attendu:
- une ligne texte non vide.

Exemple:
```text
9f4d8b... (chaine aleatoire)
```

Pourquoi il est critique:
- sans ce token, les appels authentifies retournent `401`.
- avec un token faible/expose, n'importe qui ayant acces au host pourrait injecter des requetes.

Bonnes pratiques:
- permissions `600` (ou `640` en environnement controle),
- rotation reguliere,
- ne jamais committer dans git.

### 4.2 `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret`

Role:
- secret partage pour verifier la signature HMAC des webhooks entrants.

Format attendu:
- une ligne texte non vide.

Exemple:
```text
8a23cf... (chaine aleatoire)
```

Pourquoi il est critique:
- empeche les faux webhooks envoyes par un tiers.
- si ce secret fuit, un attaquant peut tenter de forger des signatures valides.

### 4.3 `${AGENTIC_ROOT}/optional/openclaw/config/dm_allowlist.txt`

Role:
- liste des destinations DM autorisees.

Format attendu:
- un identifiant cible par ligne,
- lignes vides et commentaires (`#`) autorises.

Exemple de template:
```text
# One DM target identifier per line.
# Example values: discord:user:1234, slack:U01ABCDE
discord:user:example
```

Effet runtime:
- une cible absente de cette liste est refusee (`403`).
- plus la liste est courte, plus le perimetre est controle.

### 4.4 `${AGENTIC_ROOT}/optional/openclaw/config/tool_allowlist.txt`

Role:
- liste des actions outils que le sandbox a le droit d'executer.

Format attendu:
- un nom d'outil par ligne,
- lignes vides/commentaires autorises.

Exemple de template:
```text
# One sandbox-executable OpenClaw tool per line.
# Keep this list short and reviewed.
diagnostics.ping
time.now_utc
```

Effet runtime:
- un outil non liste est bloque.
- c'est le principal mecanisme de reduction de surface sur la partie "execution".

### 4.5 `${AGENTIC_ROOT}/optional/openclaw/config/integration-profile.current.json`

Role:
- contrat runtime actif OpenClaw/sandbox.
- ce fichier est valide au demarrage; s'il est invalide, demarrage refuse.

Structure importante (resume):
- `profile_id`, `profile_version`, `contract_kind`:
  - identite/version du profil charge.
- `runtime.auth`:
  - exige token bearer + verification HMAC webhook,
  - definit les headers attendus (`X-Webhook-Signature`, `X-Webhook-Timestamp`),
  - definit la fenetre temporelle max (`webhook_max_skew_sec_default`).
- `runtime.required_env`:
  - liste les variables qui doivent exister cote `openclaw` et cote `openclaw_sandbox`.
- `runtime.endpoints`:
  - endpoints acceptes et aliases (exemple: `/v1/dm` et `/v1/dm/send`).
- `runtime.sandbox_policy`:
  - impose proxy env, allowlist outil et healthcheck.
- `runtime.capabilities`:
  - declaration des fonctions de securite et d'audit attendues.

Fichier source/template:
- `examples/optional/openclaw.integration-profile.v1.json`

Conseil:
- ne pas improviser ce JSON a la main.
- partir du template versionne puis ajuster de maniere controlee.

### 4.6 `${AGENTIC_ROOT}/deployments/optional/openclaw.request`

Role:
- trace d'intention operateur pour autoriser l'activation du module optionnel.
- verifiee par `agent up optional` avant demarrage.

Contenu attendu:
```text
need=Enable scoped OpenClaw webhook and DM automation for approved workflows.
success=Webhook auth succeeds, deny paths stay blocked, and service healthcheck stays green.
owner=<utilisateur>
expires_at=
```

Signification des champs:
- `need`:
  - explique le besoin metier/operationnel.
  - doit etre non vide.
- `success`:
  - definit les criteres de succes observables.
  - doit etre non vide.
- `owner`:
  - responsable de la demande d'activation.
- `expires_at`:
  - date de fin de validite optionnelle.

Si `need` ou `success` sont absents/vides:
- l'activation OpenClaw est refusee avec message explicite.

## 5. Variables d'environnement importantes

Variables courantes du service:
- `OPENCLAW_AUTH_TOKEN_FILE=/run/secrets/openclaw.token`
- `OPENCLAW_WEBHOOK_SECRET_FILE=/run/secrets/openclaw.webhook_secret`
- `OPENCLAW_DM_ALLOWLIST_FILE=/config/dm_allowlist.txt`
- `OPENCLAW_TOOL_ALLOWLIST_FILE=/config/tool_allowlist.txt`
- `OPENCLAW_PROFILE_FILE=/config/integration-profile.current.json`
- `OPENCLAW_SANDBOX_URL=http://optional-openclaw-sandbox:8112`
- `OPENCLAW_SANDBOX_AUTH_TOKEN_FILE=/run/secrets/openclaw.token`

En pratique, vous n'editez pas ces chemins conteneur directement.
Vous editez les fichiers cote hote sous `${AGENTIC_ROOT}`.

## 6. Endpoints de base (vue debutant)

Endpoint hote local typique:
- `http://127.0.0.1:${OPENCLAW_WEBHOOK_HOST_PORT:-18111}`

Routes utiles:
- `GET /healthz` -> sante du service
- `GET /v1/profile` -> profil d'integration actif
- `POST /v1/dm` -> envoi DM (auth obligatoire, allowlist appliquee)
- `POST /v1/webhooks/dm` -> webhook DM entrant (politique signature/auth appliquee)

Si l'auth ou l'allowlist est incorrecte, les requetes doivent echouer (`401` ou `403`).
C'est normal et souhaite.

## 7. Workflow debutant typique

1. Preparer environnement et secrets:
```bash
./agent onboard --profile rootless-dev --optional-modules openclaw --output .runtime/env.generated.sh
source .runtime/env.generated.sh
```

2. Demarrer la stack et le module OpenClaw:
```bash
./agent up core
AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional
```

3. Verifier l'etat:
```bash
./agent ls
./agent doctor
./agent logs openclaw
```

4. Editer les politiques si necessaire:
```bash
${EDITOR:-vi} "${AGENTIC_ROOT}/optional/openclaw/config/dm_allowlist.txt"
${EDITOR:-vi} "${AGENTIC_ROOT}/optional/openclaw/config/tool_allowlist.txt"
```

5. Redemarrer les services optionnels apres modification de politique:
```bash
./agent down optional
AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional
```

## 8. Reset "installation neuve" (clean reset)

Si vous voulez retrouver un etat "comme un premier demarrage", il faut supprimer l'etat persistant monte depuis l'hote.

Important:
- ces commandes sont destructives (perte historique sessions/config locale OpenClaw),
- faites un backup avant si vous avez des artefacts a conserver.

### 8.1 Reset CLI seulement (conserve policies + secrets)

Ce mode reset la CLI OpenClaw (home/config/sessions) et les workspaces, mais garde vos fichiers de politique (`dm_allowlist`, `tool_allowlist`, profil) et vos secrets runtime.

```bash
./agent down optional
rm -rf "${AGENTIC_ROOT}/optional/openclaw/state/cli/openclaw-home"
rm -rf "${AGENTIC_ROOT}/optional/openclaw/workspaces"
./deployments/optional/init_runtime.sh
AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional
```

Ensuite, refaire l'onboarding dans le conteneur:

```bash
./agent openclaw
openclaw onboard --workspace /workspace/wizard-default --non-interactive --accept-risk --skip-health --skip-daemon --skip-skills --skip-ui --skip-channels --skip-search
```

### 8.2 Reset complet module OpenClaw

Ce mode reset aussi les logs/queues et les secrets OpenClaw runtime du module optionnel.

```bash
./agent down optional
rm -rf "${AGENTIC_ROOT}/optional/openclaw"
rm -f "${AGENTIC_ROOT}/deployments/optional/openclaw.request"
rm -f "${AGENTIC_ROOT}/secrets/runtime/openclaw.token"
rm -f "${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret"
rm -f "${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.telegram.secret"
rm -f "${AGENTIC_ROOT}/secrets/runtime/openclaw.relay.whatsapp.secret"
./deployments/optional/init_runtime.sh
AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional
```

Apres reset complet:
- verifier/adapter de nouveau les fichiers `dm_allowlist.txt`, `tool_allowlist.txt`, `relay_targets.json`,
- relancer le setup CLI `openclaw onboard ...` dans `./agent openclaw`.

## 9. Erreurs frequentes (et correctifs)

- Erreur: OpenClaw ne demarre pas.
  - Verification: sortie `./agent doctor` et fichier request optionnel.
  - Correctif: verifier `${AGENTIC_ROOT}/deployments/optional/openclaw.request` avec `need=` et `success=` non vides.

- Erreur: appel API en `401`.
  - Verification: contenu token et header d'auth.
  - Correctif: utiliser le bearer token de `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`.

- Erreur: appel API en `403` sur DM.
  - Verification: allowlist des cibles DM.
  - Correctif: ajouter la cible dans `dm_allowlist.txt` puis redemarrer les services optionnels.

- Erreur: echec de validation du profile.
  - Verification: `integration-profile.current.json` existe et est valide.
  - Correctif: restaurer depuis `examples/optional/openclaw.integration-profile.v1.json`.

## 10. Lien avec la CLI upstream `openclaw`

Cette stack s'inspire des workflows upstream OpenClaw,
mais utilise le modele d'orchestration `./agent` du depot.

Mapping rapide:
- upstream `openclaw onboard` -> stack `./agent onboard --optional-modules openclaw`
- upstream `openclaw gateway run` -> stack `AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional`

## 11. References utiles

- Site OpenClaw: https://openclaw.ai/
- Docs OpenClaw (getting started): https://docs.openclaw.ai/start/getting-started
- Runbook onboarding stack: `docs/runbooks/openclaw-onboarding-rootless-dev.md`
- Guide modules optionnels stack: `docs/runbooks/optional-modules.md`
