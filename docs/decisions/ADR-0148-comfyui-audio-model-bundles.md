# ADR-0148: ComfyUI audio models use pinned, workflow-oriented bundles

## Status

Accepted.

## Context

Stable Audio 3 and ACE-Step files are published across several Hugging Face
repositories and directory layouts. Operators need reproducible installation
in both `rootless-dev` and `strict-prod`, while ComfyUI requires files below
specific `checkpoints`, `text_encoders`, `vae`, and `diffusion_models`
directories. The requested ACE-Step 1.5 set includes both split workflow files
and an all-in-one checkpoint.

## Decision

Extend the existing checksum-pinned ComfyUI model installer with three bundles:

- `stable-audio-3` installs its checkpoint and both requested text encoders;
- `ace-step-v1` installs the requested all-in-one artifact once, despite its
  duplicated source link;
- `ace-step-1.5` installs every requested split artifact plus the turbo AIO
  checkpoint.

Source paths are translated to the model directories expected by ComfyUI. The
download command remains opt-in, resumable, checksum-verified, and profile
independent; persistence follows `AGENTIC_ROOT`. A non-blocking per-bundle file
lock prevents concurrent invocations from writing the same partial artifact.

## Consequences

The complete ACE-Step 1.5 bundle consumes about 30 GB because the split and AIO
variants overlap conceptually. This cost is explicit in the runbook. Splitting
that bundle into smaller variants can be added later without changing the
persisted model layout.
