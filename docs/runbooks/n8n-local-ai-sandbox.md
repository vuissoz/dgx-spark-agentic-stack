# Runbook — Assistant n8n entièrement local

## Résultat attendu

Le profil `optional-n8n-ai` fournit localement :

- n8n sur `http://127.0.0.1:5678` ;
- `qwen3.8` via `ollama-gate` ;
- l'API et le runner officiels `n8n-sandbox` sous Sysbox ;
- SearXNG pour la recherche de l'Assistant ;
- un registre interne utilisé pour amorcer l'image des sandboxes.

Seul le port n8n est publié, sur loopback. L'API sandbox, le runner, le
registre et SearXNG n'ont aucun port hôte.

## 1. Installer le prérequis Sysbox

Vérifier d'abord :

```bash
docker info --format '{{json .Runtimes}}' | grep sysbox-runc
```

S'il est absent, suivre le
[quickstart Linux officiel n8n](https://github.com/n8n-io/n8n-sandbox-service/blob/main/docs/quickstart-linux.md).
L'installation de Sysbox modifie le runtime Docker de l'hôte et reste donc
une opération administrateur explicite ; le stack ne la lance jamais
automatiquement.

Après installation :

```bash
docker info --format '{{json .Runtimes}}' | jq '.["sysbox-runc"]'
```

## 2. Préparer le modèle local

```bash
docker exec "$(docker ps -qf name=ollama | head -n1)" ollama pull qwen3.8
export AGENTIC_N8N_AI_MODEL=qwen3.8
```

Le nom peut être remplacé par un autre modèle Ollama compatible avec les
tools. La valeur exacte est injectée dans
`N8N_INSTANCE_AI_MODEL`.

## 3. Démarrer le profil

```bash
./agent up core
AGENTIC_N8N_AI_MODEL=qwen3.8 \
  AGENTIC_OPTIONAL_MODULES=n8n-ai \
  ./agent up optional
```

`init_runtime.sh` crée automatiquement :

- `${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox/api.key` ;
- `${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox/registration.token` ;
- `${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox/runner.key` ;
- `${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox/searxng.key` ;
- l'arborescence persistante sous
  `${AGENTIC_ROOT}/optional/n8n/sandbox`.

Ces fichiers sont hors Git et en mode `0600`. Ne pas recopier leurs valeurs
dans un fichier `.env` committé.

## 4. Préconfiguration automatique

Le profil injecte les valeurs suivantes dans n8n :

| Champ UI | Valeur locale |
|---|---|
| Provider modèle | endpoint OpenAI-compatible |
| Base URL modèle | `http://ollama-gate:11435/v1` |
| API key modèle | `local-ollama` |
| Modèle | `${AGENTIC_N8N_AI_MODEL}`, défaut `qwen3.8` |
| Provider sandbox | `n8n-sandbox` |
| Service URL | `http://optional-n8n-sandbox-api:8080` |
| API key sandbox | secret généré `api.key` |
| Recherche | `http://optional-n8n-searxng:8080` |

Il n'est normalement pas nécessaire de remplir l'assistant de configuration
dans l'UI. Une connexion enregistrée manuellement dans les paramètres
d'instance n8n peut toutefois prendre priorité sur les variables
d'environnement ; supprimer cette connexion pour revenir à la configuration
gérée par le stack.

## 5. Vérifier

```bash
./agent doctor
./agent ls
curl -fsS http://127.0.0.1:5678/healthz
```

Contrôles ciblés :

```bash
docker compose -f compose/compose.optional.yml \
  exec optional-n8n wget -qO- \
  http://optional-n8n-sandbox-api:8080/healthz

docker compose -f compose/compose.optional.yml \
  exec optional-n8n wget -qO- \
  'http://optional-n8n-searxng:8080/search?q=n8n&format=json'
```

Le healthcheck sandbox doit retourner un statut sain et le runner doit rester
`privileged=false`, avec `runtime=sysbox-runc`.

## 6. Rotation et arrêt

Pour une rotation, arrêter n8n AI, remplacer séparément les quatre fichiers
secrets par des valeurs aléatoires, conserver le mode `0600`, puis
redémarrer le profil. La rotation des certificats mTLS est destructive pour
les sessions sandbox en cours : sauvegarder puis déplacer explicitement le
dossier `sandbox/tls` avant de relancer le bootstrap.

```bash
./agent stop n8n
```

Ne jamais supprimer `${AGENTIC_ROOT}/optional/n8n/data` lors d'une rotation :
ce dossier contient workflows, credentials et état n8n.
