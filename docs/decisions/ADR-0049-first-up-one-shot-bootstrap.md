# ADR-0049: Commande one-shot `agent first-up` pour le bootstrap initial

## Contexte

Le runbook de premier demarrage demandait une sequence manuelle repetee:

1. `source .runtime/env.generated.sh`
2. `./agent profile`
3. `./deployments/bootstrap/init_fs.sh`
4. `./agent up core`
5. `./agent up agents,ui,obs,rag`
6. `./agent doctor`

Cette sequence etait correcte, mais peu ergonomique pour les utilisateurs non techniques et propice aux oublis (profil non recharge, `doctor` oublie, etc.).

## Decision

Ajouter une sous-commande CLI dediee:

- `./agent first-up`

Comportement:

- charge automatiquement `.runtime/env.generated.sh` (ou `AGENTIC_ONBOARD_OUTPUT`) si present;
- execute les etapes ci-dessus dans l'ordre;
- s'arrete a la premiere erreur avec code non-zero;
- en `strict-prod` non-root, affiche un hint explicite `sudo -E ./agent first-up ...`;
- fournit un mode `--dry-run` pour validation sans action destructive.

## Consequences

- Le chemin "jour 0" devient une seule commande actionnable.
- La sequence reste traçable (logs d'etapes explicites) et compatible avec les garde-fous existants.
- Les runbooks peuvent recommander un flux simple sans supprimer le flux detaille manuel.
