ARG AGENT_BASE_IMAGE=nvidia/cuda:13.0.1-devel-ubuntu24.04@sha256:7d2f6a8c2071d911524f95061a0db363e24d27aa51ec831fcccf9e76eb72bc92
FROM ${AGENT_BASE_IMAGE}

ARG AGENT_UID=10001
ARG AGENT_GID=10001

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
    tmux \
    unzip \
    valgrind \
    vim-tiny \
    xz-utils \
    zip \
    zlib1g-dev \
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
