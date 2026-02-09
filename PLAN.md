# PLAN.md — Implémentation du CDC DGX Spark (A→K) par Codex + GPT-5.2

Ce plan est conçu pour être exécuté par un agent de coding (Codex) : chaque sous-tâche produit des artefacts concrets (fichiers, scripts, compose) et **chaque sous-tâche a un test automatique** (script) avec critères d’acceptation binaires. On n’enchaîne pas une étape tant que ses tests ne sont pas verts.

Hypothèses d’exécution : hôte Linux (DGX Spark), Docker Engine + Docker Compose v2, NVIDIA Container Toolkit, accès distant via Tailscale/SSH. Invariant : **aucun service web n’écoute sur `0.0.0.0`** (bind hôte sur `127.0.0.1` uniquement). Les conteneurs communiquent via un réseau Docker privé.

---

## 0) Convention “repo” + harness de tests (à créer avant A)

### 0.1 Arborescence cible sur l’hôte
Tout vit sous `/srv/agentic/` :

- `/srv/agentic/deployments/` : compose, scripts, snapshots (rollback), policies
- `/srv/agentic/bin/agent` : point d’entrée opérateur (commande unique)
- `/srv/agentic/tests/` : tests automatiques (A→K)
- `/srv/agentic/secrets/` : secrets runtime + logs rotation
- `/srv/agentic/{ollama,gate,proxy,dns,openwebui,openhands,comfyui,rag,monitoring}/`
- `/srv/agentic/{claude,codex,opencode}/{state,logs,workspaces}/`
- `/srv/agentic/shared-ro/` et `/srv/agentic/shared-rw/`

### 0.2 Standard “tests”
Chaque test est un script shell idempotent dans `/srv/agentic/tests/` :
- `tests/A_*.sh … tests/K_*.sh`
- retour code `0` si OK, `!=0` sinon
- output lisible (OK/FAIL) + option : JSON dans `deployments/test-reports/<ts>/`

Créer `tests/lib/common.sh` (helpers) :
- `fail()`, `ok()`, `assert_cmd()`, `assert_no_public_bind()`, `assert_container_security()`, `assert_proxy_enforced()`, etc.

### 0.3 Commande unique `agent` (squelette immédiat)
Créer `/srv/agentic/bin/agent` avec au minimum :
- `agent up <core|agents|ui|obs|rag|optional>`
- `agent down <…>`
- `agent ps`
- `agent logs <service>`
- `agent test <A|B|…|K>` (exécute le(s) script(s) correspondants)
- `agent doctor` (agrégat de conformité “doit rester vert”)

**Test automatique** : `tests/00_harness.sh`
- vérifie que `agent test A` appelle bien un script
- vérifie que `agent doctor` existe et retourne `!=0` si aucun compose n’est déployé (mode “pas prêt” explicite)

---

## A — Fondations hôte & arborescence `/srv/agentic`

### A1 Pré-requis Docker/Compose/NVIDIA
**Implémentation**
- documenter dans `deployments/README-host.md` les commandes de diag minimales
- aucun compose à ce stade

**Test** : `tests/A1_host_prereqs.sh`
- `docker version` OK
- `docker compose version` OK
- `nvidia-smi` OK sur l’hôte
- option GPU conteneur : `docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi` OK

### A2 Création arbo + permissions
**Implémentation**
- script idempotent `deployments/bootstrap/init_fs.sh`
  - crée groupe `agentic`
  - crée tous les dossiers sous `/srv/agentic`
  - applique permissions strictes (pas world-readable, secrets isolés)

**Test** : `tests/A2_fs_layout_permissions.sh`
- `test -d /srv/agentic/{deployments,bin,tests,secrets,ollama,gate,proxy,dns}` OK
- `find /srv/agentic -maxdepth 2 -type d -perm -0002` → **vide**
- `/srv/agentic/secrets` : pas accessible “others”, fichiers `600/640` selon besoin

### A3 Invariant “aucun bind 0.0.0.0”
**Implémentation**
- ajouter dans `tests/lib/common.sh` : `assert_no_public_bind()`
- intégrer `assert_no_public_bind` dans `agent doctor`

**Test** : `tests/A3_no_public_bind.sh`
- `ss -lntp` ne doit montrer **aucun** port critique (ex: 11434, 8080, 3000, 8188, 9090, 3100, 9100…) écoutant sur `0.0.0.0`

---

## B — Noyau réseau : réseau privé, DNS interne, proxy egress, enforcement DOCKER-USER

### B1 Réseau Docker privé `agentic`
**Implémentation**
- `deployments/compose/compose.core.yml` :
  - réseau `agentic` avec `internal: true`
  - service “toolbox” minimal (busybox/alpine) pour tests réseau

**Test** : `tests/B1_network_internal.sh`
- `docker network inspect agentic` → `.Internal == true`

