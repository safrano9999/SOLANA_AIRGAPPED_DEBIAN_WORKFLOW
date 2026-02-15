#!/bin/bash
# ============================================================================
# Initialize Solana Nonce Account
# ============================================================================

set -e

[ -d "./container_alias" ] && shopt -s expand_aliases && source ./container_alias/check.sh

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLANA_DIR="$SCRIPT_DIR/solana"

# Create solana directory if it doesn't exist
mkdir -p "$SOLANA_DIR"

echo "=== Solana Nonce Account Initialization (XL) ==="
echo ""

# Network selection
echo "Network selection:"
echo "[1] Mainnet"
echo "[2] Devnet"
echo "[3] Both (creates nonce on both networks)"
read -p "Select network [1-3]: " NETWORK_CHOICE

case $NETWORK_CHOICE in
    1)
        NETWORKS=("mainnet")
        ;;
    2)
        NETWORKS=("devnet")
        ;;
    3)
        NETWORKS=("mainnet" "devnet")
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

echo ""

# Get airgapped keypair pubkey
echo "Enter airgapped wallet public key:"
echo "[1] Scan QR code"
echo "[2] Enter manually"
read -p "Select method [1-2]: " PUBKEY_METHOD

case $PUBKEY_METHOD in
    1)
        echo ""
        echo "Point camera at QR code from airgapped PC..."
        AIRGAP_PUBKEY=$(zbarcam --raw -q -1)

        if [ -z "$AIRGAP_PUBKEY" ]; then
            echo "ERROR: No pubkey received from QR code"
            exit 1
        fi

        echo "Scanned pubkey: $AIRGAP_PUBKEY"
        ;;
    2)
        read -p "Enter airgapped wallet PUBLIC KEY: " AIRGAP_PUBKEY

        if [ -z "$AIRGAP_PUBKEY" ]; then
            echo "ERROR: Airgapped pubkey required"
            exit 1
        fi
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

echo ""
echo "Will create nonce account(s) for wallet: $AIRGAP_PUBKEY"
echo "Networks: ${NETWORKS[@]}"
echo ""

read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    exit 0
fi

# Process each network
for NETWORK in "${NETWORKS[@]}"; do
    echo ""
    echo "========================================="
    echo "Processing $NETWORK..."
    echo "========================================="

    NONCE_KEYPAIR="$SOLANA_DIR/${AIRGAP_PUBKEY}-nonce-${NETWORK}.json"

    # Set network URL
    if [ "$NETWORK" == "mainnet" ]; then
        RPC_URL="https://api.mainnet-beta.solana.com"
    else
        RPC_URL="https://api.devnet.solana.com"
    fi

    echo "Setting Solana to $NETWORK..."
    solana config set --url "$RPC_URL"

    # Check if nonce keypair already exists
    if [ -f "$NONCE_KEYPAIR" ]; then
        echo "Nonce keypair already exists for this wallet on $NETWORK"
        read -p "Overwrite? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Skipping $NETWORK..."
            continue
        fi
    fi

    # Generate nonce account keypair
    echo "Generating nonce account keypair..."
    solana-keygen new --no-bip39-passphrase --force -o "$NONCE_KEYPAIR"

    NONCE_PUBKEY=$(solana-keygen pubkey "$NONCE_KEYPAIR")
    echo "Nonce account pubkey: $NONCE_PUBKEY"
    echo ""

    # Check balance
    echo "Checking fee payer balance..."
    BALANCE=$(solana balance | awk '{print $1}')
    echo "Current balance: $BALANCE SOL"

    if (( $(echo "$BALANCE < 0.01" | bc -l) )); then
        echo "ERROR: Insufficient balance on $NETWORK. Need at least 0.01 SOL"

        if [ "$NETWORK" == "devnet" ]; then
            echo "Try: solana airdrop 2"
        fi

        echo "Skipping $NETWORK..."
        rm -f "$NONCE_KEYPAIR"
        continue
    fi

    # Create nonce account
    echo "Creating nonce account (0.002 SOL from default wallet)..."
    solana create-nonce-account "$NONCE_KEYPAIR" 0.002 --nonce-authority "$AIRGAP_PUBKEY"

    echo ""
    echo "✓ Nonce account created on $NETWORK!"
    echo "✓ Nonce pubkey: $NONCE_PUBKEY"
    echo "✓ Authority: $AIRGAP_PUBKEY (airgapped keypair)"
    echo "✓ Saved to: $NONCE_KEYPAIR"
done

echo ""
echo "========================================="
echo "✓ All nonce accounts created successfully!"
echo "========================================="
echo ""
echo "Ready for transactions"
