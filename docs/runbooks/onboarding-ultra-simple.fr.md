# Onboarding Ultra-Simple (FR) - DGX Agentic Stack

Public vise: non-tech complet.
But: comprendre ce que fait la plateforme et savoir l'utiliser sans jargon.

## 1) En une phrase

Cette plateforme fait tourner une IA locale, des interfaces web, et des outils de supervision, de maniere securisee (acces local uniquement + controle de sortie reseau).

Ce guide rapide suppose le mode de travail courant: `rootless-dev`.

## 2) Les 6 briques a retenir

1. `core` = le coeur technique (IA + DNS + proxy + services de controle internes comme OpenClaw et `gate-mcp`).
2. `agents` = les assistants qui travaillent dans des espaces separes.
3. `ui` = les ecrans web que vous ouvrez.
4. `obs` = les tableaux de bord (sante, logs, metriques).
5. `rag` = la memoire documentaire (recherche semantique).
6. `optional` = modules additionnels (actives seulement si besoin).

## 3) Les ecrans principaux

- OpenWebUI: `http://127.0.0.1:8080`
- OpenHands: `http://127.0.0.1:3000`
- ComfyUI: `http://127.0.0.1:8188`
- Grafana: `http://127.0.0.1:13000`

Important: ces adresses sont locales. Depuis un autre poste, il faut un tunnel SSH/Tailscale.

## 4) Les commandes minimales

```bash
export AGENTIC_PROFILE=rootless-dev
./agent profile
./agent first-up
./agent ps
./agent doctor
```

Si vous preferez le demarrage etape par etape:

```bash
./agent up core
./agent up agents,ui,obs,rag
```

Pour arreter proprement:

```bash
./agent stack stop all
```

## 5) Sites web accessibles par defaut

La liste de domaines autorises par defaut est dans:
- `examples/core/allowlist.txt` (modele repo)
- `${AGENTIC_ROOT}/proxy/allowlist.txt` (copie runtime active)

Vous pouvez l'afficher avec:

```bash
./agent profile
ROOT="$(./agent profile | sed -n 's/^root=//p')"
cat "${ROOT}/proxy/allowlist.txt"
```

## 6) Comment savoir si tout va bien

Regle simple:
- `./agent ps` doit montrer les services en `Up`.
- `./agent doctor` doit finir sans erreurs bloquantes.

Si un service ne repond pas:

```bash
./agent logs <service>
```

Exemple:

```bash
./agent logs openwebui
```

## 7) Regles de securite faciles

- Ne jamais exposer en `0.0.0.0`.
- Ne jamais monter `docker.sock` dans les apps.
- Garder les secrets hors git.
- Garder l'acces distant via Tailscale/SSH.

## 8) Mise a jour et retour arriere

Mettre a jour:

```bash
./agent update
```

Revenir a une version precedente:

```bash
./agent rollback all <release_id>
```

## 9) Besoin d'aller plus loin

- Guide debutant detaille: `docs/runbooks/services-expliques-debutants.md`
- Guide equivalent en anglais: `docs/runbooks/services-explained-beginners.en.md`
- Installation complete: `docs/runbooks/first-time-setup.md`
- Guide ultra-simple en chinois standard: `docs/runbooks/onboarding-ultra-simple.cn.md`
- Guide ultra-simple en hindi: `docs/runbooks/onboarding-ultra-simple.hi.md`
