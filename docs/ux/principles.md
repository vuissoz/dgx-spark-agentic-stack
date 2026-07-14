# UX Principles — DGX Spark Agentic Platform v2

**Status:** active  
**Date:** 2026-07-13  
**Author:** Platform team  

## Guiding principles (from PLAN.md §15.5.1)

1. **User-first vocabulary:** Always present the user's goal and terminology first, never infrastructure internals (Docker, containers, internal ports, service names).
2. **Hide infrastructure:** Docker, OpenShell, container names, internal ports must not appear in ordinary user flows.
3. **Simple primary path, progressive disclosure:** Offer one clear path forward; expose advanced functions only when needed.
4. **Safe defaults:** All defaults must be secure, understandable, and reversible.
5. **Visible state:** Make waiting, progress, next steps, and action consequences visible.
6. **Reversibility:** Where technically possible, support undo, retry, resumption, or rollback.
7. **Consistent terminology:** Use the same terms across portal, CLI, API, and native interfaces.
8. **Actionable errors:** Errors must identify the genuinely responsible component without exposing internal complexity.
9. **No unnecessary manual steps:** Avoid manual operations that don't represent a real user decision.
10. **Ordinary vs expert mode:** Clearly distinguish ordinary user flows from break-glass/expert operations.

## Non-goals

- Reproducing v1's interface by default without explicit justification (PLAN.md §15.5).
- Exposing infrastructure details in ordinary workflows.
- Adding portal features solely because a service or API exists elsewhere.

## Cross-references

- PLAN.md §15.5 — Governance de l'expérience utilisateur et décisions de conception
- PLAN.md §15.5.2 — Détection des choix UX structurants
- ADR registry: `docs/decisions/`
