FROM debian:bookworm-slim

ARG AGENT_UID=10001
ARG AGENT_GID=10001

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    tmux \
  && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
  install -d -m 0755 /etc/agentic; \
  real_vibe=""; \
  if curl -LsSf https://mistral.ai/vibe/install.sh | bash; then \
    :; \
  else \
    echo "WARN: unable to install official Vibe CLI during image build; fallback wrapper will stay active" >&2; \
  fi; \
  if [ -x "/root/.local/bin/vibe" ]; then \
    real_vibe="/root/.local/bin/vibe"; \
  elif command -v vibe >/dev/null 2>&1; then \
    real_vibe="$(command -v vibe)"; \
  fi; \
  printf '%s\n' "${real_vibe}" > /etc/agentic/vibe-real-path

RUN groupadd --gid "${AGENT_GID}" agent \
  && useradd --uid "${AGENT_UID}" --gid "${AGENT_GID}" --create-home --shell /bin/bash agent

COPY deployments/images/agent-cli-base/entrypoint.sh /usr/local/bin/agent-entrypoint
COPY deployments/images/agent-cli-base/vibe-wrapper.sh /usr/local/bin/vibe
RUN chmod 0755 /usr/local/bin/agent-entrypoint /usr/local/bin/vibe

ENV HOME=/home/agent
WORKDIR /workspace
USER agent:agent

ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
