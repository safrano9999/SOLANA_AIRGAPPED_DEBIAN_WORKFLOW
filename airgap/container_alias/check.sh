#!/bin/bash
# check/check.sh - Detection & Argument Passing

# 1. Solana CLI
if podman ps | grep -q "solanalabs/solana"; then
    source ./container_alias/alias_solana-cli.sh "podman" && echo "Status: container (podman)"
elif docker ps | grep -q "solanalabs/solana"; then
    source ./container_alias/alias_solana-cli.sh "docker" && echo "Status: container (docker)"
fi

# 2. Solana Airgap
if podman ps | grep -q "solana-airgap"; then
    source ./container_alias/alias_airgap.sh "podman" && echo "Status: airgap-container (podman)"
elif docker ps | grep -q "solana-airgap"; then
    source ./container_alias/alias_airgap.sh "docker" && echo "Status: airgap-container (docker)"
fi
