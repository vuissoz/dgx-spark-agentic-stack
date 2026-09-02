# ADR-0142: Versioned in-repository OpenClaw default skill catalog

## Status

Accepted.

## Context

The v1 inventory and Beads describe a set of specialist names (Capability Evolver, Clawflows, GOG, GitHub, reviewers, researchers, and similar). They must not be mistaken for new harnesses or silently fetched from an unpinned marketplace.

## Decision

`examples/optional/openclaw-default-skills-plugin` is the canonical, versioned source of the managed default catalog. It is installed by `deployments/core/init_runtime.sh` into the persistent OpenClaw state, and its current manifest version is `1.1.0`.

Every catalog entry is a repo-maintained prompt/skill package, not a vendored ClawHub package. Its provenance is therefore the release commit plus its path under `examples/optional/openclaw-default-skills-plugin/skills/<name>/SKILL.md`; it has no default secret, API key, executable dependency, or egress entitlement. A skill that needs external credentials, an executable tool, or broader egress must be added separately with pinned provenance and an explicit allowlist decision.

The managed bootstrap copies the catalog reproducibly and `agent doctor` checks both the plugin provenance record and the runtime-visible `openclaw skills list --json` catalog. `tests/K16_openclaw_default_skills_catalog.sh` is the end-to-end regression proof.

## Consequences

- The requested specialist roles remain `SkillPackage`s; they do not create harnesses, runtimes, or persistent mutable state.
- Updates are reviewed repository changes and are captured by the normal release artifact/digest workflow, not mutable marketplace resolution.
- Operators can add separately managed skills, but they are not silently enabled by this baseline.
