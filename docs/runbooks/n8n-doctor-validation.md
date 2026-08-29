# Runbook — validation n8n/Ollama par `doctor`

Le workflow géré `DOCTOR - n8n local Ollama validation` vérifie le moteur n8n,
le runtime JavaScript, l'appel interne à `ollama-gate`, l'inférence
`qwen3.8:27b` et le parsing JSON.

Le fichier source est
`examples/optional/n8n-workflows/doctor-n8n-local-ollama-validation.json`.
Il est importé ou mis à jour automatiquement après :

```bash
AGENTIC_OPTIONAL_MODULES=n8n ./agent up optional
```

Le workflow est volontairement inactif : il ne reçoit ni webhook ni trigger
externe. `./agent doctor` l'exécute avec la CLI n8n dans le conteneur déjà
actif. La CLI du sous-processus utilise son propre port de broker local pour ne
pas interférer avec l'instance n8n servie aux utilisateurs.

La sortie attendue est le contrat exact :

```json
{
  "success": true,
  "doctor_status": "PASS",
  "test_id": "N8N-DOCTOR-OLLAMA-001",
  "n8n_execution": "OK",
  "javascript_runtime": "OK",
  "ollama_connection": "OK",
  "qwen_inference": "OK",
  "json_parsing": "OK",
  "response_validation": "OK",
  "backend": "ollama",
  "model": "qwen3.8:27b"
}
```

Augmenter le délai pour un premier chargement de modèle :

```bash
AGENTIC_DOCTOR_N8N_TIMEOUT_SEC=600 ./agent doctor
```

Si le module `n8n` est désactivé, le contrôle est absent de `doctor`. Si le
module est actif, une erreur de workflow, de gate, de modèle ou de JSON rend
`doctor` non conforme.
