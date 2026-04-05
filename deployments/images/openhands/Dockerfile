FROM docker.openhands.dev/openhands/openhands:1.3

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates openssh-client python3-pip python3-pytest \
    && /usr/local/bin/python3 -m pip install --no-cache-dir pytest \
    && rm -rf /var/lib/apt/lists/*

USER 42420:42420
