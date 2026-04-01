#!/bin/bash
set -e

# Detect the Docker socket GID at runtime and grant ralph access.
# On macOS (OrbStack/Docker Desktop), the socket GID inside the container
# differs from the host symlink's GID, so build-time ARG won't work.
if [ -S /var/run/docker.sock ]; then
  SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
  if [ "$SOCK_GID" = "0" ]; then
    usermod -aG root ralph
  else
    groupadd -g "$SOCK_GID" hostdocker 2>/dev/null || true
    usermod -aG "$(getent group "$SOCK_GID" | cut -d: -f1)" ralph
  fi
fi

exec gosu ralph "$@"
