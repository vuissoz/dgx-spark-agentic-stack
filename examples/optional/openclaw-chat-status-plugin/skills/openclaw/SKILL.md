---
name: openclaw
description: Show the local DGX Spark OpenClaw operator status directly in chat.
user-invocable: true
disable-model-invocation: true
command-dispatch: tool
command-tool: openclaw_chat_status_command
command-arg-mode: raw
---

Use `/openclaw status` to fetch the current DGX Spark OpenClaw operator summary without leaving chat.
