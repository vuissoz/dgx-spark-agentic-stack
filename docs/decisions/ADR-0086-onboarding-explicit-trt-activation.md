# ADR-0086: Make TRT onboarding activation and model list explicit

## Status
Accepted

## Context
`trtllm` is optional and stays disabled unless `COMPOSE_PROFILES=trt`, but the onboarding wizard did not expose that switch directly. Operators could therefore end up with:
- a gate/backend policy that assumed TRT might exist,
- no explicit `COMPOSE_PROFILES` value in the generated env,
- no explicit `TRTLLM_MODELS` list recorded during first setup.

This was especially confusing in the current day-to-day `rootless-dev` flow, where `./agent onboard` is the primary bootstrap path.

## Decision
1. Extend `deployments/bootstrap/onboarding_env.sh` to persist both `COMPOSE_PROFILES` and `TRTLLM_MODELS` in the generated env output.
2. In interactive mode, when `COMPOSE_PROFILES` does not already contain `trt`, ask explicitly whether TRT-LLM should be enabled.
3. When TRT is enabled, ask explicitly for `TRTLLM_MODELS` and validate it as a comma-separated list of model ids.
4. Add non-interactive flags `--compose-profiles` and `--trtllm-models` so CI/operators can declare the same intent without relying on implicit shell state.

## Consequences
- The generated onboarding env becomes audit-friendly for TRT enablement: desired Compose activation and exposed TRT model ids are both explicit.
- Default behavior remains unchanged when TRT is not selected: `trtllm` stays disabled.
- Operators still need model routing rules in `${AGENTIC_ROOT}/gate/config/model_routes.yml`; onboarding only makes activation and advertised TRT ids explicit.
