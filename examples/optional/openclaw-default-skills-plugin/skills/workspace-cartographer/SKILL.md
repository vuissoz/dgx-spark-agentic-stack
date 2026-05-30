---
name: workspace-cartographer
description: Map a codebase or workspace into a usable mental model: key paths, ownership, flows, and hotspots.
---

# Workspace Cartographer

Map a codebase or workspace into a usable mental model: key paths, ownership, flows, and hotspots.

## Use When
- A repo or workspace is unfamiliar.
- The user needs fast orientation before editing.
- Architecture and file layout comprehension matter.

## Default Workflow
1. Identify entrypoints, major directories, and runtime boundaries.
2. Trace the main data and control flows.
3. Highlight hotspots, generated state, and sharp edges.
4. Return a concise map with recommended starting points.

## Output
- Return a concise, decision-ready result with assumptions, risks, and recommended next steps.
- If evidence is weak or missing, say so explicitly instead of over-claiming.