### B2 DNS interne (Unbound)
**Implémentation**
- ajouter service `unbound` dans `compose.core.yml` (interne uniquement)
- config dans `/srv/agentic/dns/unbound.conf`

**Test** : `tests/B2_dns_unbound.sh`
- depuis le conteneur toolbox : `drill @unbound example.com` OK
- preuve de non-dépendance DNS externe directe : requête vers `@1.1.1.1` doit échouer (si DOCKER-USER appliqué à ce stade) ou être explicitement bloquée plus tard (B4)

### B3 Proxy egress (allowlist)
**Implémentation**
- ajouter service `egress-proxy` (ex: squid/tinyproxy) dans `compose.core.yml` (interne uniquement)
- policy allowlist : `/srv/agentic/proxy/allowlist.txt`
- logs proxy : `/srv/agentic/proxy/logs/`

**Test** : `tests/B3_proxy_policy.sh`
- depuis toolbox (sans proxy env) : `curl -fsS https://example.com` **échoue**
- depuis toolbox (avec proxy) : `curl -fsS -x http://egress-proxy:3128 https://example.com` :
  - OK si `example.com` allowlisté
  - sinon doit retourner un DENY explicite (acceptable si mode strict) + log présent

### B4 DOCKER-USER : anti-bypass (DROP+LOG)
**Implémentation**
- script idempotent `deployments/net/apply_docker_user.sh`
  - chaîne DOCKER-USER : `ESTABLISHED,RELATED` ACCEPT
  - allow strict : DNS→unbound, HTTP(S)→proxy, LLM→gate (quand gate existe)
  - le reste : LOG rate-limited + DROP
- intégrer `apply_docker_user.sh` dans `agent up core` (ou `agent doctor --fix-net`)

**Test** : `tests/B4_docker_user_enforced.sh`
- `iptables -S DOCKER-USER` contient un DROP final + règle LOG
- tentative d’egress direct (sans proxy) échoue systématiquement
- compteur/log DOCKER-USER augmente après tentative bloquée (preuve d’enforcement)

---

## C — Inference de base : Ollama (local-only)

### C1 Déployer Ollama + volume persistant
**Implémentation**
- ajouter service `ollama` (GPU) dans `compose.core.yml`
- volume : `/srv/agentic/ollama/`
- bind hôte : `127.0.0.1:11434:11434`
- healthcheck HTTP `/api/version`

**Test** : `tests/C1_ollama_basic.sh`
- hôte : `curl -fsS http://127.0.0.1:11434/api/version` OK
- `ss -lntp | grep 11434` → écoute sur `127.0.0.1` uniquement
- interne : `curl -fsS http://ollama:11434/api/version` OK
- health docker : `healthy`

### C2 Smoke test génération
**Implémentation**
- script `deployments/ollama/smoke_generate.sh` (prompt court)
- prévoir modèle minimal de test (ou skip si aucun modèle présent)

**Test** : `tests/C2_ollama_generate.sh`
- POST `/api/generate` retourne 200 + payload non vide (avec timeout court)
- logs ollama présents

---

## D — Point de contrôle LLM : `ollama-gate` (queue/priorités/sticky + logs/metrics)

### D1 Déployer `ollama-gate` devant Ollama
**Implémentation**
- ajouter service `ollama-gate` dans `compose.core.yml` (interne)
- endpoints :
  - compat OpenAI `/v1/*`
  - `/metrics`
- persistance : `/srv/agentic/gate/{state,logs}/`
- config : concurrence=1, queue activée, sticky session via header `X-Agent-Session`

**Test** : `tests/D1_gate_up_metrics.sh`
- `curl -fsS http://ollama-gate:<port>/metrics | grep -q queue_depth` OK
- `/v1/models` répond

### D2 Discipline de concurrence + queue/deny explicite
**Implémentation**
- implémenter comportement “1 actif, le reste queued/denied avec raison”
- logs gate JSON (au minimum : ts, session, project, decision, latency, model_requested, model_served)

**Test** : `tests/D2_gate_concurrency.sh`
- lancer 2 requêtes longues en parallèle :
  - 1 passe, 1 queued/denied (statut vérifié)
- logs contiennent les champs attendus

### D3 Sticky model par session + switch contrôlé
**Implémentation**
- “sticky” : session -> modèle stable sur N requêtes
- endpoint admin interne (option) pour switch explicite

**Test** : `tests/D3_gate_sticky.sh`
- 3 requêtes même session → `model_served` identique
- tentative de changer modèle “à la volée” sans switch → refus/ignorée
- switch explicite → OK + log `model_switch:true`

---

## E — Agents CLI persistants : image `agent-cli-base` + tmux + workspaces

### E1 Construire `agent-cli-base`
**Implémentation**
- `deployments/images/agent-cli-base/Dockerfile`
  - bash, tmux, git, curl, ca-certs
  - user non-root
