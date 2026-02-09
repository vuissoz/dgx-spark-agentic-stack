# AGENTS.md — Codex (dev) : implémentation conforme au CDC DGX Spark

Tu es **Codex**, agent de développement. Ta mission est de **livrer un repo exécutable** qui implémente la stack décrite dans le cahier des charges (CDC) DGX Spark : services agentiques conteneurisés, mises à jour fréquentes (`:latest`) mais **traçabilité + rollback stricts**, accès distant **Tailscale-only**, et un socle sécurité/MCO “raisonnable”.

Ce fichier définit les règles de travail et les garde-fous. En cas de conflit entre ce fichier et le CDC, **le CDC prévaut** (et tu documentes le conflit).

---

## Règle zéro : ne pas bricoler la plateforme

- Ne jamais exposer de service sur `0.0.0.0`. Tout bind HTTP/UI doit être sur `127.0.0.1` uniquement.
- Ne jamais monter `docker.sock` dans des conteneurs (OpenHands inclus). Si une fonctionnalité l’exige, tu dois proposer une alternative (API contrôlée) et documenter le risque.
- Ne jamais ajouter d’egress illimité : toute sortie réseau doit être **minimisée** (proxy/allowlist) et justifiée.
- Ne jamais stocker de secrets dans git, ni dans des logs, ni dans des fichiers `.env` committés.

Si une action est destructive (purge volumes, changement réseau, rollback, migration), tu demandes confirmation explicite **ou** tu la rends “opt-in” via un script séparé clairement nommé.

---

## Contexte d’exploitation (invariants)

Plateforme : DGX Spark, Docker/Compose, usage single-user, accès distant via Tailscale, sessions longues via SSH + tmux.

Conventions hôte (ne pas changer sans justification forte) :

- `/srv/agentic/ollama/` : modèles Ollama partagés
- `/srv/agentic/gate/{state,logs}/`
- `/srv/agentic/{claude,codex,opencode}/{state,logs,workspaces}/`
- `/srv/agentic/shared-ro/` et `/srv/agentic/shared-rw/` (si utilisés)
- `/srv/agentic/deployments/{releases,current}/` pour traçabilité + rollback

Commande d’exploitation : un wrapper `agent` masque Docker/Compose :
- `agent codex <project>` ouvre une session tmux dans le conteneur et le workspace
- `agent ls`, `agent logs <tool>`, `agent stop <tool>`
- `agent update` met à jour images / redéploie avec digests
- `agent rollback all <timestamp>` rollback exact
- `agent doctor` diagnostics

Tu dois **implémenter** ces comportements côté repo (scripts), pas juste les décrire.

---

## Objectif “prêt à exécuter” : ce que le repo doit contenir

Le repo doit permettre, sur une machine vierge (mais avec Docker installé), de :

1) déployer la stack en local uniquement (loopback),
2) activer des modules via `profiles` Compose,
3) mettre à jour en gardant traçabilité des digests,
4) revenir en arrière (rollback) de manière déterministe,
5) vérifier la conformité sécurité (script “doctor/compliance”).

### Services à inclure (au minimum)
- Ollama (backend modèles partagé)
- OpenWebUI (UI)
- OpenHands (UI/agent) **sans docker.sock**
- ComfyUI (UI)
- Socle observabilité (Prometheus/Grafana/Loki/… selon CDC)
- Gate/proxy egress (si CDC l’impose) + règles minimales

Les modules optionnels doivent être sous `profiles` (ex : `ui`, `mm`, `rag`, `obs`), et **désactivés par défaut** si non nécessaires au baseline.

---

## Règles d’implémentation (non négociables)

### Docker/Compose
- Tous les services bindés sur `127.0.0.1` (ex : `127.0.0.1:3000:3000`).
- `read_only: true` dès que possible + volumes explicites pour state/logs/workspaces.
- `cap_drop: [ALL]` + `security_opt: ["no-new-privileges:true"]`.
- Healthchecks partout où c’est réaliste (au moins HTTP/TCP).
- Pas d’images “flottantes” en production sans traçabilité : `agent update` doit enregistrer les **digests** réellement déployés.

### Réseau / egress
- Réseau Docker isolé par défaut.
- Si proxy egress : tout egress des conteneurs agents passe par le proxy (allowlist/denylist), et un garde-fou côté hôte (chaîne `DOCKER-USER`) empêche un contournement évident.
- Pas d’exposition publique : l’accès distant passe par Tailscale vers l’hôte, puis vers `127.0.0.1`.

### Secrets
- Secrets via fichiers root-only (`chmod 600`) hors git **ou** variables d’environnement injectées.
- Documenter une politique minimale : rotation, emplacement, procédure.

### Traçabilité / rollback
- Chaque déploiement crée un artefact “release” horodaté (répertoire ou fichier) contenant :
  - les images + digests,
  - la config Compose effective,
  - les versions/outils critiques.
- `agent rollback` restaure exactement une release précédente.

---

## Process de travail attendu (comment tu avances)

Tu travailles en itérations courtes, et tu laisses une trace exploitable :

- À chaque changement significatif : commit atomique, message explicite.
- Toujours garder le repo “vert” : si tu casses quelque chose, tu répares avant d’empiler.
- Toute hypothèse non triviale doit être écrite dans `docs/decisions/` (ADR léger).

Tu ne “négocies” pas le périmètre : si un point du CDC semble trop ambitieux, tu proposes une **implémentation minimale** + un chemin d’extension, sans bloquer la livraison.

---

## Définition de Done (acceptation)

Un livrable est acceptable si, depuis un clone frais :

- `./agent doctor` passe (ports, bind, egress, volumes, users, caps, digests, healthchecks).
- `./agent update` déploie et enregistre les digests.
- `./agent rollback all <timestamp>` restaure une release antérieure fonctionnelle.
- Aucun service n’écoute sur `0.0.0.0`.
- Aucun conteneur n’a `docker.sock`.
- Les états persistants se retrouvent dans `/srv/agentic/...` conformément aux conventions.

---

## Structure recommandée du repo (à respecter)

- `compose/` : fichiers Compose (baseline + overlays/profiles)
- `scripts/` : scripts shell (agent, doctor, update, rollback, backup)
- `docs/` :
  - `docs/runbooks/` (opérations courantes + incident response)
  - `docs/security/` (threat model, supply-chain, secrets)
  - `docs/decisions/` (ADRs)
- `examples/` : exemples de configs non-sensibles
- `Makefile` (optionnel) : alias simples

---

## “Doctor” : script de conformité obligatoire

Tu dois fournir un script (ex : `scripts/doctor.sh`, appelé par `./agent doctor`) qui vérifie au minimum :

- ports bindés sur 127.0.0.1 uniquement
- absence de `docker.sock` dans les mounts
- `cap_drop=ALL` + `no-new-privileges` sur les services sensibles
- `read_only` quand applicable
- présence des healthchecks
- egress conforme (proxy/règles) si activé
- volumes persistants au bon endroit (`/srv/agentic/...`)
- release digests présents et cohérents

En cas d’échec : sortie non-zéro + message actionnable.

---

## Communication minimale

Si tu es bloqué :
- tu écris exactement ce qui manque (commande + sortie),
- tu proposes la solution la plus sûre,
- tu n’ouvres jamais la sécurité “pour avancer”.

Fin.
