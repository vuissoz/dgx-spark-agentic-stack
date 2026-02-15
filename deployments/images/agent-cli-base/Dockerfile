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

RUN groupadd --gid "${AGENT_GID}" agent \
  && useradd --uid "${AGENT_UID}" --gid "${AGENT_GID}" --create-home --shell /bin/bash agent

COPY deployments/images/agent-cli-base/entrypoint.sh /usr/local/bin/agent-entrypoint
RUN chmod 0755 /usr/local/bin/agent-entrypoint

ENV HOME=/home/agent
WORKDIR /workspace
USER agent:agent

ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
