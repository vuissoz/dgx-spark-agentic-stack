FROM ghcr.io/block/goose:latest

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        git \
        openssh-client \
        python3 \
        python3-pip \
        python3-pytest \
        python3-venv \
    && python3 -m pip install --no-cache-dir --break-system-packages pytest \
    && rm -rf /var/lib/apt/lists/*

USER 1000:1000
