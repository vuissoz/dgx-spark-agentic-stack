# ADR-0025: M5 ModelBroker Decision - ModelBroker Replaces ollama-gate

## Status
ACCEPTED

## Context
The DGX Spark v2 architecture requires a clear model access abstraction layer that:
1. Enforces signed identity (user/agent/project/run) on every model request
2. Manages per-identity quotas for token/requests/GPU usage
3. Routes requests to appropriate backends (Ollama, TensorRT-LLM, remote)
4. Handles fallback when backends are unhealthy
5. Coordinates GPU admission with the scheduler
6. Provides audit logging and usage tracking

Currently, `ollama-gate` serves as the v1 adapter for model access, providing:
- OpenAI-compatible API endpoints
- Basic routing between Ollama and TensorRT-LLM
- External provider support (OpenAI, OpenRouter)
- Quota tracking for external providers
- Request queuing and concurrency control

However, `ollama-gate` has limitations:
- No built-in support for signed identity headers
- Quota management focused on external providers, not per-user/project budgets
- No explicit fallback contract
- No GPU admission coordination
- Tight coupling with Ollama-specific endpoints

## Decision
**ModelBroker will become the v2 model access abstraction layer, gradually replacing ollama-gate functionality.**

### Implementation Strategy

#### Phase 1: ModelBroker Service (Current - M5)
- Deploy ModelBroker as a separate HTTP service on port 11434
- Implement all endpoints from `evaluation/spec/model_broker.yaml`:
  - `GET /health` - Broker status
  - `GET /v1/models` - Model catalog
  - `POST /v1/generate` - Generation
  - `POST /v1/chat/completions` - Chat API
  - `POST /v1/embeddings` - Embeddings
  - `GET /v1/quotas/{scope}/{id}` - Quota status
  - `GET /v1/routing/config` - Routing config
  - `GET /v1/health/backends` - Backend health

#### Phase 2: Integration
- Update existing services to use ModelBroker instead of direct ollama-gate calls
- Maintain backward compatibility by keeping ollama-gate running
- Route ModelBroker requests through ollama-gate when appropriate

#### Phase 3: Migration
- Gradually migrate services from ollama-gate to ModelBroker
- Monitor and validate ModelBroker stability and performance
- Document parity between ollama-gate and ModelBroker features

#### Phase 4: Retirement (Future)
- Once ModelBroker achieves feature parity and stability
- ollama-gate can be retired per retirement rule: "Retire the v1 ollama-gate adapter only after ModelBroker protocol parity is proven"

### Contract Compliance

ModelBroker implements the contract defined in `evaluation/spec/model_broker.yaml`:

1. **Security**: `signed_identity_required: true`
   - Every request requires X-User-Id header
   - Optional: X-Agent-Id, X-Project-Id, X-Run-Id

2. **Audit Logging**: `audit_logging: true`
   - All requests logged with identity metadata
   - Usage tracked per identity

3. **Fallback**: `explicit: true`
   - Backend failure triggers explicit fallback
   - Fallback logged and counted in metrics

4. **Quotas**: `enforced: true`
   - Per-user quota limits enforced
   - Returns HTTP 429 with clear error when exceeded

5. **GPU Admission**: `integrated_with_scheduler: true`
   - GPU models coordinate with scheduler
   - No GPU available triggers queueing or fallback

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    ModelBroker Service                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   Quota     │  │  Identity    │  │    Model Catalog      │  │
│  │  Manager    │  │  Verification │  │    + Health Checks    │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐│
│  │                    Routing Logic                           ││
│  │  1. Validate identity headers                              ││
│  │  2. Check quota limits                                    ││
│  │  3. Select backend (sticky/round-robin/load-balanced)      ││
│  │  4. Check GPU admission (if applicable)                   ││
│  │  5. Route to backend or fallback                           ││
│  │  6. Record usage and audit log                            ││
│  └─────────────────────────────────────────────────────────┘│
│                                                                  │
│  Backends:                                                     │
│  - Ollama (http://ollama-gate:11435)                           │
│  - TensorRT-LLM (http://trtllm:11436)                          │
│  - Remote providers (OpenAI, OpenRouter)                    │
└─────────────────────────────────────────────────────────────┘
```

### Relationship with ollama-gate

**Current State (M5):**
- ModelBroker is deployed as a separate service (port 11434)
- ollama-gate remains the primary model access point (port 11435)
- ModelBroker can route requests to ollama-gate for actual model execution
- Both services coexist during transition period

**Future State:**
- ModelBroker becomes the single entry point for all model access
- ollama-gate is retired once ModelBroker achieves full parity
- Services currently using ollama-gate migrate to ModelBroker

### Benefits

1. **Centralized Identity**: Single point for identity verification
2. **Consistent Quotas**: Unified quota management across all backends
3. **Explicit Fallback**: Clear fallback contract and logging
4. **GPU Coordination**: Integration with scheduler for GPU admission
5. **Audit Trail**: Comprehensive logging of all model access
6. **Extensibility**: Easy to add new backends or features

### Drawbacks

1. **Complexity**: Additional service to maintain
2. **Transition Period**: Both services must run during migration
3. **Learning Curve**: New API for service developers to learn

### Alternatives Considered

1. **Extend ollama-gate**: Add ModelBroker features to existing ollama-gate
   - Rejected: Would increase complexity of existing service
   - Harder to maintain clean separation of concerns

2. **Proxy Approach**: Deploy ModelBroker as a proxy in front of ollama-gate
   - Rejected: Adds latency, single point of failure
   - Doesn't solve the fundamental architecture issues

3. **Gradual Replacement**: Replace ollama-gate piece by piece
   - Partially adopted: This is essentially what we're doing with ModelBroker

### Retirement Criteria

ollama-gate can be retired when:
1. ModelBroker implements all required endpoints
2. All services successfully migrate to ModelBroker
3. ModelBroker demonstrates stability in production
4. Performance metrics show no regression
5. Monitoring shows no issues with quota enforcement, identity, or fallback

### Success Metrics

- All model access goes through ModelBroker
- Zero quota violations without proper enforcement
- 100% identity verification on all requests
- Fallback works correctly when backends are unhealthy
- GPU admission coordinated with scheduler
- Audit logs capture all model access

### Links

- [ModelBroker Specification](evaluation/spec/model_broker.yaml)
- [PLAN.md §6 Model Access](PLAN.md#6---accès-aux-modèles)
- [PLAN.md M5 Models](PLAN.md#m5---modèles)
- [ModelBroker Implementation](src/agentic/implementations/model_broker.py)
- [ModelBroker HTTP Server](src/agentic/implementations/model_broker_server.py)
- [Compose Configuration](compose/compose.core.yml) (model-broker service)
