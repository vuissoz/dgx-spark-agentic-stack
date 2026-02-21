# Ultra-Einfaches Onboarding (DE) - DGX Agentic Stack

Zielgruppe: komplett nicht-technische Personen.
Ziel: Plattform verstehen und Basisaktionen sicher ausfuhren.

## 1) Ein-Satz-Zusammenfassung

Diese Plattform betreibt lokale KI, Web-Oberflachen und Monitoring mit Sicherheitsfokus (nur lokaler Zugriff + kontrollierter ausgehender Verkehr).

## 2) Die 6 Bausteine

1. `core` = technisches Herz (KI + DNS + Proxy).
2. `agents` = Assistenten mit getrennten Arbeitsbereichen.
3. `ui` = Web-Oberflachen.
4. `obs` = Dashboards (Gesundheit, Logs, Metriken).
5. `rag` = Dokument-Speicher (semantische Suche).
6. `optional` = Zusatzmodule bei Bedarf.

## 3) Wichtige Web-Adressen

- OpenWebUI: `http://127.0.0.1:8080`
- OpenHands: `http://127.0.0.1:3000`
- ComfyUI: `http://127.0.0.1:8188`
- Grafana: `http://127.0.0.1:13000`

Wichtig: Das sind lokale Adressen. Von einem anderen Rechner: SSH-/Tailscale-Tunnel nutzen.

## 4) Minimaler Befehlssatz

```bash
./agent profile
./agent up core
./agent up agents,ui,obs,rag
./agent ps
./agent doctor
```

Sauber stoppen:

```bash
./agent stack stop all
```

## 5) Gesundheitscheck (einfach)

- `./agent ps` sollte Dienste als `Up` zeigen.
- `./agent doctor` sollte ohne blockierende Fehler enden.

Bei Fehlern:

```bash
./agent logs <service>
```

Beispiel:

```bash
./agent logs openwebui
```

## 6) Einfache Sicherheitsregeln

- Nie auf `0.0.0.0` veroffentlichen.
- `docker.sock` nie in App-Container mounten.
- Secrets nie in git speichern.
- Fernzugriff nur uber Tailscale/SSH.

## 7) Update und Rollback

Update:

```bash
./agent update
```

Rollback:

```bash
./agent rollback all <release_id>
```

## 8) Weiterfuhrende Doku

- Detaillierter Beginner-Guide: `docs/runbooks/services-expliques-debutants.md`
- Englischer Beginner-Guide: `docs/runbooks/services-explained-beginners.en.md`
- Komplettes Setup: `docs/runbooks/first-time-setup.md`
