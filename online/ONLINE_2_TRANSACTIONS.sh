#!/bin/bash
# ============================================================================
# Create and broadcast transaction (ONLINE VERSION - FIXED)
# ============================================================================

set -e

[ -d "./container_alias" ] && shopt -s expand_aliases && source ./container_alias/check.sh

# Check for debug mode
TEST_MODE=0
if [ "$1" = "--debug" ]; then
    TEST_MODE=1
    echo "[DEBUG MODE - Using text input instead of QR codes]"
    echo ""
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLANA_DIR="$SCRIPT_DIR/solana"

echo "=== Solana Air-Gapped Transaction System (XL) ==="
echo ""

# Scan for available wallets
NONCE_FILES=($SOLANA_DIR/*-nonce-*.json)

if [ ${#NONCE_FILES[@]} -eq 0 ] || [ ! -f "${NONCE_FILES[0]}" ]; then
    echo "ERROR: No nonce accounts found."
    exit 1
fi

# Stable wallet selection
declare -a WALLET_KEYS
declare -A WALLET_MAP
INDEX=1

for NONCE_FILE in "${NONCE_FILES[@]}"; do
    FILENAME=$(basename "$NONCE_FILE")
    PK=$(echo "$FILENAME" | cut -d'-' -f1)
    NET=$(echo "$FILENAME" | sed 's/.*-nonce-//' | sed 's/.json//')

    W_KEY="${PK}-${NET}"
    WALLET_KEYS[$INDEX]="$W_KEY"
    WALLET_MAP["$W_KEY"]="$NONCE_FILE"

    echo "[$INDEX] ${PK:0:8}...${PK: -8} ($NET)"
    INDEX=$((INDEX + 1))
done

echo ""
read -p "Select wallet [1-$((INDEX - 1))]: " WALLET_CHOICE

# Assign data safely
SELECTED_KEY="${WALLET_KEYS[$WALLET_CHOICE]}"
SELECTED_NONCE_FILE="${WALLET_MAP[$SELECTED_KEY]}"

if [ -z "$SELECTED_NONCE_FILE" ]; then
    echo "ERROR: Invalid selection!"
    exit 1
fi

SELECTED_PUBKEY=$(echo "$SELECTED_KEY" | cut -d'-' -f1)
SELECTED_NETWORK=$(echo "$SELECTED_KEY" | cut -d'-' -f2)

# --- DER KAPUTTE ZWEITE LOOP WURDE HIER ENTFERNT ---

echo ""
echo "Selected: ${SELECTED_PUBKEY:0:8}...${SELECTED_PUBKEY: -8} ($SELECTED_NETWORK)"
echo ""

# Set network
if [ "$SELECTED_NETWORK" == "mainnet" ]; then
    RPC_URL="https://api.mainnet-beta.solana.com"
else
    RPC_URL="https://api.devnet.solana.com"
fi

solana config set --url "$RPC_URL" > /dev/null

# Load token registry
TOKENS_JSON="$SCRIPT_DIR/tokens-${SELECTED_NETWORK}.json"

# Get nonce account address
NONCE_ACCOUNT=$(solana-keygen pubkey "$SELECTED_NONCE_FILE")

# Fetch current nonce value
echo "Fetching current nonce value..."
NONCE_OUTPUT=$(solana nonce "$NONCE_ACCOUNT" 2>&1)
NONCE_EXIT_CODE=$?

if [ $NONCE_EXIT_CODE -ne 0 ]; then
    echo "ERROR: Failed to fetch nonce"
    echo "$NONCE_OUTPUT"
    exit 1
fi

NONCE_VALUE=$(echo "$NONCE_OUTPUT" | grep -v "^$" | head -1)

if [ -z "$NONCE_VALUE" ]; then
    echo "ERROR: Could not fetch nonce value"
    exit 1
fi

echo "Current nonce: $NONCE_VALUE"
echo ""

# Check balances
echo "Checking balances for ${SELECTED_PUBKEY:0:8}...${SELECTED_PUBKEY: -8}..."

# SOL balance
SOL_BALANCE=$(solana balance "$SELECTED_PUBKEY" | awk '{print $1}')

# SPL token balances
SPL_OUTPUT=$(spl-token accounts --owner "$SELECTED_PUBKEY" 2>/dev/null || echo "")

# Parse and display balances
declare -a TOKENS
declare -a TOKEN_BALANCES
declare -a TOKEN_MINTS
TOKEN_INDEX=1

# Add SOL
TOKENS[1]="SOL"
TOKEN_BALANCES[1]="$SOL_BALANCE"
TOKEN_MINTS[1]="native"

echo "  [1] SOL: $SOL_BALANCE SOL"

# Helper function to get token info
get_token_info() {
    local MINT=$1
    if [ ! -f "$TOKENS_JSON" ]; then return 1; fi
    if ! command -v jq &> /dev/null; then return 1; fi

    local INFO=$(jq -r ".\"${MINT}\"" "$TOKENS_JSON" 2>/dev/null)
    if [ -z "$INFO" ] || [ "$INFO" == "null" ]; then return 1; fi

    local SYMBOL=$(echo "$INFO" | jq -r '.symbol')
    local NAME=$(echo "$INFO" | jq -r '.name')
    echo "${SYMBOL}|${NAME}"
}

# Parse SPL tokens
if [ ! -z "$SPL_OUTPUT" ]; then
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*([A-Za-z0-9]+)[[:space:]]+([0-9.]+) ]]; then
            MINT="${BASH_REMATCH[1]}"
            BALANCE="${BASH_REMATCH[2]}"

            if (( $(echo "$BALANCE > 0" | bc -l) )); then
                TOKEN_INDEX=$((TOKEN_INDEX + 1))
                # Token Info sauber abrufen
                T_INFO=$(get_token_info "$MINT" || echo "")

                if [ ! -z "$T_INFO" ]; then
                    SYMBOL=$(echo "$T_INFO" | cut -d'|' -f1)
                    NAME=$(echo "$T_INFO" | cut -d'|' -f2)
                    TOKENS[$TOKEN_INDEX]="$SYMBOL"
                    echo "  [$TOKEN_INDEX] $SYMBOL: $BALANCE ($NAME)"
                else
                    TOKENS[$TOKEN_INDEX]="SPL-${MINT:0:8}"
                    echo "  [$TOKEN_INDEX] ${MINT:0:8}...${MINT: -8}: $BALANCE"
                fi

                TOKEN_BALANCES[$TOKEN_INDEX]="$BALANCE"
                TOKEN_MINTS[$TOKEN_INDEX]="$MINT"
            fi
        fi
    done <<< "$SPL_OUTPUT"
fi

echo ""

# Token selection
if [ $TOKEN_INDEX -eq 1 ]; then
    SELECTED_TOKEN_INDEX=1
else
    read -p "Select token to send [1-$TOKEN_INDEX]: " SELECTED_TOKEN_INDEX
    if [ -z "$SELECTED_TOKEN_INDEX" ] || [ $SELECTED_TOKEN_INDEX -lt 1 ] || [ $SELECTED_TOKEN_INDEX -gt $TOKEN_INDEX ]; then
        echo "ERROR: Invalid token selection"; exit 1
    fi
fi

SELECTED_TOKEN="${TOKENS[$SELECTED_TOKEN_INDEX]}"
SELECTED_BALANCE="${TOKEN_BALANCES[$SELECTED_TOKEN_INDEX]}"
SELECTED_MINT="${TOKEN_MINTS[$SELECTED_TOKEN_INDEX]}"

# Get decimals
if [ "$SELECTED_TOKEN" == "SOL" ]; then
    DECIMALS="9"
else
    DECIMALS=$(solana token supply "$SELECTED_MINT" 2>/dev/null | grep "Decimals:" | awk '{print $2}')
    if [ -z "$DECIMALS" ]; then DECIMALS="6"; fi
fi

echo "Selected: $SELECTED_TOKEN (Balance: $SELECTED_BALANCE)"
echo ""

# Get recipient
read -p "Enter recipient address: " RECIPIENT
if [ -z "$RECIPIENT" ]; then echo "ERROR: Recipient required"; exit 1; fi

# Get amount
while true; do
    read -p "Enter amount (max: $SELECTED_BALANCE): " AMOUNT
    if [ -z "$AMOUNT" ]; then continue; fi
    if (( $(echo "$AMOUNT > $SELECTED_BALANCE" | bc -l) )); then echo "Zu hoch"; continue; fi
    break
done

if [ "$SELECTED_TOKEN" == "SOL" ]; then
    S_ATA=""; R_ATA=""
else
    echo "Checking Token Accounts..."
    S_ATA=$(spl-token address --token "$SELECTED_MINT" --owner "$SELECTED_PUBKEY")
    R_ATA=$(spl-token address --token "$SELECTED_MINT" --owner "$RECIPIENT")

    if ! solana account "$S_ATA" >/dev/null 2>&1; then
        spl-token create-account "$SELECTED_MINT" --owner "$SELECTED_PUBKEY"
    fi
    if ! solana account "$R_ATA" >/dev/null 2>&1; then
        spl-token create-account "$SELECTED_MINT" --owner "$RECIPIENT"
    fi
fi

# Build transaction data
TX_DATA="NONCE_VALUE:$NONCE_VALUE|NONCE_ACCOUNT:$NONCE_ACCOUNT|SIGNER:$SELECTED_PUBKEY|RECIPIENT:$RECIPIENT|AMOUNT:$AMOUNT|TOKEN:$SELECTED_TOKEN|MINT:$SELECTED_MINT|DECIMALS:$DECIMALS|S_ATA:$S_ATA|R_ATA:$R_ATA"

echo ""
echo "Generating QR code..."
if [ $TEST_MODE -eq 1 ]; then
    echo "$TX_DATA"
else
    # FIX: Anführungszeichen um $TX_DATA
    qrencode -t UTF8 "$TX_DATA"
fi

echo ""
read -p "Press ENTER when ready to receive signed transaction..."

if [ $TEST_MODE -eq 1 ]; then
    read -r SIGNED_TX
else
    SIGNED_TX=$(zbarcam --raw -q -1)
fi

# Parse & Broadcast
SIGNER=$(echo "$SIGNED_TX" | cut -d'=' -f1)
SIGNATURE=$(echo "$SIGNED_TX" | cut -d'=' -f2)

if [ "$SELECTED_TOKEN" == "SOL" ]; then
    solana transfer --from "$SIGNER" --blockhash "$NONCE_VALUE" --nonce "$NONCE_ACCOUNT" \
      --nonce-authority "$SIGNER" --signer "$SIGNER=$SIGNATURE" --fee-payer "$SIGNER" \
      --allow-unfunded-recipient "$RECIPIENT" "$AMOUNT"
else
    spl-token transfer --blockhash "$NONCE_VALUE" --nonce "$NONCE_ACCOUNT" \
      --nonce-authority "$SIGNER" --fee-payer "$SIGNER" --owner "$SIGNER" \
      --signer "$SIGNER=$SIGNATURE" --mint-decimals "$DECIMALS" --from "$S_ATA" \
      --use-unchecked-instruction "$SELECTED_MINT" "$AMOUNT" "$R_ATA"
fi

echo "✓ Broadcast fertig!"
