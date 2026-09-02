FROM docker.openhands.dev/openhands/openhands:1.3

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates openssh-client python3-pip python3-pytest \
    && /usr/local/bin/python3 -m pip install --no-cache-dir pytest \
    && rm -rf /var/lib/apt/lists/*

# OpenHands 1.3's V1 Changes panel calls the private runtime URL directly.
# Patch the version-pinned static bundle to use the same-origin server bridge
# instead; the script fails closed if the upstream bundle contract changes.
COPY --chmod=0755 deployments/patches/openhands/patch_frontend_git_bridge.py /usr/local/bin/patch-openhands-frontend-git-bridge
RUN /usr/local/bin/patch-openhands-frontend-git-bridge

USER 42420:42420
