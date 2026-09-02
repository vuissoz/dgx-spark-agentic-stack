# ADR-0157 — Tolérer l’installation différée du plugin DuckDuckGo OpenClaw

## Statut

Accepté — 2026-09-02

## Contexte

OpenClaw `2026.8.2` ne contient plus le client DuckDuckGo dans le paquet CLI
principal. Le client est fourni par `@openclaw/duckduckgo-plugin`, dont le
bundle contient un fichier `ddg-client-<hash>.js`. Le plugin est installé dans
les dépendances runtime du profil OpenClaw, et non dans `/opt/openclaw` lors du
build de l’image optionnelle.

L’ancien `--require-match` du patch DDG faisait donc échouer l’image alors que
l’installation OpenClaw et la copie de l’UI étaient correctes.

## Décision

Le Dockerfile utilise `patch_openclaw_ddg.py --allow-missing` au build. Cette
option retourne zéro mais émet un avertissement explicite lorsque le plugin
externe n’est pas encore présent. Le wrapper conserve le patch runtime sur
`.openclaw/plugin-runtime-deps`, là où le plugin peut être installé.

Le mode `--require-match` reste disponible pour les contextes où la présence
du bundle est obligatoire. Les tests couvrent les deux comportements afin de
ne pas transformer une absence inattendue en succès silencieux.

## Conséquences

- Le build `agentic/optional-modules` fonctionne avec OpenClaw `2026.8.2`.
- Le patch POST DuckDuckGo est appliqué dès que le plugin runtime est présent.
- Une installation runtime du plugin doit rester vérifiée par les tests
  d’intégration OpenClaw.
