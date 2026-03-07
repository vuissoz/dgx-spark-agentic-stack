FROM python:3.11-slim-bookworm

ARG COMFYUI_REPO=https://github.com/comfyanonymous/ComfyUI.git
ARG COMFYUI_REF=master
ARG COMFYUI_MANAGER_REPO=https://github.com/ltdrdata/ComfyUI-Manager.git
ARG COMFYUI_MANAGER_REF=main
ARG COMFYUI_ENABLE_CUDA_TORCH=1
ARG COMFYUI_TORCH_INDEX_URL=https://download.pytorch.org/whl/cu124

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    COMFYUI_HOME=/opt/comfyui

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    gcc \
    git \
    libc6-dev \
    libgl1 \
    libglib2.0-0 \
    tini \
  && rm -rf /var/lib/apt/lists/*

RUN if ! getent group 1000 >/dev/null; then groupadd --gid 1000 agentic; fi \
  && if ! getent passwd 1000 >/dev/null; then useradd --uid 1000 --gid 1000 --create-home --home-dir /home/agentic --shell /usr/sbin/nologin agentic; fi

RUN git clone --depth 1 --branch "${COMFYUI_REF}" "${COMFYUI_REPO}" "${COMFYUI_HOME}"

WORKDIR ${COMFYUI_HOME}

RUN python3 -m pip install --upgrade pip setuptools wheel \
  && python3 -m pip install -r requirements.txt \
  && if [ "${COMFYUI_ENABLE_CUDA_TORCH}" = "1" ]; then \
    python3 -m pip install --index-url "${COMFYUI_TORCH_INDEX_URL}" torch torchvision torchaudio; \
  fi \
  && if [ -n "${COMFYUI_MANAGER_REPO}" ]; then \
    git clone --depth 1 --branch "${COMFYUI_MANAGER_REF}" "${COMFYUI_MANAGER_REPO}" "${COMFYUI_HOME}/custom_nodes/ComfyUI-Manager"; \
    if [ -f "${COMFYUI_HOME}/custom_nodes/ComfyUI-Manager/requirements.txt" ]; then \
      python3 -m pip install -r "${COMFYUI_HOME}/custom_nodes/ComfyUI-Manager/requirements.txt"; \
    fi; \
  fi

RUN mkdir -p /opt/comfyui-defaults \
  && cp -a "${COMFYUI_HOME}/custom_nodes" /opt/comfyui-defaults/custom_nodes \
  && mkdir -p /comfyui/models /comfyui/input /comfyui/output /comfyui/user /tmp/comfyui-temp \
  && rm -rf \
    "${COMFYUI_HOME}/models" \
    "${COMFYUI_HOME}/input" \
    "${COMFYUI_HOME}/output" \
    "${COMFYUI_HOME}/user" \
  && ln -s /comfyui/models "${COMFYUI_HOME}/models" \
  && ln -s /comfyui/input "${COMFYUI_HOME}/input" \
  && ln -s /comfyui/output "${COMFYUI_HOME}/output" \
  && ln -s /comfyui/user "${COMFYUI_HOME}/user" \
  && chown -R 1000:1000 "${COMFYUI_HOME}" /opt/comfyui-defaults /comfyui /tmp/comfyui-temp

COPY deployments/images/comfyui/entrypoint.sh /usr/local/bin/comfyui-entrypoint
RUN chmod 0755 /usr/local/bin/comfyui-entrypoint

EXPOSE 8188

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/comfyui-entrypoint"]
CMD ["python3", "main.py", "--listen", "0.0.0.0", "--port", "8188", "--input-directory", "/comfyui/input", "--output-directory", "/comfyui/output", "--user-directory", "/comfyui/user", "--temp-directory", "/tmp/comfyui-temp"]
