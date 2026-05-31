FROM node:24-bookworm AS openclaw-ui-builder

ARG OPENCLAW_INSTALL_VERSION=latest

RUN apt-get update \
  && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN set -eux; \
  requested="${OPENCLAW_INSTALL_VERSION}"; \
  if [ "${requested}" = "latest" ] || [ "${requested}" = "next" ]; then \
    resolved="$(npm view "openclaw@${requested}" version)"; \
  else \
    resolved="${requested#v}"; \
  fi; \
  printf '%s\n' "${resolved}" >/tmp/openclaw-ui-version; \
  git clone --depth 1 --branch "v${resolved}" https://github.com/openclaw/openclaw.git /build/src

WORKDIR /build/src
RUN corepack enable \
  && pnpm install --frozen-lockfile \
  && pnpm ui:install \
  && pnpm ui:build

FROM python:3.12-slim

ARG OPENCLAW_INSTALL_CLI_SCRIPT=https://openclaw.ai/install-cli.sh
ARG OPENCLAW_INSTALL_VERSION=latest
ARG OPENCLAW_PREFIX=/opt/openclaw
ARG OPENAI_WHISPER_PIP_SPEC=openai-whisper==20250625

RUN apt-get update \
  && packages='\
    bash \
    ca-certificates \
    curl \
    ffmpeg \
    git \
    openssh-client \
    python3-pip \
    python3-pytest \
    python3-setuptools \
    vlc \
    xz-utils' \
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
       python3 -m pip install --ignore-installed --no-cache-dir ${whisper_pip_deps} "${OPENAI_WHISPER_PIP_SPEC}" --no-deps; \
     else \
       python3 -m pip install --no-cache-dir "${OPENAI_WHISPER_PIP_SPEC}"; \
     fi \
  && python3 -m pip install --no-cache-dir pytest \
  && python3 -c 'import torch, whisper; print(torch.__version__); print(whisper.__file__)' \
  && rm -rf /var/lib/apt/lists/*

RUN addgroup --system app && adduser --system --ingroup app app
RUN groupadd --gid 1000 agentic \
  && useradd --uid 1000 --gid 1000 --home-dir /state/cli/openclaw-home --no-create-home --shell /usr/sbin/nologin agentic
WORKDIR /app
COPY deployments/optional/optional_service.py /app/optional_service.py
COPY deployments/optional/openclaw_approvals.py /app/openclaw_approvals.py
COPY deployments/optional/openclaw_gateway_entrypoint.sh /app/openclaw_gateway_entrypoint.sh
COPY deployments/optional/openclaw_gateway_rpc_probe.sh /app/openclaw_gateway_rpc_probe.sh
COPY deployments/optional/openclaw_wrapper.sh /app/openclaw_wrapper.sh
COPY deployments/optional/openclaw_config_layers.py /app/openclaw_config_layers.py
COPY deployments/optional/openclaw_provider_bridge.py /app/openclaw_provider_bridge.py
COPY deployments/optional/patch_openclaw_ddg.py /app/patch_openclaw_ddg.py
COPY deployments/optional/tcp_forward.py /app/tcp_forward.py
COPY deployments/optional/whisper-en.sh /usr/local/bin/whisper-en
COPY deployments/optional/whisper-fr.sh /usr/local/bin/whisper-fr
COPY --from=openclaw-ui-builder /build/src/dist/control-ui /tmp/openclaw-control-ui

RUN install -d -m 0755 "${OPENCLAW_PREFIX}" /etc/agentic \
  && tmp_script="$(mktemp)" \
  && curl -fsSL "${OPENCLAW_INSTALL_CLI_SCRIPT}" -o "${tmp_script}" \
  && bash "${tmp_script}" --prefix "${OPENCLAW_PREFIX}" --version "${OPENCLAW_INSTALL_VERSION}" --no-onboard \
  && rm -f "${tmp_script}" \
  && test -x "${OPENCLAW_PREFIX}/bin/openclaw" \
  && python3 /app/patch_openclaw_ddg.py --require-match "${OPENCLAW_PREFIX}" \
  && printf '%s\n' "${OPENCLAW_PREFIX}/bin/openclaw" >/etc/agentic/openclaw-real-path \
  && chmod 0644 /etc/agentic/openclaw-real-path \
  && install -m 0755 /app/openclaw_wrapper.sh /usr/local/bin/openclaw \
  && chmod 0755 /usr/local/bin/whisper-en \
  && chmod 0755 /usr/local/bin/whisper-fr \
  && chmod 0755 /app/openclaw_gateway_entrypoint.sh \
  && chmod 0755 /app/openclaw_gateway_rpc_probe.sh \
  && chmod 0755 /app/openclaw_approvals.py \
  && chmod 0755 /app/openclaw_config_layers.py \
  && chmod 0755 /app/patch_openclaw_ddg.py \
  && chmod 0755 /app/openclaw_provider_bridge.py \
  && rm -rf "${OPENCLAW_PREFIX}/lib/node_modules/openclaw/dist/control-ui" \
  && install -d -m 0755 "${OPENCLAW_PREFIX}/lib/node_modules/openclaw/dist" \
  && cp -R /tmp/openclaw-control-ui "${OPENCLAW_PREFIX}/lib/node_modules/openclaw/dist/control-ui" \
  && test -f "${OPENCLAW_PREFIX}/lib/node_modules/openclaw/dist/control-ui/index.html" \
  && chmod -R a+rX "${OPENCLAW_PREFIX}" \
  && chmod 0644 /app/tcp_forward.py \
  && rm -rf /tmp/openclaw-control-ui

ENV PATH="/usr/local/bin:${OPENCLAW_PREFIX}/bin:${PATH}"
USER app
ENTRYPOINT ["python3", "/app/optional_service.py"]
