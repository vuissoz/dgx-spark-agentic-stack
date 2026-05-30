---
name: documentation-builder
description: Create or refactor docs so operators and developers can execute tasks reliably with minimal ambiguity.
---

# Documentation Builder

Create or refactor docs so operators and developers can execute tasks reliably with minimal ambiguity.

## Use When
- The system exists but its docs are weak or fragmented.
- The audience needs reproducible instructions.
- The doc must preserve operational constraints and caveats.

## Default Workflow
1. Define the target audience and tasks the doc must support.
2. Collect the minimum correct steps and invariants.
3. Prefer concrete commands, paths, examples, and failure handling.
4. Return the doc structure plus the missing validation points.

## Output
- Return a concise, decision-ready result with assumptions, risks, and recommended next steps.
- If evidence is weak or missing, say so explicitly instead of over-claiming.
