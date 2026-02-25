ARG AGENT_BASE_IMAGE=nvidia/cuda:13.0.1-devel-ubuntu24.04@sha256:7d2f6a8c2071d911524f95061a0db363e24d27aa51ec831fcccf9e76eb72bc92
FROM ${AGENT_BASE_IMAGE}

ARG AGENT_UID=10001
ARG AGENT_GID=10001
ARG AGENT_CLI_INSTALL_MODE=best-effort
ARG AGENT_NPM_PREFIX=/opt/agentic/npm-global
ARG AGENT_CLI_INSTALL_HOME=/opt/agentic/install-home
ARG OPENCLAW_PREFIX=/opt/agentic/openclaw
ARG CODEX_CLI_NPM_SPEC=@openai/codex@latest
ARG CLAUDE_CODE_NPM_SPEC=@anthropic-ai/claude-code@latest
ARG OPENCODE_NPM_SPEC=opencode-ai@latest
ARG OPENHANDS_INSTALL_SCRIPT=https://install.openhands.dev/install.sh
ARG OPENCLAW_INSTALL_CLI_SCRIPT=https://openclaw.ai/install-cli.sh
ARG OPENCLAW_INSTALL_VERSION=latest
ARG VIBE_INSTALL_SCRIPT=https://mistral.ai/vibe/install.sh

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    autoconf \
    automake \
    bash \
    bear \
    build-essential \
    cargo \
    ca-certificates \
    ccache \
    clang \
    clang-format \
    clang-tidy \
    clangd \
    cmake \
    cppcheck \
    curl \
    direnv \
    fd-find \
    gdb \
    gdbserver \
    git \
    git-lfs \
    golang-go \
    jq \
    less \
    libc6-dev \
    libbz2-dev \
    libffi-dev \
    libreadline-dev \
    libsqlite3-dev \
    libssl-dev \
    libtool \
    lld \
    lldb \
    meson \
    ninja-build \
    nodejs \
    npm \
    openssh-client \
    pkg-config \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    ripgrep \
    rsync \
    rustc \
    shellcheck \
    shfmt \
    sudo \
    tmux \
    unzip \
    valgrind \
    vim-tiny \
    xz-utils \
    zip \
    zlib1g-dev \
  && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid "${AGENT_GID}" agent \
  && useradd --uid "${AGENT_UID}" --gid "${AGENT_GID}" --create-home --shell /bin/bash agent

RUN install -d -m 0750 /etc/sudoers.d \
  && printf 'agent ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/90-agentic-agent \
  && if id -u ubuntu >/dev/null 2>&1; then printf 'ubuntu ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/90-agentic-ubuntu; fi \
  && chmod 0440 /etc/sudoers.d/90-agentic-agent \
  && if [ -f /etc/sudoers.d/90-agentic-ubuntu ]; then chmod 0440 /etc/sudoers.d/90-agentic-ubuntu; fi \
  && visudo -cf /etc/sudoers >/dev/null

COPY deployments/images/agent-cli-base/install-agent-clis.sh /usr/local/bin/install-agent-clis
COPY deployments/images/agent-cli-base/entrypoint.sh /usr/local/bin/agent-entrypoint
COPY deployments/images/agent-cli-base/agent-cli-wrapper.sh /usr/local/bin/agent-cli-wrapper
RUN chmod 0755 /usr/local/bin/install-agent-clis /usr/local/bin/agent-entrypoint /usr/local/bin/agent-cli-wrapper \
  && AGENT_CLI_INSTALL_MODE="${AGENT_CLI_INSTALL_MODE}" \
    AGENT_NPM_PREFIX="${AGENT_NPM_PREFIX}" \
    AGENT_CLI_INSTALL_HOME="${AGENT_CLI_INSTALL_HOME}" \
    OPENCLAW_PREFIX="${OPENCLAW_PREFIX}" \
    CODEX_CLI_NPM_SPEC="${CODEX_CLI_NPM_SPEC}" \
    CLAUDE_CODE_NPM_SPEC="${CLAUDE_CODE_NPM_SPEC}" \
    OPENCODE_NPM_SPEC="${OPENCODE_NPM_SPEC}" \
    OPENHANDS_INSTALL_SCRIPT="${OPENHANDS_INSTALL_SCRIPT}" \
    OPENCLAW_INSTALL_CLI_SCRIPT="${OPENCLAW_INSTALL_CLI_SCRIPT}" \
    OPENCLAW_INSTALL_VERSION="${OPENCLAW_INSTALL_VERSION}" \
    VIBE_INSTALL_SCRIPT="${VIBE_INSTALL_SCRIPT}" \
    /usr/local/bin/install-agent-clis
COPY deployments/images/agent-cli-base/vibe-wrapper.sh /usr/local/bin/vibe
RUN chmod 0755 /usr/local/bin/vibe \
  && ln -sf /usr/local/bin/agent-cli-wrapper /usr/local/bin/codex \
  && ln -sf /usr/local/bin/agent-cli-wrapper /usr/local/bin/claude \
  && ln -sf /usr/local/bin/agent-cli-wrapper /usr/local/bin/opencode \
  && ln -sf /usr/local/bin/agent-cli-wrapper /usr/local/bin/openhands \
  && ln -sf /usr/local/bin/agent-cli-wrapper /usr/local/bin/openclaw

ENV HOME=/home/agent
WORKDIR /workspace
USER agent:agent

ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
