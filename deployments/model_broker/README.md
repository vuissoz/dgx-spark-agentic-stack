# ModelBroker Service — §6, M5

ModelBroker is the v2 model access abstraction layer for DGX Spark, implementing the contract defined in `evaluation/spec/model_broker.yaml`.

## Overview

ModelBroker provides a centralized, secure, and quota-aware interface for model access across multiple backends (Ollama, TensorRT-LLM, remote providers).

### Key Features

- **Signed Identity**: Enforces X-User-Id, X-Agent-Id, X-Project-Id, X-Run-Id headers on every request
- **Quota Management**: Per-user/project quotas for tokens, requests, and GPU minutes
- **Model Routing**: Intelligent routing to Ollama, TensorRT-LLM, or remote backends
- **Fallback**: Explicit fallback when backends are unhealthy
- **GPU Admission**: Coordination with scheduler for GPU-accelerated models
- **Audit Logging**: Comprehensive tracking of all model access

## Quick Start

### Development

```bash
# Install dependencies
pip install -r src/requirements.txt

# Run the server
python3 src/agentic/implementations/model_broker_server.py

# Test with curl
curl -X POST http://127.0.0.1:11434/v1/chat/completions \
  -H "X-User-Id: test-user" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3-coder:30b", "messages": [{"role": "user", "content": "Hello"}]}'
```

### Docker

```bash
# Build the image
docker build -t agentic/model-broker:local -f deployments/model_broker/Dockerfile ..

# Run with Docker
docker run -d \
  --name model-broker \
  -p 127.0.0.1:11434:11434 \
  -e MODEL_BROKER_HOST=0.0.0.0 \
  -e OLLAMA_GATE_URL=http://ollama-gate:11435 \
  -e TRTLLM_URL=http://trtllm:11436 \
  agentic/model-broker:local

# With Docker Compose (see compose/compose.core.yml)
docker compose -f compose/compose.core.yml up -d model-broker
```

## API Endpoints

### Health & Status

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/health` | Broker status, backend health, and routing summary |
| GET | `/v1/health/backends` | Detailed backend health with latency metrics |
| GET | `/v1/routing/config` | Active routing configuration and fallback rules |

### Model Catalog

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/v1/models` | List available models with health metadata |

### Generation

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/v1/generate` | Generate text with signed identity |
| POST | `/v1/chat/completions` | Chat API with message history and tool calls |
| POST | `/v1/embeddings` | Generate embedding vectors |

### Quotas

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/v1/quotas/{scope}/{id}` | Quota consumption for user, agent, or project |

## Request Headers

All requests (except health endpoints) require:

- `X-User-Id: string` (required) — User identifier
- `X-Agent-Id: string` (optional) — Agent name
- `X-Project-Id: string` (optional) — Project identifier
- `X-Run-Id: string` (optional) — Run identifier for correlation

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MODEL_BROKER_HOST` | `127.0.0.1` | Host to bind the server to |
| `MODEL_BROKER_PORT` | `11434` | Port to listen on |
| `MODEL_BROKER_STATE_DIR` | `/srv/agentic/model_broker/state` | State directory for quotas |
| `MODEL_BROKER_MAX_TOKENS_DAY` | `1000000` | Max tokens per user per day |
| `MODEL_BROKER_MAX_REQUESTS_HOUR` | `1000` | Max requests per user per hour |
| `MODEL_BROKER_MAX_GPU_MINUTES` | `120.0` | Max GPU minutes per user |
| `OLLAMA_GATE_URL` | `http://ollama-gate:11435` | Ollama gate backend URL |
| `TRTLLM_URL` | `http://trtllm:11436` | TensorRT-LLM backend URL |

## Configuration

### Model Registration

Models are registered in the server's `lifespan` function. To add a new model:

```python
broker.register_model(ModelInfo(
    name="model-name",
    backend=ModelBackend.OLLAMA,  # or TRTLLM
    tags=["tag1", "tag2"],
    context_window=32768,
))
```

### Routing Strategy

Configure routing strategy via `RoutingStrategy`:

- `STICKY` — Same session always routes to same backend (default)
- `ROUND_ROBIN` — Distribute requests across healthy backends
- `LOAD_BALANCED` — Route to backend with lowest active requests

## Quota Management

Quotas are enforced per-user with configurable limits:

```python
quota_manager = QuotaManager(
    max_tokens_per_day=1000000,
    max_requests_per_hour=1000,
    max_gpu_minutes=120.0,
)
```

### Quota Scopes

- **user** — Per-user quotas (fully implemented)
- **agent** — Per-agent quotas (interface exists, implementation TODO)
- **project** — Per-project quotas (interface exists, implementation TODO)

## Backend Integration

### Ollama

