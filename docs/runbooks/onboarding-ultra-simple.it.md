# Onboarding Ultra-Semplice (IT) - DGX Agentic Stack

Pubblico: persone completamente non tecniche.
Obiettivo: capire la piattaforma ed eseguire le azioni base in sicurezza.

## 1) Riassunto in una frase

Questa piattaforma esegue AI locale, interfacce web e monitoraggio con impostazione sicura (accesso solo locale + traffico in uscita controllato).

## 2) I 6 blocchi principali

1. `core` = cuore tecnico (AI + DNS + proxy).
2. `agents` = assistenti con spazi di lavoro separati.
3. `ui` = schermate web.
4. `obs` = dashboard (salute, log, metriche).
5. `rag` = memoria documentale (ricerca semantica).
6. `optional` = moduli extra attivati solo se servono.

## 3) Endpoint web principali

- OpenWebUI: `http://127.0.0.1:8080`
- OpenHands: `http://127.0.0.1:3000`
- ComfyUI: `http://127.0.0.1:8188`
- Grafana: `http://127.0.0.1:13000`

Importante: sono indirizzi locali. Da un altro computer serve tunnel SSH/Tailscale.

## 4) Comandi minimi

```bash
./agent profile
./agent up core
./agent up agents,ui,obs,rag
./agent ps
./agent doctor
```

Per fermare in modo pulito:

```bash
./agent stack stop all
```

## 5) Come capire se e tutto ok

- `./agent ps` deve mostrare i servizi `Up`.
- `./agent doctor` deve finire senza errori bloccanti.

Se un servizio fallisce:

```bash
./agent logs <service>
```

Esempio:

```bash
./agent logs openwebui
```

## 6) Regole di sicurezza semplici

- Non esporre mai su `0.0.0.0`.
- Non montare mai `docker.sock` nei container applicativi.
- Non mettere segreti in git.
- Usare accesso remoto solo via Tailscale/SSH.

## 7) Aggiornamento e rollback

Aggiornare:

```bash
./agent update
```

Rollback:

```bash
./agent rollback all <release_id>
```

## 8) Documentazione successiva

- Guida dettagliata beginner: `docs/runbooks/services-expliques-debutants.md`
- Guida equivalente in inglese: `docs/runbooks/services-explained-beginners.en.md`
- Setup completo: `docs/runbooks/first-time-setup.md`
