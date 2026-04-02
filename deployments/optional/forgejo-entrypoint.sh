#!/bin/bash
set -euo pipefail

# Fix permissions for rootless container
if [[ "${EUID}" -ne 0 ]]; then
  echo "INFO: Fixing permissions for rootless Forgejo container"
  
  # Make sure the custom directory is writable
  if [[ -d "/var/lib/gitea/custom" ]]; then
    find "/var/lib/gitea/custom" -type d -exec chmod 775 {} + 2>/dev/null || true
    find "/var/lib/gitea/custom" -type f -exec chmod 664 {} + 2>/dev/null || true
  fi
  
  # Fix queues directory permissions
  if [[ -d "/var/lib/gitea/queues" ]]; then
    find "/var/lib/gitea/queues" -type d -exec chmod 775 {} + 2>/dev/null || true
    find "/var/lib/gitea/queues" -type f -exec chmod 664 {} + 2>/dev/null || true
    # Remove stale lock files
    rm -f "/var/lib/gitea/queues/common/LOCK" 2>/dev/null || true
  fi
fi

# Start Forgejo
 exec /usr/local/bin/docker-entrypoint.sh "$@"
