# Workflow n8n PubMed — IADI / U1254 / CIC-IT Nancy

Le workflow `examples/optional/n8n-workflows/pubmed-iadi-last-14-days.json` est déclenché par le bouton **Execute workflow** dans n8n. Il interroge les E-utilities officielles de PubMed sur les 14 derniers jours, récupère les notices, demande une synthèse au modèle local via `ollama-gate`, puis renvoie les liens PubMed, DOI et PDF PMC lorsqu’ils existent.

## Installation

1. Démarrer n8n avec `AGENTIC_OPTIONAL_MODULES=n8n ./agent up optional`.
2. Importer le fichier JSON depuis **Workflows → Import from File**.
3. Vérifier que le modèle indiqué par `N8N_INSTANCE_AI_MODEL` existe avec `curl http://127.0.0.1:11435/v1/models` ou `./agent doctor`.
4. Ouvrir le workflow et cliquer **Execute workflow**.

Le workflow évite l’AI Assistant n8n : l’AI Assistant peut annuler une requête si son alias de modèle n’existe pas ou si son délai est trop court. Le modèle est envoyé directement à l’endpoint OpenAI-compatible local avec un délai de trois minutes.

## PDF et capture de première page

PubMed n’héberge pas systématiquement le PDF. Le workflow ajoute `pdfUrl` uniquement quand un identifiant PMC est présent et signale les autres cas. La capture de la première page doit être faite depuis le PDF libre indiqué; automatiser une capture pour tous les éditeurs nécessiterait un service de rendu PDF séparé et autorisé par leurs conditions d’accès.

Si la synthèse échoue, vérifier dans n8n la sortie **Local AI synthesis**, puis les logs `./agent logs n8n`. Tester d’abord le modèle avec `curl http://127.0.0.1:11435/v1/models` et remplacer `N8N_INSTANCE_AI_MODEL` par un identifiant réellement listé.
