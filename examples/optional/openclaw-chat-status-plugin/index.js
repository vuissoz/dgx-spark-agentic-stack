import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const STATUS_URL = "http://openclaw:8111/v1/dashboard/status";

function textValue(value, fallback = "-") {
  if (typeof value !== "string") {
    return fallback;
  }
  const normalized = value.trim();
  return normalized || fallback;
}

function intValue(value) {
  return Number.isInteger(value) ? Number(value) : 0;
}

function renderStatus(payload) {
  const runtime = payload && typeof payload === "object" ? payload.runtime || {} : {};
  const execution = payload && typeof payload === "object" ? payload.execution_plane || {} : {};
  const relay = payload && typeof payload === "object" ? payload.relay || {} : {};
  const approvals = payload && typeof payload === "object" ? payload.approvals || {} : {};

  const sandboxState = textValue(runtime.sandbox, "unknown");
  const moduleState = sandboxState === "reachable" ? "ok" : "degraded";
  const lines = [
    "OpenClaw status",
    `Module: ${moduleState}`,
    `Profile: ${textValue(runtime.profile_id)}`,
    `Sandbox health: ${sandboxState}`,
    `Current session: ${textValue(execution.current_session_id)}`,
    `Default session: ${textValue(execution.default_session_id)}`,
    `Default model: ${textValue(execution.default_model)}`,
    `Provider: ${textValue(execution.provider)}`,
    `Active sandboxes: ${intValue(execution.active)}`,
    `Active sessions: ${intValue(execution.active_sessions)}`,
    `Recent expired sandboxes: ${Array.isArray(execution.recent_expired) ? execution.recent_expired.length : 0}`,
    `Approvals pending: ${intValue(approvals.pending)}`,
    `Relay queue: pending=${intValue(relay.pending)} done=${intValue(relay.done)} dead=${intValue(relay.dead)}`,
  ];
  return lines.join("\n");
}

export default definePluginEntry({
  id: "openclaw-chat-status",
  name: "DGX Spark OpenClaw Chat Status",
  description: "Expose /openclaw status as a direct slash command in chat.",
  register(api) {
    api.registerTool({
      name: "openclaw_chat_status_command",
      description: "Return a sanitized operator summary for the local DGX Spark OpenClaw stack.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          command: { type: "string" },
          commandName: { type: "string" },
          skillName: { type: "string" },
        },
      },
      async execute(_id, params) {
        const rawCommand = typeof params?.command === "string" ? params.command.trim() : "";
        if (rawCommand !== "" && rawCommand !== "status") {
          return {
            content: [
              {
                type: "text",
                text: "Usage: /openclaw status",
              },
            ],
          };
        }

        try {
          const response = await fetch(STATUS_URL, {
            headers: { Accept: "application/json" },
          });
          if (!response.ok) {
            return {
              content: [
                {
                  type: "text",
                  text: `OpenClaw status is temporarily unavailable (http ${response.status}).`,
                },
              ],
            };
          }
          const payload = await response.json();
          return {
            content: [
              {
                type: "text",
                text: renderStatus(payload),
              },
            ],
          };
        } catch (error) {
          const detail = error instanceof Error ? error.message : String(error);
          return {
            content: [
              {
                type: "text",
                text: `OpenClaw status is temporarily unavailable (${detail}).`,
              },
            ],
          };
        }
      },
    });
  },
});
