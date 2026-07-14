# Open UX Questions — DGX Spark Agentic Platform v2

**Last updated:** 2026-07-13

This file tracks open questions that need design reviews (PLAN.md §15.5).

## Currently open

### Q-001: Portal entry point for first-time users
- **Status:** needs-design-review
- **Created:** 2026-07-13
- **Description:** What should the landing page show? Agent list only? Quick-start cards? System health?
- **Alternatives:**
  1. Simple agent list (minimum friction)
  2. Guided walkthrough with system checks first
  3. Dashboard with recent sessions + agent selection
- **Relevant directives:** DXR-001, DXR-002
- **Re-evaluation condition:** When a prototype can be built

### Q-002: Error message format across CLI and portal
- **Status:** proposed
- **Created:** 2026-07-13
- **Description:** Should CLI and portal errors share a common JSON schema? How detailed should they be?
- **Alternatives:**
  1. Shared error schema (implementation cost higher, consistency better)
  2. Per-surface error formats (lower cost, potential inconsistency)
- **Relevant directives:** DXR-003

### Q-003: Multi-agent session sharing UX
- **Status:** proposed
- **Created:** 2026-07-13
- **Description:** How should users perceive multi-agent hierarchies (parent/child runs)? Tree view? Flat list with indentation?
- **Relevant directives:** DXR-002

## Closed questions

*(moved to `docs/ux/decisions/` as UXDR-* when finalized)*
