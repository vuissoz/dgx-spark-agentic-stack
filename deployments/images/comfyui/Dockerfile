FROM python:3.11-slim-bookworm

ARG COMFYUI_REPO=https://github.com/comfyanonymous/ComfyUI.git
ARG COMFYUI_REF=master

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    COMFYUI_HOME=/opt/comfyui

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    libgl1 \
    libglib2.0-0 \
    tini \
  && rm -rf /var/lib/apt/lists/*

RUN if ! getent group 1000 >/dev/null; then groupadd --gid 1000 agentic; fi \
  && if ! getent passwd 1000 >/dev/null; then useradd --uid 1000 --gid 1000 --create-home --home-dir /home/agentic --shell /usr/sbin/nologin agentic; fi

RUN git clone --depth 1 --branch "${COMFYUI_REF}" "${COMFYUI_REPO}" "${COMFYUI_HOME}"

WORKDIR ${COMFYUI_HOME}

RUN python3 -m pip install --upgrade pip setuptools wheel \
  && python3 -m pip install -r requirements.txt

RUN mkdir -p /comfyui/models /comfyui/input /comfyui/output /comfyui/user /tmp/comfyui-temp \
  && rm -rf \
    "${COMFYUI_HOME}/models" \
    "${COMFYUI_HOME}/input" \
    "${COMFYUI_HOME}/output" \
    "${COMFYUI_HOME}/user" \
  && ln -s /comfyui/models "${COMFYUI_HOME}/models" \
  && ln -s /comfyui/input "${COMFYUI_HOME}/input" \
  && ln -s /comfyui/output "${COMFYUI_HOME}/output" \
  && ln -s /comfyui/user "${COMFYUI_HOME}/user"

COPY deployments/images/comfyui/entrypoint.sh /usr/local/bin/comfyui-entrypoint
RUN chmod 0755 /usr/local/bin/comfyui-entrypoint

EXPOSE 8188

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/comfyui-entrypoint"]
CMD ["python3", "main.py", "--listen", "0.0.0.0", "--port", "8188", "--input-directory", "/comfyui/input", "--output-directory", "/comfyui/output", "--user-directory", "/comfyui/user", "--temp-directory", "/tmp/comfyui-temp"]
