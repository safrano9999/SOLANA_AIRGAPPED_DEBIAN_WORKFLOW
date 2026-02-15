#!/bin/bash
# ============================================================================
# Initialize Stake Accounts
# ============================================================================

set -e

[ -d "./container_alias" ] && shopt -s expand_aliases && source ./container_alias/check.sh

# Logic for additional accounts
EXTRA_FLAG=0
if [[ "$*" == *"--add-stake"* ]]; then
    EXTRA_FLAG=1
    TIMESTAMP=$(date +%s)
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLANA_DIR="$SCRIPT_DIR/solana"

mkdir -p "$SOLANA_DIR"

echo "=== Initialize Solana Stake Accounts ==="
[[ $EXTRA_FLAG -eq 1 ]] && echo "[MODE: Weiterer Account - Überschreiben deaktiviert]"
echo ""

# Check for default wallet
if [ ! -f ~/.config/solana/id.json ]; then
    echo "ERROR: No default Solana wallet found at ~/.config/solana/id.json"
    echo "This wallet is needed to pay for stake account creation."
    echo ""
    echo "Create one with: solana-keygen new"
    exit 1
fi

# Check default wallet balance
echo "Checking default wallet balance..."
DEFAULT_BALANCE=$(solana balance ~/.config/solana/id.json 2>/dev/null | awk '{print $1}')

if [ -z "$DEFAULT_BALANCE" ]; then
    echo "ERROR: Could not check default wallet balance"
    exit 1
fi

echo "Default wallet balance: $DEFAULT_BALANCE SOL"

if (( $(echo "$DEFAULT_BALANCE < 0.01" | bc -l) )); then
    echo "WARNING: Low balance. Need at least ~0.003 SOL per stake account for rent."
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

echo ""

# Scan for wallets with nonce accounts
echo "Scanning for wallets with nonce accounts..."
echo ""

