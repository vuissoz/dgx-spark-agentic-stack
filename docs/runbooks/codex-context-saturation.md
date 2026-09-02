# Test de saturation contrôlée du contexte Codex

Ce test est volontairement opt-in et ne fait pas partie des smoke tests. Il
charge progressivement le corpus Jules Verne complet dans une session Codex
unique et s’arrête à 90 % par défaut, avec un arrêt préventif à 95 %.

## Préparer et simuler

```sh
./agent codex saturate-context --dry-run --context-window 131072 --json --verbose
```

Le mode `--dry-run` télécharge le manifest, calcule les morceaux et produit un
rapport sans appeler Codex. Pour une campagne reproductible, fournir un
`--corpus-manifest` local ou un manifest dont les sources et les SHA-256 sont
conservés dans l’artefact.

## Lancer sur la DGX Spark

```sh
./agent codex saturate-context \
  --target-percent 90 \
  --hard-stop-percent 95 \
  --max-chars-per-load-turn 50000 \
  --json --verbose
```

Le rapport est écrit sous `${AGENTIC_ROOT}/codex/logs/context-saturation/`.
`target-reached` est le résultat nominal ; `hard-stop-preflight` signifie que
le prochain morceau aurait dépassé le seuil de sécurité ;
`corpus-exhausted` signifie que le corpus n’a pas suffi. Un refus Codex ou un
timeout reste une erreur de campagne et doit être conservé avec les artefacts.

Ne lancer cette campagne qu’après vérification de la réserve mémoire et du
watchdog. Elle peut être longue et consommer une part importante de la
mémoire unifiée.
