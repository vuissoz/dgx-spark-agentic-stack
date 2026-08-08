# ADR-0147: M10 Scheduler Avancé + Collaboration avec Persistance Fichiers

## Contexte

La section M10 du PLAN.md demande l'implémentation d'un "Scheduler avancé et collaboration" avec les fonctionnalités suivantes :
- Calendrier (Calendar)
- Réservations (Reservations)
- Préemption coopérative (Cooperative Preemption)
- Garde anti-boucle (Anti-loop Detection)
- Intégration avec des plateformes de collaboration (Mattermost, Dify)
- Bots de notification pour les événements du scheduler

## Décision

Nous avons décidé d'implémenter M10 avec une architecture basée sur des fichiers pour la persistance de l'état du scheduler, combinée à une intégration de collaboration via des webhooks et des bots dédiés.

### Architecture Choisie

1. **Persistance par Fichiers** :
   - Utilisation de fichiers JSON pour stocker l'état du scheduler
   - Configuration via `SchedulerConfig.state_dir` et `auto_persist`
   - Méthodes `save_state()` et `load_state()` pour la sérialisation/désérialisation
   - Persistance automatique périodique via `maybe_persist()`

2. **Intégration Collaboration** :
   - **MattermostClient** : Client pour l'envoi de notifications via webhooks Mattermost
   - **DifyClient** : Client pour l'exécution de workflows de collaboration IA
   - **SchedulerNotificationBot** : Bot centralisé avec architecture orientée événements
   - Intégration directe dans le scheduler via `set_collaboration_bot()`

3. **Architecture Événementielle** :
   - Utilisation de threads workers pour le traitement asynchrone des événements
   - Types d'événements structurés : `BotEventType` (SCHEDULED, PREMPTED, COMPLETED, FAILED, etc.)
   - Configuration centralisée via `BotConfig`

## Alternatives Considérées

### Alternative 1: Base de Données Centralisée
- **Pour** : Persistance plus robuste, transactions ACID
- **Contre** : Complexité accrue, dépendance supplémentaire, moins adapté au contexte rootless
- **Décision** : Rejetée en faveur de la simplicité des fichiers pour le contexte actuel

### Alternative 2: Messages Asynchrones (Kafka/RabbitMQ)
- **Pour** : Découplage complet, haute performance
- **Contre** : Infrastructure complexe, surdimensionné pour les besoins actuels
- **Décision** : Rejetée au profit d'une intégration directe via webhooks

### Alternative 3: Intégration Directe sans Bots
- **Pour** : Plus simple à court terme
- **Contre** : Moins extensible, mélange des responsabilités
- **Décision** : Rejetée au profit d'une architecture modulaire avec bots dédiés

## Conséquences

### Positives
- **Simplicité** : Pas de nouvelle dépendance de base de données
- **Rootless-Compatible** : Fonctionne parfaitement dans un environnement rootless
- **Extensibilité** : Architecture modulaire permet d'ajouter d'autres plateformes de collaboration
- **Testabilité** : Facile à tester avec des mocks de webhooks
- **Persistance** : État du scheduler survit aux redémarrages

### Négatives
- **Pas de transactions ACID** : Risque de corruption en cas d'écriture simultanée
- **Performances limitées** : Lecture/écriture de fichiers peut être un goulot d'étranglement
- **Maintenance** : Gestion manuelle de la synchronisation des fichiers

## Implémentation

### Fichiers Créés/Modifiés

1. **`src/agentic/control/scheduler.py`** (+~300 lignes)
   - Ajout de `SchedulerConfig` avec `state_dir` et `auto_persist`
   - Méthodes `save_state()`, `load_state()`, `maybe_persist()`
   - Intégration de la collaboration via `set_collaboration_bot()`
   - Calendrier, réservations, préemption coopérative

2. **`src/agentic/collaboration/__init__.py`** (nouveau)
   - Exports des classes et types du module collaboration
   - `BotConfig`, `BotEvent`, `BotEventType`

3. **`src/agentic/collaboration/mattermost_client.py`** (nouveau, ~228 lignes)
   - `MattermostClient` avec configuration via `MattermostConfig`
   - Envoi de messages via webhooks
   - Gestion des erreurs et timeout

4. **`src/agentic/collaboration/dify_client.py`** (nouveau, ~223 lignes)
   - `DifyClient` avec configuration via `DifyConfig`
   - Exécution de workflows de collaboration
   - Intégration avec les tâches du scheduler

5. **`src/agentic/collaboration/collaboration_bot.py`** (nouveau, ~382 lignes)
   - `SchedulerNotificationBot` avec architecture orientée événements
   - Thread workers pour le traitement asynchrone
   - Gestion des événements de type : SCHEDULED, PREMPTED, COMPLETED, FAILED, CANCELLED

6. **`tests/J19_collaboration_features.py`** (nouveau, ~427 lignes)
   - 5 tests complets pour la persistance et la collaboration
   - Couverture : J19-collab-1 à J19-collab-5

### Contrats et Intégration

- **Intégration Mattermost** : Utilisation de webhooks HTTP standard
- **Intégration Dify** : Appels API REST pour l'exécution de workflows
- **Scheduler** : Événements déclenchés aux points clés du cycle de vie des workloads

## Validation

- **Tests** : J19-collab 5/5 tous passants
- **Total des tests** : 156/156 passants à travers 21 suites (18 Python + 3 shell)
- **Validation rootless-dev** : Confirmée dans l'environnement de test

## Statut

✅ **Complet** - Implémentation terminée et testée
✅ **Intégré** - Intégration avec le scheduler principal
✅ **Documenté** - Documentation dans STATUS.md et ce ADR

## Prochaines Étapes

1. Validation en environnement strict-prod
2. Intégration avec les autres modules (M6-M8) une fois le matériel disponible
3. Amélioration des performances si nécessaire (cache, batching)
4. Ajout de métriques de monitoring pour les notifications de collaboration

## Métadonnées

- **ADR** : 0147
- **Date** : 2026-08-08
- **Auteurs** : Mistral Vibe
- **Statut** : Accepté
- **Version** : 1.0
- **Lié à** : M10, PLAN.md, STATUS.md