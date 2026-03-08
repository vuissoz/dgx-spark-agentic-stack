# Runbook: Matrice Agents vs Integrations Ollama (Step 7)

Ce runbook formalise la strategie de compatibilite des integrations agents autour d'Ollama pour:
- `opencode`
- `openclaw`
- `openhands`
- `vibestral`
- `pi-mono`

Source versionnee machine-readable:
- `docs/runbooks/ollama-agent-integration-matrix.v1.json`

## Matrice v1

| Agent | Support upstream `ollama launch` | Source de contrat principale | Mode de configuration stack | Endpoint cible | Variables requises |
| --- | --- | --- | --- | --- | --- |
| `opencode` | `launch-supported` | `docs/integrations/opencode.mdx` | Reconciliation de `~/.config/opencode/opencode.json` + defaults stack (`ollama-gate-defaults.env`) | `http://ollama-gate:11435` | `OLLAMA_BASE_URL`, `OPENAI_BASE_URL`, `OPENAI_API_BASE_URL`, `OPENAI_API_BASE`, `OPENAI_API_KEY`, `AGENTIC_DEFAULT_MODEL` |
| `openclaw` | `launch-supported` | `docs/integrations/openclaw.mdx` | Adapter optionnel inspire launch avec profil versionne (`optional-openclaw`) | `http://optional-openclaw:8111` | `OPENCLAW_AUTH_TOKEN_FILE`, `OPENCLAW_WEBHOOK_SECRET_FILE`, `OPENCLAW_PROFILE_FILE`, `OPENCLAW_SANDBOX_URL`, `OPENCLAW_SANDBOX_AUTH_TOKEN_FILE`, `OPENCLAW_SANDBOX_PROFILE_FILE` |
| `openhands` | `adapter-internal` | Contrat stack (`compose.ui` + onboarding) | Bootstrap `openhands.env` + `settings.json` | `http://ollama-gate:11435/v1` | `LLM_BASE_URL`, `LLM_MODEL`, `LLM_API_KEY`, `AGENTIC_DEFAULT_MODEL` |
| `vibestral` | `adapter-internal` | Contrat stack (`entrypoint` + `compose.agents`) | Generation de `~/.vibe/config.toml` vers `ollama-gate` | `http://ollama-gate:11435/v1` | `AGENTIC_OLLAMA_GATE_V1_URL`, `AGENTIC_DEFAULT_MODEL`, `OLLAMA_BASE_URL` |
| `pi-mono` | `adapter-internal` | Contrat stack (`compose.optional` + `entrypoint`) | Reconciliation de `~/.pi/agent/{models,settings}.json` vers `ollama-gate` | `http://ollama-gate:11435/v1` | `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `AGENTIC_DEFAULT_MODEL` |

## Tests de contrat dedies

### Opencode/OpenClaw: alignement launch/integration
- `tests/L8_ollama_launch_alignment_contracts.sh`
  - valide que la matrice marque `opencode` et `openclaw` en `launch-supported`;
  - valide les sources upstream et commandes launch attendues;
  - execute un drift-watch cible (`--sources opencode,openclaw`) et detecte explicitement une regression d'invariant;
  - valide le contrat de bootstrap opencode (`opencode.json` reconcile sur `ollama/<AGENTIC_DEFAULT_MODEL>` quand le service est lance).

### OpenHands/Vibestral: adapters internes + non-regression
- `tests/L9_ollama_internal_adapter_contracts.sh`
  - valide que la matrice marque `openhands` et `vibestral` en `adapter-internal`;
  - verifie les invariants de config stack (`compose.ui`, `entrypoint`, onboarding);
  - ajoute des assertions runtime opportunistes si les services sont deja lances.

### Pi-mono: adapter interne + regression runtime
- `tests/K4_pi_mono.sh`
  - verifie le contrat runtime `optional-pi-mono` (securite/proxy/mounts),
  - verifie la reconciliation `~/.pi/agent/{models,settings}.json` vers `ollama-gate`,
  - detecte une regression explicite sur provider/API key/model par defaut.

## Ecarts assumes (explicites)

- `openclaw`: la stack n'appelle pas directement `ollama launch openclaw`; elle implemente un adapter optionnel inspire du contrat observable, avec profil versionne bootstrappe au runtime.
- `openhands` et `vibestral`: il n'existe pas de contrat `ollama launch` officiel equivalent; la compatibilite repose sur un adapter interne versionne et teste.

## Contrat de maintenance

- Toute evolution upstream est surveillee via `agent ollama-drift watch`.
- Toute evolution locale doit mettre a jour:
  - `docs/runbooks/ollama-agent-integration-matrix.v1.json`,
  - ce runbook,
  - les tests `L8`/`L9` associes.
