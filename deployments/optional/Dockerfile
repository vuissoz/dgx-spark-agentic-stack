FROM python:3.12-slim

ARG OPENCLAW_INSTALL_CLI_SCRIPT=https://openclaw.ai/install-cli.sh
ARG OPENCLAW_INSTALL_VERSION=latest
ARG OPENCLAW_PREFIX=/opt/openclaw

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    xz-utils \
  && rm -rf /var/lib/apt/lists/*

RUN addgroup --system app && adduser --system --ingroup app app
WORKDIR /app
COPY deployments/optional/optional_service.py /app/optional_service.py
COPY deployments/optional/openclaw_gateway_entrypoint.sh /app/openclaw_gateway_entrypoint.sh
COPY deployments/optional/openclaw_wrapper.sh /app/openclaw_wrapper.sh
COPY deployments/optional/openclaw_config_layers.py /app/openclaw_config_layers.py
COPY deployments/optional/tcp_forward.py /app/tcp_forward.py

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
  && chmod 0755 /app/openclaw_config_layers.py \
  && install -d -m 0755 "${OPENCLAW_PREFIX}/lib/node_modules/openclaw/dist/control-ui" \
  && if [ ! -f "${OPENCLAW_PREFIX}/lib/node_modules/openclaw/dist/control-ui/index.html" ]; then \
       printf '%s\n' \
         '<!doctype html>' \
         '<html lang="en">' \
         '  <head>' \
         '    <meta charset="utf-8">' \
         '    <title>OpenClaw Gateway</title>' \
         '  </head>' \
         '  <body>' \
         '    <h1>OpenClaw Gateway</h1>' \
         '    <p>Fallback control UI page provided by the agentic stack.</p>' \
         '  </body>' \
         '</html>' \
         >"${OPENCLAW_PREFIX}/lib/node_modules/openclaw/dist/control-ui/index.html"; \
     fi \
  && chmod -R a+rX "${OPENCLAW_PREFIX}" \
  && chmod 0644 /app/tcp_forward.py

ENV PATH="/usr/local/bin:${OPENCLAW_PREFIX}/bin:${PATH}"
USER app
ENTRYPOINT ["python3", "/app/optional_service.py"]
