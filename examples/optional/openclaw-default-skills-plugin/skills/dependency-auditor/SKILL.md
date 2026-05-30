---
name: dependency-auditor
description: Review dependencies for necessity, update risk, supply-chain exposure, and maintenance posture.
---

# Dependency Auditor

Review dependencies for necessity, update risk, supply-chain exposure, and maintenance posture.

## Use When
- A project has dependency sprawl or upgrade pressure.
- Security and maintenance risk matter.
- You need to justify keep, update, replace, or remove decisions.

## Default Workflow
1. Inventory direct and high-impact transitive dependencies.
2. Assess usage, ownership, update cadence, and known risk signals.
3. Separate must-keep dependencies from removable baggage.
4. Return recommended actions with blast radius and validation steps.

## Output
- Return a concise, decision-ready result with assumptions, risks, and recommended next steps.
- If evidence is weak or missing, say so explicitly instead of over-claiming.
