# Assistant d'initialisation des secrets runtime

`./agent secrets` est le point d'entrée idempotent pour préparer les secrets
des profils actifs. Il lit l'inventaire versionné
`config/secrets.inventory.json` et n'utilise ni l'état Docker, ni les logs, ni
un fichier `.env` comme source de secret.

## Onboarding

Après avoir chargé l'environnement produit par `./agent onboard`, lancer :

```bash
./agent secrets --profiles ui
```

Pour un module optionnel, déclarer le même module que lors du démarrage :

```bash
AGENTIC_OPTIONAL_MODULES=n8n ./agent secrets
AGENTIC_OPTIONAL_MODULES=n8n-ai ./agent secrets
```

L'assistant demande deux fois, avec saisie masquée, uniquement les valeurs
requises absentes. Un fichier déjà valide est seulement contrôlé : son contenu
n'est ni affiché ni réécrit. Un secret optionnel absent est signalé comme tel
sans déclencher de prompt. Les noms d'utilisateur comme
`N8N_BASIC_AUTH_USER` et `COMFYUI_AUTH_USERNAME` sont des paramètres non
sensibles répertoriés séparément dans l'inventaire.

Les chemins sont strictement relatifs à
`${AGENTIC_ROOT}/secrets/runtime/`. L'assistant impose `0700` aux répertoires,
`0600` aux fichiers, la propriété root des répertoires en `strict-prod` et
l'UID/GID `AGENT_RUNTIME_UID:AGENT_RUNTIME_GID` aux fichiers consommés par les
services. En `rootless-dev`, les répertoires appartiennent à l'opérateur. En mode
interactif, une correction de métadonnées est annoncée sans toucher au contenu.
Une correction de propriétaire qui exige davantage de droits échoue avec une
consigne de relance privilégiée.

## Contrôle non interactif et doctor

```bash
./agent secrets --check --profiles ui
AGENTIC_OPTIONAL_MODULES=n8n-ai ./agent secrets --check
./agent doctor
```

`--check` ne crée et ne modifie aucun fichier, ne demande aucune valeur et
retourne un code non nul si un secret requis est absent, vide, invalide ou mal
protégé. La sortie contient uniquement l'identifiant d'inventaire, le chemin et
la correction à effectuer. `./agent doctor` exécute ce contrôle pour le core et
les profils/modules déclarés dans l'environnement.

## Valeur invalide et rotation explicite

Un fichier existant mais invalide n'est jamais remplacé silencieusement.
L'assistant demande une confirmation explicite. Pour une rotation volontaire,
utiliser la commande séparée :

```bash
./agent secrets rotate comfyui-auth-password
./agent secrets rotate n8n-basic-auth-password
```

La nouvelle valeur est saisie et confirmée en mode masqué ; aucune valeur de
secret n'est acceptée en argument. Redémarrer ensuite uniquement le service
concerné, puis relancer `./agent secrets --check` et `./agent doctor`.

Ne jamais copier une valeur dans une commande shell, une issue ou un log. Les
artefacts de release ne doivent contenir que la configuration effective et les
digests, jamais le répertoire `${AGENTIC_ROOT}/secrets/runtime/`.