NONCE_FILES=($SOLANA_DIR/*-nonce-*.json)

if [ ${#NONCE_FILES[@]} -eq 0 ] || [ ! -f "${NONCE_FILES[0]}" ]; then
    echo "ERROR: No nonce accounts found."
    exit 1
fi

# Build wallet list with availability
declare -a AVAILABLE_WALLETS
declare -A WALLET_INFO
INDEX=1

for NONCE_FILE in "${NONCE_FILES[@]}"; do
    FILENAME=$(basename "$NONCE_FILE")
    WALLET_PUBKEY=$(echo "$FILENAME" | cut -d'-' -f1)
    NETWORK=$(echo "$FILENAME" | sed 's/.*-nonce-//' | sed 's/.json//')

    # Check if stake account already exists
    STAKE_FILE="$SOLANA_DIR/${WALLET_PUBKEY}-stake-${NETWORK}.json"

    # If EXTRA_FLAG active, always show wallet as available
    if [ ! -f "$STAKE_FILE" ] || [ $EXTRA_FLAG -eq 1 ]; then
        if [ -z "${WALLET_INFO[$WALLET_PUBKEY]}" ]; then
            WALLET_INFO[$WALLET_PUBKEY]="$NETWORK"
        else
            if [[ ! "${WALLET_INFO[$WALLET_PUBKEY]}" == *"$NETWORK"* ]]; then
                WALLET_INFO[$WALLET_PUBKEY]="${WALLET_INFO[$WALLET_PUBKEY]},$NETWORK"
            fi
        fi
    fi
done

# Filter wallets that have at least one available network
for WALLET_PUBKEY in "${!WALLET_INFO[@]}"; do
    AVAILABLE_NETWORKS="${WALLET_INFO[$WALLET_PUBKEY]}"
    if [ ! -z "$AVAILABLE_NETWORKS" ]; then
        AVAILABLE_WALLETS[$INDEX]="$WALLET_PUBKEY"

        # Format available networks
        MAINNET_AVAILABLE=$(echo "$AVAILABLE_NETWORKS" | grep -o "mainnet" || echo "")
        DEVNET_AVAILABLE=$(echo "$AVAILABLE_NETWORKS" | grep -o "devnet" || echo "")

        AVAIL_TEXT=""
        if [ ! -z "$MAINNET_AVAILABLE" ] && [ ! -z "$DEVNET_AVAILABLE" ]; then
            AVAIL_TEXT="mainnet ✓, devnet ✓"
        elif [ ! -z "$MAINNET_AVAILABLE" ]; then
            AVAIL_TEXT="mainnet only"
            if [ -f "$SOLANA_DIR/${WALLET_PUBKEY}-stake-devnet.json" ]; then
                AVAIL_TEXT="$AVAIL_TEXT (devnet stake exists)"
            fi
        elif [ ! -z "$DEVNET_AVAILABLE" ]; then
            AVAIL_TEXT="devnet only"
            if [ -f "$SOLANA_DIR/${WALLET_PUBKEY}-stake-mainnet.json" ]; then
                AVAIL_TEXT="$AVAIL_TEXT (mainnet stake exists)"
            fi
        fi

        echo "[$INDEX] ${WALLET_PUBKEY:0:8}...${WALLET_PUBKEY: -8}"
        echo "    Available: $AVAIL_TEXT"
        echo ""

        INDEX=$((INDEX + 1))
    fi
done

if [ ${#AVAILABLE_WALLETS[@]} -eq 0 ]; then
    echo "No wallets available for stake account creation."
    echo "All wallets already have stake accounts on all available networks."
    exit 0
fi

# Select wallet
read -p "Select wallet [1-${#AVAILABLE_WALLETS[@]}]: " WALLET_CHOICE

if [ -z "$WALLET_CHOICE" ] || [ "$WALLET_CHOICE" -lt 1 ] || [ "$WALLET_CHOICE" -gt ${#AVAILABLE_WALLETS[@]} ]; then
    echo "ERROR: Invalid selection"
    exit 1
fi

SELECTED_WALLET="${AVAILABLE_WALLETS[$WALLET_CHOICE]}"
AVAILABLE_NETWORKS="${WALLET_INFO[$SELECTED_WALLET]}"

echo ""
echo "Selected: ${SELECTED_WALLET:0:12}...${SELECTED_WALLET: -12}"
echo ""

# Determine network options
MAINNET_AVAILABLE=$(echo "$AVAILABLE_NETWORKS" | grep -o "mainnet" || echo "")
DEVNET_AVAILABLE=$(echo "$AVAILABLE_NETWORKS" | grep -o "devnet" || echo "")

declare -a NETWORKS_TO_CREATE

if [ ! -z "$MAINNET_AVAILABLE" ] && [ ! -z "$DEVNET_AVAILABLE" ]; then
    echo "Create stake account on:"
    echo "[1] Mainnet only"
    echo "[2] Devnet only"
    echo "[3] Both networks"
    read -p "Choice [1-3]: " NETWORK_CHOICE

    case $NETWORK_CHOICE in
        1)
            NETWORKS_TO_CREATE=("mainnet")
            ;;
        2)
            NETWORKS_TO_CREATE=("devnet")
            ;;
        3)
            NETWORKS_TO_CREATE=("mainnet" "devnet")
            ;;
        *)
            echo "ERROR: Invalid choice"
            exit 1
            ;;
    esac
elif [ ! -z "$MAINNET_AVAILABLE" ]; then
    echo "Creating stake account on mainnet (only available network)"
    NETWORKS_TO_CREATE=("mainnet")
elif [ ! -z "$DEVNET_AVAILABLE" ]; then
    echo "Creating stake account on devnet (only available network)"
    NETWORKS_TO_CREATE=("devnet")
else
    echo "ERROR: No networks available"
    exit 1
fi

echo ""
echo "Wallet pubkey: ${SELECTED_WALLET:0:12}...${SELECTED_WALLET: -12}"
echo ""

read -p "Create stake account(s) for this wallet? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    exit 0
fi

echo ""

# Create stake accounts
declare -a CREATED_STAKES

for NETWORK in "${NETWORKS_TO_CREATE[@]}"; do
    echo "========================================="
    echo "Creating stake account on $NETWORK..."
    echo "========================================="

    # Modified naming when EXTRA_FLAG active
    if [ $EXTRA_FLAG -eq 1 ]; then
        STAKE_KEYPAIR="$SOLANA_DIR/${SELECTED_WALLET}-stake-${NETWORK}-${TIMESTAMP}.json"
    else
        STAKE_KEYPAIR="$SOLANA_DIR/${SELECTED_WALLET}-stake-${NETWORK}.json"
    fi

    # Set network URL
    if [ "$NETWORK" == "mainnet" ]; then
        RPC_URL="https://api.mainnet-beta.solana.com"
    else
        RPC_URL="https://api.devnet.solana.com"
    fi

    solana config set --url "$RPC_URL" > /dev/null

    # Generate stake account keypair
    echo "Generating stake account keypair..."
    solana-keygen new --no-bip39-passphrase --force -o "$STAKE_KEYPAIR" > /dev/null

    STAKE_PUBKEY=$(solana-keygen pubkey "$STAKE_KEYPAIR")
    echo "Stake account pubkey: $STAKE_PUBKEY"
    echo ""

    # Create stake account
    echo "Creating stake account on-chain..."
    echo "Funding with rent-exempt minimum from default wallet..."

    solana create-stake-account \
        "$STAKE_KEYPAIR" \
        0.00228288 \
        --from ~/.config/solana/id.json \
        --stake-authority "$SELECTED_WALLET" \
        --withdraw-authority "$SELECTED_WALLET"

    echo ""
    echo "✓ Stake account created on $NETWORK!"
    echo "  Address: $STAKE_PUBKEY"
    echo "  Stake authority: $SELECTED_WALLET"
    echo "  Withdraw authority: $SELECTED_WALLET"
    echo "  Funded by: ~/.config/solana/id.json"
    echo "  Saved to: $STAKE_KEYPAIR"
    echo ""

    CREATED_STAKES+=("$NETWORK|$STAKE_PUBKEY")
done

echo "========================================="
echo "✓ All stake accounts created successfully!"
echo "========================================="
echo ""

# Summary
echo "Summary:"
echo "  Wallet: ${SELECTED_WALLET:0:12}...${SELECTED_WALLET: -12}"
for STAKE_INFO in "${CREATED_STAKES[@]}"; do
    NETWORK=$(echo "$STAKE_INFO" | cut -d'|' -f1)
    PUBKEY=$(echo "$STAKE_INFO" | cut -d'|' -f2)
    echo "  $NETWORK stake: ${PUBKEY:0:12}...${PUBKEY: -12}"
done
echo ""
echo "Both authorities set to: ${SELECTED_WALLET:0:12}...${SELECTED_WALLET: -12}"
echo "Funded by: ~/.config/solana/id.json"
echo ""
echo "✓ Initialization complete!"
echo ""
