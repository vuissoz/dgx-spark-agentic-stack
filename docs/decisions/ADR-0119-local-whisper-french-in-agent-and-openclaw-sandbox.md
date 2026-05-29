# ADR-0119: Local French Whisper runtime in agent and OpenClaw sandbox images

## Status

Accepted

## Context

The stack now needs in-container local speech transcription for French without
manual package installation after deployment.

Two runtime constraints shape the implementation:

- agent and OpenClaw sandbox containers run with a read-only root filesystem;
- the request explicitly targets both the baseline agent image and the
  `openclaw-sandbox` runtime.

## Decision

- Ship `ffmpeg`, `vlc`, `python3-torch`, and `openai-whisper` directly in:
  - `agentic/agent-cli-base:local`
  - `agentic/optional-modules:local`
- Expose both:
  - `whisper` for raw upstream usage;
  - `whisper-fr` as a convenience wrapper for
    `whisper --language French --task transcribe`.
- Pin Whisper/Torch caches to writable state-backed directories so model
  downloads and runtime artifacts work with `read_only: true`.

## Consequences

- French transcription works locally inside agent containers and
  `openclaw-sandbox` without ad hoc `apt` or `pip` commands.
- First use still downloads the selected Whisper model into the persistent
  state/cache path.
- Image size increases because media and ML runtime dependencies are now part
  of the managed images.
