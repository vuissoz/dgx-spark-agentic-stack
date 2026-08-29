#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_cmd docker
assert_cmd python3

n8n_cid="$(require_service_container optional-n8n)" || exit 1
wait_for_container_ready "${n8n_cid}" 90 || fail "n8n is not healthy"

# This script is sent to the n8n container over stdin. The generated source is
# written and executed only through the remote SandboxClient; it is never
# evaluated by Node in the n8n container or by the host shell.
docker exec -i "${n8n_cid}" node - <<'NODE' >/tmp/agent-k21-result.json
const crypto = require('node:crypto');
const undiciPath = '/usr/local/lib/node_modules/n8n/node_modules/.pnpm/undici@7.29.0/node_modules/undici/index.js';
const sandboxPath = '/usr/local/lib/node_modules/n8n/node_modules/.pnpm/@n8n+sandbox-client@0.1.0/node_modules/@n8n/sandbox-client/dist/index.js';
const { ProxyAgent, fetch } = require(undiciPath);
const { SandboxClient, SandboxServiceError } = require(sandboxPath);

async function main() {
  const modelUrl = process.env.N8N_INSTANCE_AI_MODEL_URL.replace(/\/$/, '');
  const proxyUrl = process.env.HTTPS_PROXY || process.env.HTTP_PROXY;
  if (!proxyUrl) throw new Error('n8n proxy URL is missing');
  const dispatcher = new ProxyAgent(proxyUrl);
  let generated;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const response = await fetch(`${modelUrl}/chat/completions`, {
      method: 'POST',
      dispatcher,
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${process.env.N8N_INSTANCE_AI_MODEL_API_KEY || 'local-gate'}`,
      },
      body: JSON.stringify({
        model: process.env.N8N_INSTANCE_AI_MODEL,
        stream: false,
        messages: [
          {
            role: 'system',
            content: 'Generate JavaScript source, never an n8n workflow JSON document. The source must start with console.log and use no imports or network calls.',
          },
          {
            role: 'user',
            content: 'Call emit_workflow with a JavaScript file that only prints {"status":"ok","origin":"n8n-sandbox"} as JSON.',
          },
        ],
        tools: [{
          type: 'function',
          function: {
            name: 'emit_workflow',
            description: 'Return one generated executable JavaScript workflow step.',
            parameters: {
              type: 'object',
              properties: {
                filename: { type: 'string' },
                source: { type: 'string' },
              },
              required: ['filename', 'source'],
              additionalProperties: false,
            },
          },
        }],
        tool_choice: { type: 'function', function: { name: 'emit_workflow' } },
      }),
    });
    if (!response.ok) throw new Error(`model request failed with ${response.status}`);
    const completion = await response.json();
    const call = completion.choices?.[0]?.message?.tool_calls?.[0];
    if (call?.function?.name !== 'emit_workflow') continue;
    const candidate = JSON.parse(call.function.arguments);
    if (typeof candidate.filename === 'string' && typeof candidate.source === 'string' && /^\s*console\.log\(/.test(candidate.source)) {
      generated = candidate;
      break;
    }
  }
  if (!generated) throw new Error('model did not generate a bounded executable JavaScript step after 3 attempts');
  if (generated.source.length > 2000 || !generated.source.includes('n8n-sandbox')) {
    throw new Error('generated workflow source failed the bounded-content check');
  }
  if (/\b(require|import|fetch|XMLHttpRequest|child_process)\b|https?:\/\//.test(generated.source)) {
    throw new Error('generated workflow source requested forbidden host/network capabilities');
  }

  const client = new SandboxClient({
    baseUrl: process.env.N8N_INSTANCE_AI_SANDBOX_API_URL,
    apiKey: process.env.N8N_INSTANCE_AI_SANDBOX_API_KEY,
  });
  const sandboxId = crypto.randomUUID();
  let created = false;
  try {
    await client.createSandbox({ id: sandboxId });
    created = true;
    await client.mkdir(sandboxId, '/home/user/workspace', true);
    await client.writeFile(sandboxId, '/home/user/workspace/workflow.js', generated.source);
    const execution = await client.exec(sandboxId, {
      command: 'node /home/user/workspace/workflow.js',
      workdir: '/home/user/workspace',
      timeoutMs: 30000,
    });
    if (!execution.success || execution.exitCode !== 0) {
      throw new Error(`sandbox execution failed: ${execution.stderr}`);
    }
    const output = JSON.parse(execution.stdout.trim());
    if (output.status !== 'ok' || output.origin !== 'n8n-sandbox') {
      throw new Error(`unexpected sandbox output: ${execution.stdout}`);
    }
  } finally {
    if (created) await client.deleteSandbox(sandboxId);
  }

  let deleted = false;
  try {
    await client.getSandbox(sandboxId);
  } catch (error) {
    if (error instanceof SandboxServiceError && error.status === 404) deleted = true;
    else throw error;
  }
  if (!deleted) throw new Error('sandbox workspace was not cleaned up');
  process.stdout.write(JSON.stringify({
    model: process.env.N8N_INSTANCE_AI_MODEL,
    generated: true,
    executedInSandbox: true,
    cleanedUp: true,
  }) + '\n');
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE

python3 - /tmp/agent-k21-result.json <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload != {
    "model": "qwen3.8:27b",
    "generated": True,
    "executedInSandbox": True,
    "cleanedUp": True,
}:
    raise SystemExit(f"unexpected n8n Assistant E2E result: {payload!r}")
PY

ok "K21_n8n_assistant_sandbox_e2e passed"
