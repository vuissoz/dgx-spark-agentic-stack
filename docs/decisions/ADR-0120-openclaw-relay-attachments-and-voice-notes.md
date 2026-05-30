# ADR-0120: OpenClaw relay attachments and voice notes on the local webhook path

## Status

Accepted

## Context

The stack already exposed a controlled local path for inbound OpenClaw messages:

- provider webhook -> `openclaw-relay`
- signed forward -> `openclaw /v1/webhooks/dm`
- controlled execution -> `openclaw-sandbox`

That path only transported plain text. Attached files and voice notes could not
be staged, inspected, or transcribed by the local OpenClaw tooling, even though
the sandbox image already ships `ffmpeg` and `whisper`.

Two guardrails remain non-negotiable:

- no `docker.sock`;
- no widened egress just to fetch remote chat attachments.

## Decision

1. Extend the local relay/webhook contract to accept inline attachment payloads
   (`attachments[]` plus common single-item aliases such as `voice`, `audio`,
   `document`, `image`, `video`, `file`).
2. Stage attachment bytes under
   `${AGENTIC_ROOT}/openclaw/relay/state/attachments/<event_id>/`.
3. Write a deterministic `manifest.json` per inbound event and forward only
   metadata plus attachment summary to the inner OpenClaw webhook.
4. Mount the staged attachment tree read-only into `openclaw-sandbox` and expose
   explicit tools:
   - `attachments.list`
   - `attachments.read_text`
   - `attachments.transcribe_audio`
5. Prefer provider-supplied transcript metadata when available; otherwise allow
   local on-demand Whisper transcription inside the sandbox.

## Consequences

Positive:

- webhook-backed Telegram/other provider events can now carry files and voice
  notes into the local OpenClaw runtime;
- attachment staging is persistent, auditable, and independent from external
  provider re-downloads;
- no new public ingress and no extra broad egress are introduced.

Trade-offs:

- the direct upstream OpenClaw long-polling provider path remains upstream-owned;
  this ADR guarantees attachment handling on the stack-managed relay/webhook
  path only;
- large attachments must be sent inline and are constrained by explicit size and
  count limits;
- on-demand Whisper transcription may still download a model on first use if the
  cache is empty.
