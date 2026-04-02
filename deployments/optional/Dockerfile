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

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    openssh-client \
    xz-utils \
  && rm -rf /var/lib/apt/lists/*

RUN addgroup --system app && adduser --system --ingroup app app
WORKDIR /app
COPY deployments/optional/optional_service.py /app/optional_service.py
COPY deployments/optional/openclaw_approvals.py /app/openclaw_approvals.py
COPY deployments/optional/openclaw_gateway_entrypoint.sh /app/openclaw_gateway_entrypoint.sh
COPY deployments/optional/openclaw_wrapper.sh /app/openclaw_wrapper.sh
COPY deployments/optional/openclaw_config_layers.py /app/openclaw_config_layers.py
COPY deployments/optional/openclaw_provider_bridge.py /app/openclaw_provider_bridge.py
COPY deployments/optional/tcp_forward.py /app/tcp_forward.py
COPY --from=openclaw-ui-builder /build/src/dist/control-ui /tmp/openclaw-control-ui

RUN install -d -m 0755 "${OPENCLAW_PREFIX}" /etc/agentic \
  && tmp_script="$(mktemp)" \
  && curl -fsSL "${OPENCLAW_INSTALL_CLI_SCRIPT}" -o "${tmp_script}" \
  && bash "${tmp_script}" --prefix "${OPENCLAW_PREFIX}" --version "${OPENCLAW_INSTALL_VERSION}" --no-onboard \
  && rm -f "${tmp_script}" \
  && test -x "${OPENCLAW_PREFIX}/bin/openclaw" \
  && printf '%s\n' "${OPENCLAW_PREFIX}/bin/openclaw" >/etc/agentic/openclaw-real-path \
  && chmod 0644 /etc/agentic/openclaw-real-path \
  && install -m 0755 /app/openclaw_wrapper.sh /usr/local/bin/openclaw \
  && chmod 0755 /app/openclaw_gateway_entrypoint.sh \
  && chmod 0755 /app/openclaw_approvals.py \
  && chmod 0755 /app/openclaw_config_layers.py \
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
