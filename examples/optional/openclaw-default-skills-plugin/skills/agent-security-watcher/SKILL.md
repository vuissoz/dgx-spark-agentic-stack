---
name: agent-security-watcher
description: Monitor agent workflows for unsafe permissions, secret handling issues, risky tool use, and policy drift.
---

# Agent Security Watcher

Monitor agent workflows for unsafe permissions, secret handling issues, risky tool use, and policy drift.

## Use When
- An agent stack is gaining capabilities or integrations.
- Security posture must be reviewed continuously.
- The user wants guardrails, not just one-time audit output.

## Default Workflow
1. Map tools, permissions, secrets, egress, and trust boundaries.
2. Look for unsafe defaults, drift, and missing enforcement.
3. Separate immediate exposures from longer-term hardening work.
4. Return detections, guardrails, and operator actions.

## Output
- Return a concise, decision-ready result with assumptions, risks, and recommended next steps.
- If evidence is weak or missing, say so explicitly instead of over-claiming.
