#!/usr/bin/env bash
# Charge l'environnement local de développement de la stack agentique.
# Utilisation : source ./scripts/init_env.sh

export AGENTIC_OPTIONAL_MODULES=mcp,pi-mono,goose,portainer,n8n
export AGENTIC_PROFILE=rootless-dev
export COMPOSE_PROFILES=
