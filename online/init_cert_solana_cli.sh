#!/usr/bin/env bash
set -euo pipefail

# Init certs inside the running solana-cli container
CONTAINER_NAME="solana-cli"

podman exec -it "$CONTAINER_NAME" apt-get update
podman exec -it "$CONTAINER_NAME" apt-get install -y --no-install-recommends ca-certificates
podman exec -it "$CONTAINER_NAME" update-ca-certificates
