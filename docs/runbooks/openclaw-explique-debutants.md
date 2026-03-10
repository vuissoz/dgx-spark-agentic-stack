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
Dans ce depot, OpenClaw est deploie comme module optionnel avec deux services:
- `optional-openclaw`: service API principal,
- `optional-openclaw-sandbox`: backend d'execution d'outils restreint.

Modele mental simple:
1. une requete arrive sur OpenClaw,
2. OpenClaw authentifie et valide,
3. OpenClaw verifie les allowlists de politique,
4. si une action outil est necessaire, il transmet au sandbox,
5. les logs d'audit sont ecrits.

## 2. Pourquoi il y a deux conteneurs

## `optional-openclaw` (API)
- recoit les requetes API,
- applique le token d'auth et le secret webhook,
- verifie l'allowlist DM et le contrat d'endpoints,
- enregistre les evenements d'audit.

## `optional-openclaw-sandbox` (execution)
- execute les actions outils autorisees dans un perimetre plus strict,
- utilise une allowlist dediee,
- n'est pas expose sur une interface hote publique.

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

Les fichiers OpenClaw sont generes/prepares sous `${AGENTIC_ROOT}`:

- `${AGENTIC_ROOT}/secrets/runtime/openclaw.token`
  - token bearer pour auth API,
  - garder le mode `600`.

- `${AGENTIC_ROOT}/secrets/runtime/openclaw.webhook_secret`
  - secret HMAC pour verification de signature webhook,
  - garder le mode `600`.

- `${AGENTIC_ROOT}/optional/openclaw/config/dm_allowlist.txt`
  - cibles DM autorisees.

- `${AGENTIC_ROOT}/optional/openclaw/config/tool_allowlist.txt`
  - actions outils sandbox autorisees.

- `${AGENTIC_ROOT}/optional/openclaw/config/integration-profile.current.json`
  - profil/contrat runtime actif (variables requises et aliases d'endpoints).

- `${AGENTIC_ROOT}/deployments/optional/openclaw.request`
  - fichier d'intention operateur pour le gating optionnel (`need=` et `success=` non vides).

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

## 8. Erreurs frequentes (et correctifs)

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

## 9. Lien avec la CLI upstream `openclaw`

Cette stack s'inspire des workflows upstream OpenClaw,
mais utilise le modele d'orchestration `./agent` du depot.

Mapping rapide:
- upstream `openclaw onboard` -> stack `./agent onboard --optional-modules openclaw`
- upstream `openclaw gateway run` -> stack `AGENTIC_OPTIONAL_MODULES=openclaw ./agent up optional`

## 10. References utiles

- Site OpenClaw: https://openclaw.ai/
- Docs OpenClaw (getting started): https://docs.openclaw.ai/start/getting-started
- Runbook onboarding stack: `docs/runbooks/openclaw-onboarding-rootless-dev.md`
- Guide modules optionnels stack: `docs/runbooks/optional-modules.md`
