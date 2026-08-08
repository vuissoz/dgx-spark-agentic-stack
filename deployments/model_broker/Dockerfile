# deployments/model_broker/Dockerfile — ModelBroker HTTP Service (§6, M5)
#
# Build: docker build -t agentic/model-broker:local -f deployments/model_broker/Dockerfile ..
#
# Security: Runs as non-root, read-only filesystem, capability dropping
FROM python:3.11-slim as builder

# Install build dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc python3-dev && \
    rm -rf /var/lib/apt/lists/*

# Copy requirements and install Python dependencies
WORKDIR /build
COPY src/requirements.txt .
RUN pip install --user -r requirements.txt

# --- Runtime stage ---
FROM python:3.11-slim

# Create non-root user
RUN groupadd -r agent && useradd -r -g agent agent

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
    && rm -rf /var/lib/apt/lists/*

# Install Python packages from builder
COPY --from=builder /root/.local /home/agent/.local
ENV PATH=/home/agent/.local/bin:$PATH
ENV PYTHONPATH=/home/agent/.local/lib/python3.11/site-packages:/app

# Create directories with proper permissions
RUN mkdir -p /srv/agentic/model_broker/state && \
    chown agent:agent /srv/agentic/model_broker/state

# Copy application code
WORKDIR /app
COPY src/agentic/ ./agentic/

# Ensure proper permissions
RUN chown -R agent:agent /app

# Switch to non-root user
USER agent
WORKDIR /app

# Environment variables
ENV MODEL_BROKER_HOST=0.0.0.0
ENV MODEL_BROKER_PORT=11434
ENV MODEL_BROKER_STATE_DIR=/srv/agentic/model_broker/state
ENV OLLAMA_GATE_URL=http://ollama-gate:11435
ENV TRTLLM_URL=http://trtllm:11436
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=5 \
    CMD python3 -c 'import urllib.request; \
        sys.exit(0 if urllib.request.urlopen("http://127.0.0.1:11434/health", timeout=3).status == 200 else 1)' || exit 1

# Entry point
CMD ["python3", "agentic/implementations/model_broker_server.py"]