- pas de docker.sock, pas de privilèges

**Test** : `tests/E1_image_build.sh`
- `docker image inspect agent-cli-base:<tag>` OK
- `.Config.User` non-root

### E2 Déployer `agentic-claude`, `agentic-codex`, `agentic-opencode`
**Implémentation**
- `deployments/compose/compose.agents.yml`
- volumes par outil :
  - `/srv/agentic/<tool>/{state,logs,workspaces}`
- env :
  - `OLLAMA_BASE_URL=http://ollama-gate:<port>`
  - `HTTP(S)_PROXY=http://egress-proxy:3128`
  - `NO_PROXY=ollama-gate,unbound,egress-proxy,localhost,127.0.0.1`
- sécurité conteneur :
  - `read_only: true`, `tmpfs: /tmp`
  - `cap_drop: [ALL]`
  - `security_opt: [no-new-privileges:true]`

**Test** : `tests/E2_agents_confinement.sh`
- `docker exec agentic-claude tmux has-session -t claude` OK (idem codex/opencode)
- `docker inspect` prouve : non-root, readonly rootfs, cap_drop ALL, NNP
- egress : direct KO, via proxy conforme
- écritures : OK dans workspace/state/logs, KO ailleurs

---

## F — Commande unique `agent` + conformité + update/rollback par digest

### F1 Implémenter `agent` (opérations)
**Implémentation**
- compléter `/srv/agentic/bin/agent` :
  - `agent <tool>` : attache tmux, sélection projet (basename git ou dir)
  - `agent ls` : sessions actives + taille workspaces + modèle sticky (si dispo)
  - `agent logs <tool>`
  - `agent stop <tool>`
  - `agent up/down` multi-compose
- stocker config runtime dans `/srv/agentic/deployments/runtime.env` (non committé)

**Test** : `tests/F1_agent_cli.sh`
- `agent ls` fonctionne même si aucune session (retour propre)
- `agent claude` crée/attache une session tmux et workspace projet

### F2 Snapshot par digest + rollback strict
**Implémentation**
- `deployments/releases/snapshot.sh` :
  - capture digests (`docker compose images --digests` ou inspect)
  - copie compose effectifs + runtime.env (sans secrets)
  - enregistre `health_report.json`
- `deployments/releases/rollback.sh <id>` :
  - repin images par digest (ou tags->digests figés)
  - redeploy compose
- journal : `deployments/changes.log`

**Test** : `tests/F2_update_rollback.sh`
- `agent update` crée un snapshot complet (`deployments/releases/<ts>/…`)
- après un “changement” (pull latest), `agent rollback <ts>` restaure exactement les digests
- healthchecks redeviennent `healthy`

### F3 `agent doctor` (gating sécurité)
**Implémentation**
- `agent doctor` agrège :
  - `assert_no_public_bind`
  - DOCKER-USER présent + DROP final
  - proxy enforced (pas d’egress direct)
  - conformité conteneurs agents (non-root, NNP, cap_drop, ro)
  - health des conteneurs critiques

**Test** : `tests/F3_doctor.sh`
- en état nominal : doctor=PASSED
- si on force un bind `0.0.0.0` dans un compose de test : doctor=FAILED
- si DOCKER-USER absent : doctor=FAILED

---

## G — Observabilité : Prometheus + Grafana + Loki + DCGM exporter

### G1 Déployer stack obs
**Implémentation**
- `deployments/compose/compose.obs.yml` :
  - prometheus, grafana, loki, promtail (ou vector), node_exporter, cadvisor, dcgm-exporter
- binds hôte : grafana/prometheus en `127.0.0.1` seulement
- persistance : `/srv/agentic/monitoring/…`

**Test** : `tests/G1_obs_up.sh`
- `curl -fsS http://127.0.0.1:<grafana>/login` OK (et pas sur 0.0.0.0)
- prometheus targets UP via API `/api/v1/targets`
- loki reçoit des logs (query retourne ≥1 entrée)
- métriques GPU (`dcgm_*`) présentes

---

## H — UIs web demandées : OpenWebUI + OpenHands (durci)

### H1 OpenWebUI (auth obligatoire, via gate)
**Implémentation**
- `deployments/compose/compose.ui.yml` : openwebui
- bind hôte : `127.0.0.1:8080`
- auth obligatoire (bootstrap admin)
- backend LLM = `ollama-gate`
- persistance : `/srv/agentic/openwebui/`

**Test** : `tests/H1_openwebui.sh`
- port local-only
- accès sans auth refusé (code cohérent)
- une requête LLM depuis OpenWebUI apparaît dans logs gate (tag/header “client” si configuré)

