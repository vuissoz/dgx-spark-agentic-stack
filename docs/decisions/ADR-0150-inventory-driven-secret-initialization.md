# ADR-0150 — Initialisation des secrets pilotée par inventaire

## Contexte

Les scripts d'initialisation généraient ou demandaient des secrets à plusieurs
endroits. Ce fonctionnement rendait difficile la distinction entre secret
absent, option non activée et valeur déjà conforme, et pouvait provoquer une
ressaisie inutile.

## Décision

- Utiliser `config/secrets.inventory.json` comme inventaire versionné des
  secrets gérés par profil/module, avec chemin runtime et règle de validation.
- Fournir un moteur unique `scripts/secrets_assistant.py`, exposé par
  `./agent secrets`, réutilisé en lecture seule par doctor.
- Activer `core` par défaut ; ajouter les profils via `--profiles` et les
  modules via `AGENTIC_OPTIONAL_MODULES` ou `--modules`.
- Réserver les mutations au mode interactif TTY, avec double saisie masquée.
  `--check` reste strictement non interactif et non mutatif.
- Séparer la rotation volontaire dans `agent secrets rotate <id>`.
- Migrer le mot de passe Basic Auth n8n vers
  `${AGENTIC_ROOT}/secrets/runtime/n8n.auth_password` et son contrat `_FILE`.
  Ce mécanisme est documenté par n8n dans
  <https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration#keeping-sensitive-data-in-separate-files>.

## Conséquences

Les secrets valides ne sont plus réécrits par l'assistant. Les profils
optionnels peuvent être contrôlés avant Compose, et les futurs modules étendent
un inventaire plutôt que d'ajouter une nouvelle logique de prompt. Les anciens
déploiements n8n utilisant uniquement `N8N_BASIC_AUTH_PASSWORD` doivent créer le
fichier via `./agent secrets --modules n8n` avant le prochain démarrage.
