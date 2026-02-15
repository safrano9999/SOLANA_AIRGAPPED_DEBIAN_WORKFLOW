#!/bin/bash
# init_airgapped.sh - Create new keypair (Hybrid: Bare Metal & Container)

set -e

[ -d "./container_alias" ] && shopt -s expand_aliases && source ./container_alias/check.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLANA_DIR="$SCRIPT_DIR/solana"
mkdir -p "$SOLANA_DIR"

echo "=== Create New Solana Keypair (Airgapped) ==="
echo ""
echo "Generating new keypair..."
echo ""

# Stream output to variable to support podman aliases and local execution
RAW_OUTPUT=$(solana-keygen new --no-bip39-passphrase --force -o /dev/stdout)

# Extract JSON key and Public Key from the stream
KEY_JSON=$(echo "$RAW_OUTPUT" | grep -o '\[.*\]')
PUBKEY=$(echo "$RAW_OUTPUT" | grep "pubkey:" | awk '{print $2}' | tr -d '\r')

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "IMPORTANT: Write down your seed phrase above!"
echo "════════════════════════════════════════════════════════════════"
echo ""

echo "Public key: $PUBKEY"
echo ""

KEYPAIR_FILE="$SOLANA_DIR/${PUBKEY}.json"

# Save directly to host filesystem
echo "$KEY_JSON" > "$KEYPAIR_FILE"
chmod 600 "$KEYPAIR_FILE"

echo "✓ Keypair saved to: $KEYPAIR_FILE"
echo ""

read -p "Display public key as QR code? (y/N): " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Public Key QR Code:"
    echo ""
    qrencode -t UTF8 $PUBKEY
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "Scan this QR code with online PC when running init_xl.sh"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
fi

# Store stake account info as requested in logbook [2026-01-19]
echo "{\"pubkey\": \"$PUBKEY\", \"type\": \"main-wallet\", \"created\": \"$(date)\"}" > "$SOLANA_DIR/${PUBKEY}_info.json"

echo ""
echo "✓ Setup complete!"
echo "Keypair file: $(basename "$KEYPAIR_FILE")"
echo ""
