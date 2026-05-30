---
name: clawflows
description: Design or adapt multi-step workflows that chain skills, conditions, and handoffs into repeatable automations.
---

# Clawflows

Design or adapt multi-step workflows that chain skills, conditions, and handoffs into repeatable automations.

## Use When
- The user wants a reusable multi-step workflow.
- Several skills must be orchestrated in sequence.
- The process needs branches, gates, or typed inputs/outputs.

## Default Workflow
1. Define the workflow goal, inputs, outputs, and stop conditions.
2. Break the flow into deterministic stages with clear handoffs.
3. Identify which steps are automated versus review-gated.
4. Return the workflow spec, assumptions, and test cases.

## Output
- Return a concise, decision-ready result with assumptions, risks, and recommended next steps.
- If evidence is weak or missing, say so explicitly instead of over-claiming.
