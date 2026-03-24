# ADR-0081: ComfyUI single runtime root and explicit arm64/rootless CUDA policy

## Status
Accepted

## Context
Two follow-up issues remained open around ComfyUI:
- `dgx-spark-agentic-stack-0ik`: runtime persistence was fragmented across five host mounts (`models`, `input`, `output`, `user`, `custom_nodes`), while real ComfyUI mutations can affect the whole runtime tree.
- `dgx-spark-agentic-stack-6nn`: on `arm64` in `rootless-dev`, the image requested CUDA PyTorch wheels from the `cu124` index, but the effective runtime could still end up CPU-only. That left operators with an ambiguous "GPU-enabled" posture.

Observed constraint:
- on Linux `aarch64`, the PyTorch `cu124` wheel index exposes `aarch64` artifacts without the `+cu124` CUDA suffix, so the current path cannot assume an effective CUDA backend just because the CUDA index was requested.

## Decision
- Switch ComfyUI persistence to a single host mount:
  - `${AGENTIC_ROOT}/comfyui:/comfyui`
- Keep the upstream source checkout under `/opt/comfyui`, but replace the mutable paths with symlinks toward `/comfyui/{models,input,output,user,custom_nodes}` so the source tree remains a git checkout and `ComfyUI-Manager` still works.
- Extend the ComfyUI entrypoint to write runtime diagnostics at:
  - `/comfyui/user/agentic-runtime/torch-runtime.json`
- On `arm64` with `AGENTIC_PROFILE=rootless-dev`:
  - if `torch.cuda.is_available()` is true, record policy `effective`;
  - otherwise, record policy `unsupported-explicit`, warn on startup, and force ComfyUI `--cpu`.
- Extend `agent doctor` and `tests/I1_comfyui.sh` to require:
  - the single `/comfyui` mount,
  - absence of the legacy fragmented mounts,
  - presence of the CUDA diagnostics file,
  - and, on `arm64/rootless-dev`, a policy of either `effective` or `unsupported-explicit`.

## Consequences
- Any ComfyUI runtime mutation now remains inside one canonical persistent subtree.
- `agent forget comfyui` can safely target `${AGENTIC_ROOT}/comfyui` as one unit.
- Operators on `arm64/rootless-dev` get an explicit signal when ComfyUI is running in CPU fallback instead of assuming CUDA is active.
- A future effective CUDA trajectory can be introduced without changing the operator contract: the diagnostics simply move from `unsupported-explicit` to `effective`.
