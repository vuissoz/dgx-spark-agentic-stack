# ADR-0121: OpenClaw sub-agent cron policy

## Statut

Accepte

## Contexte

L'operateur veut autoriser la planification `cron` depuis les sub-agents OpenClaw geres par la stack, sans ouvrir l'acces gateway complet ni contourner les garde-fous reseau.

La documentation upstream OpenClaw expose le levier de config suivant pour les sub-agents:

- `tools.subagents.tools.deny`
- `tools.subagents.tools.allow`

Dans cette stack, la config mutable OpenClaw est materialisee depuis:

- un socle immutable,
- un overlay operateur borne,
- un `state` runtime stack-owned.

Le `state` est le bon point d'injection pour une policy de sous-agents qui ne doit pas etre saisie a la main a chaque onboarding.

## Decision

La stack initialise desormais le `state` OpenClaw avec la policy suivante:

- `tools.subagents.tools.deny` conserve `gateway`,
- `tools.subagents.tools.deny` retire `cron`,
- `tools.subagents.tools.allow` ajoute explicitement `cron`.

Cette policy est appliquee par `deployments/core/init_runtime.sh` lors du bootstrap du runtime OpenClaw.

## Consequences

- Les sub-agents OpenClaw recoivent l'intention de policy correcte pour acceder a `cron`.
- L'acces `gateway` reste explicitement refuse aux sub-agents.
- Le changement est idempotent et persiste dans le `state` stack-owned.

## Risques et limites

- Une regression upstream OpenClaw documentee en 2026 indique que `tools.subagents.tools.deny/allow` peut etre acceptee par la config mais ignoree a l'execution selon la version courante.
- En consequence, cette stack pose la bonne configuration, mais l'effet runtime final depend encore du comportement upstream installe dans l'image OpenClaw resolue par `agent update`.
- Si la regression persiste sur la version deployee, le correctif devra etre complete par un contournement stack-side ou par une mise a jour upstream.
