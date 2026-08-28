# Runbook — Assistant n8n local avec sandbox en VM

## Architecture

n8n, SearXNG, Ollama et `ollama-gate` restent dans le stack Docker du DGX.
Toute l'exécution de code de l'Assistant est déplacée dans la VM Multipass
CPU-only `agentic-n8n-sandbox` : certificats mTLS, API, registre, seed d'image,
runner Sysbox, daemon Docker interne et conteneurs de workspace.

Le DGX n'installe ni Sysbox ni libvirt. Multipass 1.16 utilise son backend
QEMU avec `/dev/kvm`. Aucun GPU n'est transmis à la VM.

## Ressources

Valeurs par défaut :

| Ressource | Valeur | Effet attendu |
|---|---:|---|
| vCPU | 4 | suffisant pour les builds de workflows |
| RAM | 8 Gio maximum | ~570 Mio mesurés au repos ; jusqu'à quatre sandboxes de 1 Gio |
| disque | 60 Gio sparse maximum | ~4,4 Gio réellement utilisés après provisioning testé |
| GPU | aucun | Qwen reste sur Ollama dans l'hôte |

La RAM du DGX Spark est unifiée : la mémoire effectivement consommée par la
VM n'est plus disponible pour les modèles GPU. Arrêter la VM libère cette RAM.

## Création

Depuis la racine du dépôt :

```bash
./agent n8n-sandbox-vm create
```

Cette commande génère d'abord les secrets hors Git, crée la VM Ubuntu ARM64,
installe Docker et Sysbox dans le guest, transfère uniquement la configuration
et les secrets nécessaires, puis attend `/healthz`.

Le service `core` doit être actif avant la création : il publie Squid
uniquement sur `127.0.0.1:3128`. Le gestionnaire crée dans la VM une clé SSH
dédiée et ajoute côté hôte une entrée `authorized_keys` limitée au seul
forward vers ce port. Cette clé n'autorise ni shell, ni PTY, ni autre cible.

Dimensionnement personnalisé :

```bash
./agent n8n-sandbox-vm create --cpus 6 --memory 12G --disk 80G
```

État et endpoint privé :

```bash
./agent n8n-sandbox-vm status
./agent n8n-sandbox-vm endpoint
```

L'endpoint doit être de la forme `http://10.x.y.z:8080`. L'API est bindée
uniquement sur cette adresse privée Multipass ; aucun port sandbox n'écoute
sur `0.0.0.0` ou sur les interfaces LAN/Tailscale de l'hôte.

## Démarrage de n8n AI

```bash
./agent up core
export AGENTIC_N8N_AI_MODEL=qwen3.8
AGENTIC_OPTIONAL_MODULES=n8n-ai ./agent up optional
```

Le stack résout automatiquement l'adresse courante de la VM et injecte :

| Champ | Valeur |
|---|---|
| modèle | `qwen3.8` par défaut |
| URL modèle | `http://ollama-gate:11435/v1` |
| provider sandbox | `n8n-sandbox` |
| URL sandbox | endpoint privé Multipass résolu |
| recherche | `http://optional-n8n-searxng:8080` |

La politique `DOCKER-USER` autorise seulement l'IP du conteneur n8n vers
l'IP de la VM sur TCP 8080. Les autres conteneurs ne reçoivent pas cet accès.

## Egress des sandboxes

Les sandboxes peuvent installer des paquets et consulter les destinations
autorisées, mais uniquement via la passerelle Squid monitorée du stack :

1. leur image contient les configurations natives de `apt`, `npm`, `pip`,
   `git`, `curl` et `wget` ;
2. ces outils ciblent `192.0.2.1:3128`, une adresse RFC5737 non routable ;
3. le guest traduit cette adresse vers son tunnel SSH ;
4. le tunnel aboutit au Squid loopback de l'hôte ;
5. Squid applique `${AGENTIC_ROOT}/proxy/allowlist.txt` et écrit
   `${AGENTIC_ROOT}/proxy/logs/access.log`, collecté par Loki lorsque `obs` est actif ;
6. les règles du runner et du guest bloquent toute sortie directe, même si du
   code supprime les variables proxy ou utilise `curl --noproxy`.

Les dépôts Debian/Ubuntu, npm, PyPI, GitHub et les registres déjà nécessaires
au stack sont présents dans l'allowlist de base. Ajouter une destination de
travail revient à ajouter son domaine exact à l'allowlist, puis à redémarrer
`egress-proxy` ; aucun wildcard global n'est requis.

## Vérification

```bash
./agent n8n-sandbox-vm status
./agent doctor
curl -fsS http://127.0.0.1:5678/healthz
```

Inspection du guest :

```bash
multipass exec agentic-n8n-sandbox -- \
  sudo docker compose --project-name n8n-sandbox \
  --env-file /etc/n8n-sandbox/sandbox.env \
  -f /opt/n8n-sandbox/compose.yml ps
```

`doctor` vérifie que Sysbox est absent du Docker hôte, que le runner guest
utilise `sysbox-runc` sans mode privilégié, qu'aucun `docker.sock` n'est monté
et que n8n cible l'endpoint privé sain. Il vérifie également le tunnel, l'image
proxifiée et les chaînes fail-closed d'egress.

L'image ARM64 `latest` vérifiée le 28 août 2026 sert encore son canal HTTP
exec/file sans le TLS déjà décrit par la documentation amont. Ce port n'est
jamais publié : il reste sur le bridge guest `internal` et exige la clé API.
Les canaux d'enregistrement et de contrôle restent en mTLS. Cette exception
doit être retirée dès qu'une image ARM64 alignée est disponible.

## Arrêt, reprise et suppression

```bash
./agent n8n-sandbox-vm stop
./agent n8n-sandbox-vm start
```

La suppression est destructive et explicitement opt-in :

```bash
./agent n8n-sandbox-vm destroy --yes
```

Multipass conserve alors l'image en état `Deleted`. Ne lancer
`multipass purge` qu'après avoir accepté la perte définitive de l'état API,
des certificats, du registre et des workspaces de la VM. Les workflows n8n
restent, eux, dans `${AGENTIC_ROOT}/optional/n8n/data` sur l'hôte.

## Rotation

Arrêter n8n AI et la VM avant de remplacer les fichiers sous
`${AGENTIC_ROOT}/secrets/runtime/n8n-sandbox/`. Rejouer ensuite :

```bash
./agent n8n-sandbox-vm create --reuse-existing
AGENTIC_OPTIONAL_MODULES=n8n-ai ./agent up optional
```

Une rotation de CA impose de déplacer explicitement `/srv/n8n-sandbox/tls`
dans le guest avant reprovisionnement et invalide les sessions en cours.
