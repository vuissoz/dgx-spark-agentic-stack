# Onboarding Ultra-Simple (FR) - DGX Agentic Stack

Public vise: non-tech complet.
But: comprendre ce que fait la plateforme et savoir l'utiliser sans jargon.

## 1) En une phrase

Cette plateforme fait tourner une IA locale, des interfaces web, et des outils de supervision, de maniere securisee (acces local uniquement + controle de sortie reseau).

## 2) Les 6 briques a retenir

1. `core` = le coeur technique (IA + DNS + proxy).
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
./agent profile
./agent up core
./agent up agents,ui,obs,rag
./agent ps
./agent doctor
```

Pour arreter proprement:

```bash
./agent stack stop all
```

## 5) Comment savoir si tout va bien

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

## 6) Regles de securite faciles

- Ne jamais exposer en `0.0.0.0`.
- Ne jamais monter `docker.sock` dans les apps.
- Garder les secrets hors git.
- Garder l'acces distant via Tailscale/SSH.

## 7) Mise a jour et retour arriere

Mettre a jour:

```bash
./agent update
```

Revenir a une version precedente:

```bash
./agent rollback all <release_id>
```

## 8) Besoin d'aller plus loin

- Guide debutant detaille: `docs/runbooks/services-expliques-debutants.md`
- Guide equivalent en anglais: `docs/runbooks/services-explained-beginners.en.md`
- Installation complete: `docs/runbooks/first-time-setup.md`
