ARG AGENT_BASE_IMAGE=nvidia/cuda:13.0.1-devel-ubuntu24.04@sha256:7d2f6a8c2071d911524f95061a0db363e24d27aa51ec831fcccf9e76eb72bc92
FROM ${AGENT_BASE_IMAGE}

ARG AGENT_UID=10001
ARG AGENT_GID=10001
ARG AGENT_NODE_MAJOR=22
ARG AGENT_CLI_INSTALL_MODE=best-effort
ARG AGENT_NPM_PREFIX=/opt/agentic/npm-global
ARG AGENT_CLI_INSTALL_HOME=/opt/agentic/install-home
ARG OPENCLAW_PREFIX=/opt/agentic/openclaw
ARG CODEX_CLI_NPM_SPEC=@openai/codex@latest
ARG CLAUDE_CODE_NPM_SPEC=@anthropic-ai/claude-code@latest
ARG OPENCODE_NPM_SPEC=opencode-ai@latest
ARG KILOCODE_CLI_NPM_SPEC=@kilocode/cli@7.4.5
ARG PI_CODING_AGENT_NPM_SPEC=@mariozechner/pi-coding-agent@latest
ARG OPENHANDS_INSTALL_SCRIPT=https://install.openhands.dev/install.sh
ARG OPENCLAW_INSTALL_CLI_SCRIPT=https://openclaw.ai/install-cli.sh
ARG OPENCLAW_INSTALL_VERSION=latest
ARG VIBE_INSTALL_SCRIPT=https://mistral.ai/vibe/install.sh
ARG HERMES_AGENT_GIT_URL=https://github.com/NousResearch/hermes-agent.git
ARG HERMES_AGENT_GIT_REF=v2026.4.3
ARG HERMES_AGENT_GIT_SHA=abf1e98f6253f6984479fe03d1098173a9b065a7
ARG HERMES_PIP_EXTRAS=pty,cli
ARG OPENAI_WHISPER_PIP_SPEC=openai-whisper==20250625

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
  && install -d -m 0755 /etc/apt/keyrings \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
  && chmod 0644 /etc/apt/keyrings/nodesource.gpg \
  && printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' "${AGENT_NODE_MAJOR}" \
    >/etc/apt/sources.list.d/nodesource.list \
  && apt-get update \
  && packages='\
    autoconf \
    automake \
    bash \
    bear \
    build-essential \
    cargo \
    ccache \
    clang \
    clang-format \
    clang-tidy \
    clangd \
    cmake \
    cppcheck \
    direnv \
    fd-find \
    ffmpeg \
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
    openssh-client \
    pkg-config \
    python3 \
    python3-dev \
    python3-pip \
    python3-pytest \
    python3-setuptools \
    python3-venv \
    ripgrep \
    rsync \
    rustc \
    shellcheck \
    shfmt \
    sudo \
    tree \
    tmux \
    unzip \
    valgrind \
    vlc \
    vim-tiny \
    xz-utils \
    zip \
    zlib1g-dev' \
  && whisper_pip_deps='certifi==2026.5.20 charset-normalizer==3.4.7 idna==3.17 llvmlite==0.47.0 more-itertools==11.1.0 numba==0.65.1 numpy==2.4.6 regex==2026.5.9 requests==2.34.2 tiktoken==0.13.0 tqdm==4.67.3 urllib3==2.7.0' \
  && requested_distro_torch=0 \
  && if apt-cache show python3-torch 2>/dev/null | grep -q '^Package: python3-torch$'; then \
       packages="${packages} python3-torch"; \
       requested_distro_torch=1; \
     fi \
  && apt-get install -y --no-install-recommends ${packages} \
  && has_distro_torch=0 \
  && if [ "${requested_distro_torch}" = "1" ] && python3 -c 'import torch' >/dev/null 2>&1; then \
       has_distro_torch=1; \
     fi \
  && if [ "${has_distro_torch}" = "1" ]; then \
       python3 -m pip install --break-system-packages --ignore-installed --no-cache-dir ${whisper_pip_deps} "${OPENAI_WHISPER_PIP_SPEC}" --no-deps; \
     else \
       python3 -m pip install --break-system-packages --no-cache-dir "${OPENAI_WHISPER_PIP_SPEC}"; \
     fi \
  && python3 -m pip install --break-system-packages --no-cache-dir pytest \
  && python3 -c 'import torch, whisper; print(torch.__version__); print(whisper.__file__)' \
  && node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 20 || (major === 20 && minor < 6)) { console.error(`Node ${process.versions.node} is below required 20.6.0`); process.exit(1); }' \
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
COPY deployments/images/agent-cli-base/agent-known-tools.sh /usr/local/bin/agent-known-tools
COPY deployments/images/agent-cli-base/agent-cli-wrapper.sh /usr/local/bin/agent-cli-wrapper
COPY deployments/images/agent-cli-base/hermes-wrapper.sh /usr/local/bin/hermes
COPY deployments/images/agent-cli-base/whisper-en.sh /usr/local/bin/whisper-en
COPY deployments/images/agent-cli-base/whisper-fr.sh /usr/local/bin/whisper-fr
RUN chmod 0755 /usr/local/bin/install-agent-clis /usr/local/bin/agent-entrypoint /usr/local/bin/agent-known-tools /usr/local/bin/agent-cli-wrapper \
    /usr/local/bin/hermes /usr/local/bin/whisper-en /usr/local/bin/whisper-fr \
  && AGENT_CLI_INSTALL_MODE="${AGENT_CLI_INSTALL_MODE}" \
    AGENT_NPM_PREFIX="${AGENT_NPM_PREFIX}" \
    AGENT_CLI_INSTALL_HOME="${AGENT_CLI_INSTALL_HOME}" \
    OPENCLAW_PREFIX="${OPENCLAW_PREFIX}" \
    CODEX_CLI_NPM_SPEC="${CODEX_CLI_NPM_SPEC}" \
    CLAUDE_CODE_NPM_SPEC="${CLAUDE_CODE_NPM_SPEC}" \
    OPENCODE_NPM_SPEC="${OPENCODE_NPM_SPEC}" \
    KILOCODE_CLI_NPM_SPEC="${KILOCODE_CLI_NPM_SPEC}" \
    PI_CODING_AGENT_NPM_SPEC="${PI_CODING_AGENT_NPM_SPEC}" \
    OPENHANDS_INSTALL_SCRIPT="${OPENHANDS_INSTALL_SCRIPT}" \
    OPENCLAW_INSTALL_CLI_SCRIPT="${OPENCLAW_INSTALL_CLI_SCRIPT}" \
    OPENCLAW_INSTALL_VERSION="${OPENCLAW_INSTALL_VERSION}" \
    VIBE_INSTALL_SCRIPT="${VIBE_INSTALL_SCRIPT}" \
    HERMES_AGENT_GIT_URL="${HERMES_AGENT_GIT_URL}" \
    HERMES_AGENT_GIT_REF="${HERMES_AGENT_GIT_REF}" \
    HERMES_AGENT_GIT_SHA="${HERMES_AGENT_GIT_SHA}" \
    HERMES_PIP_EXTRAS="${HERMES_PIP_EXTRAS}" \
    /usr/local/bin/install-agent-clis
COPY deployments/images/agent-cli-base/vibe-wrapper.sh /usr/local/bin/vibe
RUN chmod 0755 /usr/local/bin/vibe \
  && ln -sf /usr/local/bin/agent-cli-wrapper /usr/local/bin/codex \
  && ln -sf /usr/local/bin/agent-cli-wrapper /usr/local/bin/claude \
  && ln -sf /usr/local/bin/agent-cli-wrapper /usr/local/bin/opencode \
  && ln -sf /usr/local/bin/agent-cli-wrapper /usr/local/bin/kilo \
  && ln -sf /usr/local/bin/agent-cli-wrapper /usr/local/bin/pi \
  && ln -sf /usr/local/bin/agent-cli-wrapper /usr/local/bin/openhands \
  && ln -sf /usr/local/bin/agent-cli-wrapper /usr/local/bin/openclaw

ENV HOME=/home/agent
WORKDIR /workspace
USER agent:agent

ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