### H2 OpenHands (pas de docker.sock par défaut)
**Implémentation**
- openhands bind `127.0.0.1:3000`
- persistance `/srv/agentic/openhands/`
- interdiction montage `/var/run/docker.sock`
- option : docker-socket-proxy filtrant (désactivé par défaut, activable étape K)

**Test** : `tests/H2_openhands.sh`
- port local-only
- `docker inspect` : aucun mount docker.sock
- OpenHands utilise gate (preuve logs gate)

---

## I — ComfyUI (GPU) : génération d’images sous contrôle

### I1 Déployer ComfyUI
**Implémentation**
- service comfyui dans `compose.ui.yml` (ou `compose.comfy.yml`)
- bind : `127.0.0.1:8188`
- volumes :
  - `/srv/agentic/comfyui/models`
  - `/srv/agentic/comfyui/input`, `/output`, `/user`
- profil GPU “lowprio” (au moins séparation logique)

**Test** : `tests/I1_comfyui.sh`
- UI répond
- exécuter un workflow “smoke” (API si dispo) produisant un fichier dans `output/`
- port local-only
- downloads éventuels passent par proxy (sinon bloqués)

---

## J — RAG baseline : Qdrant + embeddings via Ollama-gate

### J1 Déployer Qdrant interne
**Implémentation**
- `deployments/compose/compose.rag.yml` : qdrant
- **pas** de port host publié
- persistance : `/srv/agentic/rag/qdrant/`

**Test** : `tests/J1_qdrant.sh`
- aucun publish host sur 6333/6334
- health OK depuis toolbox interne

### J2 Ingestion reproductible + mini-corpus
**Implémentation**
- `/srv/agentic/rag/docs/` corpus test
- `/srv/agentic/rag/scripts/ingest.sh` :
  - embeddings via `ollama-gate`
  - index qdrant
- `/srv/agentic/rag/scripts/query_smoke.sh`

**Test** : `tests/J2_rag_smoke.sh`
- ingestion : nb docs indexés == attendu
- query : retourne ≥N hits
- mode offline : si proxy coupé, RAG continue de fonctionner sur corpus local (sans fetch web)

---

## K — Modules optionnels à risque : Clawdbot / MCP Catalog / Portainer (activation conditionnelle)

Principe : **désactivé par défaut**. Un module n’est activé que si :
- besoin explicite + définition de succès
- il passe la même barre que le noyau (confinement, traçabilité, pas d’expo host, secrets propres)

### K0 Harness “optional gating”
**Implémentation**
- `deployments/compose/compose.optional.yml` (vide par défaut ou services commentés)
- `agent up optional` refuse si `agent doctor` n’est pas vert (garde-fou)

**Test** : `tests/K0_optional_gating.sh`
- `agent up optional` échoue si doctor rouge, passe si doctor vert

### K1 Clawdbot (si activé)
**Implémentation**
- auth token fort (secret runtime)
- DM policy allowlist
- sandbox activée
- egress via proxy + DOCKER-USER
- logs d’audit centralisés

**Test** : `tests/K1_clawdbot.sh`
- endpoint refuse sans token
- actions génèrent logs d’audit
- aucune ouverture `0.0.0.0`
- aucun egress direct possible

### K2 MCP Catalog (si activé)
**Implémentation**
- allowlist stricte des tools
- secrets minimaux dans `/srv/agentic/secrets/runtime`
- pas d’expo host, logs fins

**Test** : `tests/K2_mcp.sh`
- tool non allowlisté → refus
- secrets non présents dans workspaces
- logs centralisés

### K3 Portainer (si activé)
**Implémentation**
- bind local-only
- pas de docker.sock brut : docker-socket-proxy filtrant, ou alternative CLI
- justification d’activation dans `deployments/changes.log`

**Test** : `tests/K3_portainer.sh`
- port local-only
- pas de mount docker.sock direct
- si socket-proxy : seules APIs allowlistées répondent

---

## Définition “terminé” (objectif final)
La stack est “opérable” quand :
- `agent doctor` est vert de façon stable
- egress libre impossible (proxy + DOCKER-USER prouvés)
- Ollama local-only fonctionne et est consommé via `ollama-gate` (queue+sticky+metrics)
- agents CLI persistants (tmux) confinés (non-root, NNP, cap_drop ALL, rootfs ro)
- UIs demandées (OpenWebUI, OpenHands, ComfyUI) bind local + auth, et ne cassent pas la posture
- observabilité exploitable (CPU/RAM/disque/GPU, logs, erreurs proxy, drops DOCKER-USER)
- update/rollback stricts par digest reproductibles

---

## Ordre d’exécution imposé (chemin critique)
A → B → C → D → E → F → G → H → I → J → K

Stop condition générale : si une étape exige des privilèges élevés non compensés (root + caps + accès host), elle reste désactivée, et on documente le refus dans `deployments/changes.log`.

