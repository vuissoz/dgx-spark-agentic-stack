# ADR-0152 — Store the ComfyUI authentication password as a runtime file secret

## Status

Accepted

## Context

`comfyui-loopback` previously received `COMFYUI_AUTH_PASSWORD` through its
container environment, with `change-me` as a Compose default. Deployed values
could consequently appear in `docker inspect`, effective Compose snapshots and
`deployments/runtime.env`.

The proxy runs as the configured non-root runtime UID. Compose file secrets are
bind-mounted by the local Docker implementation, so declaring a Compose
`uid`/`gid` does not reliably remap ownership of the source file.

## Decision

1. Use `${AGENTIC_ROOT}/secrets/runtime/comfyui.auth_password` as the sole
   canonical source for the ComfyUI Basic Auth password.
2. Generate a random 48-hex-character value during UI runtime initialization
   when no valid secret exists. Keep the directory at `0700`, the file at
   `0600`, and the file owned by the configured runtime UID/GID so the non-root
   proxy can read its read-only bind mount.
3. Preserve `COMFYUI_AUTH_USERNAME` as non-sensitive runtime configuration.
4. Migrate a valid legacy `COMFYUI_AUTH_PASSWORD` from
   `deployments/runtime.env`, remove the legacy entry, and replace `change-me`
   rather than preserving it.
5. Pass only `COMFYUI_AUTH_PASSWORD_FILE=/run/secrets/comfyui.auth_password` to
   the container. The startup command and healthcheck read the mounted file.
6. Reject rollback and release artifacts that contain an inline
   `COMFYUI_AUTH_PASSWORD`; an unsafe historical snapshot is not eligible for
   deterministic restoration.
7. Rotate through `agent comfyui rotate-password`, which replaces the file
   atomically, recreates a running proxy and records only the action and path.

## Consequences

- The password no longer appears in container environment inspection or new
  release snapshots.
- Existing installations migrate on the next UI initialization without losing
  a non-default password.
- The runtime UID can read the secret but other host users cannot.
- Historical releases containing inline ComfyUI credentials must be replaced
  by a sanitized `agent update` release before rollback is allowed.
