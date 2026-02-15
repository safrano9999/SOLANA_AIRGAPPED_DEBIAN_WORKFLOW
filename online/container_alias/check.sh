#!/bin/bash
# check/check.sh - Detection & Argument Passing

# 1. Solana CLI
if podman ps | grep -q "solanalabs/solana"; then
    source ./container_alias/alias_solana-cli.sh "podman" && echo "Status: container (podman)"
elif docker ps | grep -q "solanalabs/solana"; then
    source ./container_alias/alias_solana-cli.sh "docker" && echo "Status: container (docker)"
fi

# 2. Solana Airgap
if podman ps | grep -q "solana-online"; then
    source ./container_alias/alias_online.sh "podman" && echo "Status: online-container (podman)"
elif docker ps | grep -q "solana-online"; then
    source ./container_alias/alias_online.sh "docker" && echo "Status: online-container (docker)"
fi