- URL: `http://ollama-gate:11435`
- Protocol: OpenAI-compatible
- Endpoints: `/v1/chat/completions`, `/v1/models`, `/api/tags`

### TensorRT-LLM

- URL: `http://trtllm:11436`
- Protocol: vLLM-compatible (same as Ollama gate)
- Endpoints: `/v1/chat/completions`

### Remote Providers

- OpenAI: Via ollama-gate proxy
- OpenRouter: Via ollama-gate proxy

## Fallback Behavior

When a backend is unhealthy:

1. ModelBroker checks health status
2. If primary backend is unhealthy, tries next backend in chain
3. If all backends are unhealthy, returns 503
4. Fallback is logged and counted in metrics

Fallback chain: `ollama` → `trtllm` → other healthy backends

## GPU Admission

For GPU-accelerated models:

1. ModelBroker checks GPU availability with scheduler
2. If no GPU available, queues request or falls back
3. GPU usage is tracked per user for quota purposes

## Monitoring & Metrics

ModelBroker tracks:

- Tokens per second
- Time to first token
- Time to complete
- Total tokens
- Cost estimates
- Fallback count
- Quota exceeded count
- Backend errors
- GPU admission denied count

## Security

### Container Security

- Runs as non-root user (`agent:agent`)
- Read-only filesystem
- Dropped capabilities (`cap_drop: [ALL]`)
- No new privileges (`no-new-privileges:true`)

### Network Security

- Binds to `127.0.0.1` by default (loopback only)
- Can be configured to bind to `0.0.0.0` for internal network access
- Never exposed publicly

### Identity Security

- All requests require signed identity headers
- No anonymous access to generation endpoints
- Identity metadata logged for audit

## Testing

### Unit Tests

```bash
# Run ModelBroker protocol tests
python3 tests/J7_model_broker_protocol.sh

# Run quota admission tests
python3 tests/J18_quota_admission_integration.py

# Run Messages/Responses/Chat/Ollama tests
python3 tests/J19_model_broker_messages_responses_chat_ollama.py
```

### Integration Tests

```bash
# Health check
curl http://127.0.0.1:11434/health

# List models
curl http://127.0.0.1:11434/v1/models

# Generate with identity
curl -X POST http://127.0.0.1:11434/v1/generate \
  -H "X-User-Id: test-user" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3-coder:30b", "prompt": "Hello"}'

# Chat completion
curl -X POST http://127.0.0.1:11434/v1/chat/completions \
  -H "X-User-Id: test-user" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3-coder:30b", "messages": [{"role": "user", "content": "Hello"}]}'

# Embeddings
curl -X POST http://127.0.0.1:11434/v1/embeddings \
  -H "X-User-Id: test-user" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3-emembed:7b", "input": "Test sentence"}'

# Check quotas
curl http://127.0.0.1:11434/v1/quotas/user/test-user \
  -H "X-User-Id: admin-user"
```

## Migration from ollama-gate

ModelBroker is designed to gradually replace ollama-gate functionality. See [ADR-0025](docs/decisions/ADR-0025-M5-model-broker-ollama-gate-decision.md) for the migration strategy.

### Current State

- ModelBroker deployed on port 11434
- ollama-gate remains on port 11435
- Both services coexist during transition

### Future State

- ModelBroker becomes primary model access point
- ollama-gate retired once parity is achieved

## Files

| File | Purpose |
|------|---------|
| `src/agentic/implementations/model_broker.py` | Core ModelBroker logic (routing, quotas, identity) |
| `src/agentic/implementations/model_broker_server.py` | HTTP server with FastAPI endpoints |
| `src/agentic/implementations/model_broker_client.py` | HTTP clients for backend communication |
| `deployments/model_broker/Dockerfile` | Docker build configuration |
| `deployments/model_broker/README.md` | This file |
| `compose/compose.core.yml` | Docker Compose service configuration |
| `evaluation/spec/model_broker.yaml` | Protocol specification |

## Troubleshooting

### Port already in use

```bash
# Check what's using port 11434
ss -tlnp | grep 11434

# Kill the process
kill $(lsof -t -i:11434)
```

### Missing dependencies

```bash
# Install Python dependencies
pip install -r src/requirements.txt

# Or install specific packages
pip install fastapi uvicorn httpx
```

### Backend connection issues

```bash
# Check if ollama-gate is running
curl http://127.0.0.1:11435/healthz

# Check if TRT-LLM is running
curl http://127.0.0.1:11436/health
```

## Performance Considerations

- ModelBroker adds minimal latency (typically < 5ms)
- Most time is spent in backend model inference
- Use `ROUND_ROBIN` or `LOAD_BALANCED` strategy for high throughput
- Consider increasing `MODEL_BROKER_MAX_REQUESTS_HOUR` for high-volume scenarios

## License

MIT License — Part of the DGX Spark agentic stack.