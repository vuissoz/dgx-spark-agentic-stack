# ADR-0119: Local Whisper runtime for French and English in agent and OpenClaw sandbox images

## Status

Accepted

## Context

The stack now needs in-container local speech transcription for French and
English without manual package installation after deployment.

Two runtime constraints shape the implementation:

- agent and OpenClaw sandbox containers run with a read-only root filesystem;
- the request explicitly targets both the baseline agent image and the
  `openclaw-sandbox` runtime.

## Decision

- Ship `ffmpeg`, `vlc`, and `openai-whisper` directly in:
  - `agentic/agent-cli-base:local`
  - `agentic/optional-modules:local`
- Resolve the Torch runtime from the most stable source available per target
  architecture:
  - prefer distro `python3-torch` when the package exists for the image base
    and is importable by the active container Python interpreter;
  - when distro `python3-torch` is usable, install `openai-whisper` with
    `--no-deps`, `--ignore-installed`, and explicit pins for the remaining
    Whisper Python dependencies so `pip` does not redownload or override
    Torch/CUDA or fail while trying to uninstall distro-managed Python wheels;
  - otherwise let `pip` resolve `torch` during the managed image build and fail
    the build immediately if `import torch` or `import whisper` is broken.
- Expose both:
  - `whisper` for raw upstream usage;
  - `whisper-en` as a convenience wrapper for
    `whisper --language English --task transcribe`;
  - `whisper-fr` as a convenience wrapper for
    `whisper --language French --task transcribe`.
- Pin Whisper/Torch caches to writable state-backed directories so model
  downloads and runtime artifacts work with `read_only: true`.

## Consequences

- French and English transcription work locally inside agent containers and
  `openclaw-sandbox` without ad hoc `apt` or `pip` commands.
- First use still downloads the selected Whisper model into the persistent
  state/cache path.
- Image size increases because media and ML runtime dependencies are now part
  of the managed images.
