---
name: architecture-reviewer
description: Review system architecture for boundaries, failure modes, scalability, operability, and simplicity.
---

# Architecture Reviewer

Review system architecture for boundaries, failure modes, scalability, operability, and simplicity.

## Use When
- A design or architecture proposal needs scrutiny.
- Interfaces, state, and operational behavior matter.
- The goal is to reduce complexity and risk before implementation.

## Default Workflow
1. Map the components, contracts, data flows, and trust boundaries.
2. Stress-test the design under failure, scale, and change.
3. Identify unnecessary coupling, hidden state, and operational traps.
4. Return findings, alternatives, and tradeoff-driven recommendations.

## Output
- Return a concise, decision-ready result with assumptions, risks, and recommended next steps.
- If evidence is weak or missing, say so explicitly instead of over-claiming.
