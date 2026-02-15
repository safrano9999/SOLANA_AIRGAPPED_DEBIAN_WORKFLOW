#!/bin/bash
# ============================================================================
# Manage Solana Stake Accounts (ONLINE VERSION - FIXED)
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

echo "=== Solana Stake Manager ==="
echo ""

# Scan for stake accounts
STAKE_FILES=($SOLANA_DIR/*-stake-*.json)

if [ ${#STAKE_FILES[@]} -eq 0 ] || [ ! -f "${STAKE_FILES[0]}" ]; then
    echo "ERROR: No stake accounts found."
    exit 1
fi

# Build stake account list
declare -a STAKE_LIST
INDEX=0
for STAKE_FILE in "${STAKE_FILES[@]}"; do
    FILENAME=$(basename "$STAKE_FILE")
    WALLET_PUBKEY=$(echo "$FILENAME" | cut -d'-' -f1)
    NETWORK=$(echo "$FILENAME" | sed 's/.*-stake-//' | sed 's/.json//')
    STAKE_LIST[$INDEX]="$WALLET_PUBKEY|$NETWORK|$STAKE_FILE"
    DISPLAY_NUM=$((INDEX + 1))
    echo "[$DISPLAY_NUM] ${WALLET_PUBKEY:0:8}...${WALLET_PUBKEY: -8} ($NETWORK)"
    INDEX=$((INDEX + 1))
done
TOTAL_STAKES=$INDEX

echo ""
read -p "Select stake account [1-$TOTAL_STAKES]: " STAKE_CHOICE
ARRAY_INDEX=$((STAKE_CHOICE - 1))
SELECTED_DATA=${STAKE_LIST[$ARRAY_INDEX]}
SELECTED_WALLET=$(echo "$SELECTED_DATA" | cut -d'|' -f1)
SELECTED_NETWORK=$(echo "$SELECTED_DATA" | cut -d'|' -f2)
SELECTED_STAKE_FILE=$(echo "$SELECTED_DATA" | cut -d'|' -f3)

STAKE_PUBKEY=$(solana-keygen pubkey "$SELECTED_STAKE_FILE")
# Nonce-File-Pfad korrigiert (nimmt den Basisnamen des Netzwerks)
BASE_NET=$(echo "$SELECTED_NETWORK" | cut -d'-' -f1)
NONCE_FILE="$SOLANA_DIR/$SELECTED_WALLET-nonce-$BASE_NET.json"
NONCE_ACCOUNT=$(solana-keygen pubkey "$NONCE_FILE")

if [ "$BASE_NET" == "mainnet" ]; then
    RPC_URL="https://api.mainnet-beta.solana.com"
else
    RPC_URL="https://api.devnet.solana.com"
fi

solana config set --url "$RPC_URL" > /dev/null

echo ""
echo "--- LIVE BLOCKCHAIN STATUS ---"
solana epoch-info | grep -E "Epoch|Progress"
echo "Wallet: $SELECTED_WALLET"
WALLET_BALANCE=$(solana balance "$SELECTED_WALLET" | awk '{print $1}')
echo "Guthaben: $WALLET_BALANCE SOL"
echo "------------------------------"
echo "Stake Account: $STAKE_PUBKEY"
STAKE_OUTPUT=$(solana stake-account "$STAKE_PUBKEY" 2>/dev/null || echo "Nicht gefunden")

if [[ "$STAKE_OUTPUT" == "Nicht gefunden" ]]; then
    echo "Status: Konto noch nicht auf der Blockchain."
    STAKE_BALANCE="0"
else
    echo "$STAKE_OUTPUT" | grep -E "Balance|Status|Active Stake|Activating Stake"
    STAKE_BALANCE=$(echo "$STAKE_OUTPUT" | grep "Balance:" | awk '{print $2}')
fi
echo "------------------------------"

echo ""
echo "What would you like to do?"
echo "[1] Fund stake account (Transfer from Cold Wallet)"
echo "[2] Delegate stake to validator"
echo "[3] Deactivate stake (unstake)"
echo "[4] Withdraw stake (after deactivation)"
echo "[5] Merge stake accounts"
echo "[6] Split stake account"
echo "[7] Detailed Status / Rewards"
echo "[8] Exit"
echo ""
read -p "Choice [1-8]: " OPERATION

# Helper für QR & Broadcast
get_signed_tx() {
    local DATA="$1"
    if [ $TEST_MODE -eq 1 ]; then
        echo "════════════════════════════════════════"
        echo "$DATA"
        echo "════════════════════════════════════════"
    else
        # FIX: Anführungszeichen um DATA, keine Pipe
        qrencode -t UTF8 "$DATA"
    fi
    echo ""
    read -p "Press ENTER when ready to receive signed transaction..."
    if [ $TEST_MODE -eq 1 ]; then
        read -r SIGNED_TX
    else
        SIGNED_TX=$(zbarcam --raw -q -1)
    fi
    if [ -z "$SIGNED_TX" ]; then echo "ERROR: No data"; exit 1; fi
    echo "$SIGNED_TX"
}

case $OPERATION in
    1)
        read -p "Amount to transfer (SOL): " AMOUNT
        NONCE_VALUE=$(solana nonce "$NONCE_ACCOUNT" | head -1)
        TX_DATA="ACTION:FUND_STAKE|NONCE:$NONCE_VALUE|NONCE_ACCOUNT:$NONCE_ACCOUNT|WALLET:$SELECTED_WALLET|STAKE_ACCOUNT:$STAKE_PUBKEY|AMOUNT:$AMOUNT|NETWORK:$SELECTED_NETWORK"
        SIGNED=$(get_signed_tx "$TX_DATA")
        SIG=$(echo "$SIGNED" | cut -d'=' -f2)
        solana transfer "$STAKE_PUBKEY" "$AMOUNT" --from "$SELECTED_WALLET" --blockhash "$NONCE_VALUE" --nonce "$NONCE_ACCOUNT" --nonce-authority "$SELECTED_WALLET" --fee-payer "$SELECTED_WALLET" --signer "$SELECTED_WALLET=$SIG"
        ;;
    2)
        # Validator Auswahl (vereinfacht für Übersicht)
        echo "1) Jito 2) Everstake 3) Laine 4) Custom"
        read -p "Choice: " V_CHOICE
        case $V_CHOICE in
            1) V_PUB="6i65S85F6Yy1T2V8B3FjW2B5T4Y3V5S8S85F6Yy1T2V" ; V_NAME="Jito" ;;
            2) V_PUB="EARNynHRWg6GfyJCmrriZeZzY8Y8gYmejN2m7mDUUtBD" ; V_NAME="Everstake" ;;
            3) V_PUB="ey7Git54dtxJ42T9T8dvH1HE5cHT8cv3otSTFSGUucQ" ; V_NAME="Laine" ;;
            4) read -p "Pubkey: " V_PUB ; V_NAME="Custom" ;;
            *) exit 1 ;;
        esac
        NONCE_VALUE=$(solana nonce "$NONCE_ACCOUNT" | head -1)
        TX_DATA="ACTION:DELEGATE_STAKE|NONCE:$NONCE_VALUE|NONCE_ACCOUNT:$NONCE_ACCOUNT|WALLET:$SELECTED_WALLET|STAKE_ACCOUNT:$STAKE_PUBKEY|VALIDATOR:$V_PUB|VALIDATOR_NAME:$V_NAME|NETWORK:$SELECTED_NETWORK"
        SIGNED=$(get_signed_tx "$TX_DATA")
        SIG=$(echo "$SIGNED" | cut -d'=' -f2)
        solana delegate-stake --blockhash "$NONCE_VALUE" --nonce "$NONCE_ACCOUNT" --nonce-authority "$SELECTED_WALLET" --stake-authority "$SELECTED_WALLET" --fee-payer "$SELECTED_WALLET" --signer "$SELECTED_WALLET=$SIG" "$STAKE_PUBKEY" "$V_PUB"
        ;;
    3)
        NONCE_VALUE=$(solana nonce "$NONCE_ACCOUNT" | head -1)
        TX_DATA="ACTION:DEACTIVATE_STAKE|NONCE:$NONCE_VALUE|NONCE_ACCOUNT:$NONCE_ACCOUNT|WALLET:$SELECTED_WALLET|STAKE_ACCOUNT:$STAKE_PUBKEY|NETWORK:$SELECTED_NETWORK"
        SIGNED=$(get_signed_tx "$TX_DATA")
        SIG=$(echo "$SIGNED" | cut -d'=' -f2)
        solana deactivate-stake --blockhash "$NONCE_VALUE" --nonce "$NONCE_ACCOUNT" --nonce-authority "$SELECTED_WALLET" --stake-authority "$SELECTED_WALLET" --fee-payer "$SELECTED_WALLET" --signer "$SELECTED_WALLET=$SIG" "$STAKE_PUBKEY"
        ;;
    4)
        NONCE_VALUE=$(solana nonce "$NONCE_ACCOUNT" | head -1)
        TX_DATA="ACTION:WITHDRAW_STAKE|NONCE:$NONCE_VALUE|NONCE_ACCOUNT:$NONCE_ACCOUNT|WALLET:$SELECTED_WALLET|STAKE_ACCOUNT:$STAKE_PUBKEY|AMOUNT:$STAKE_BALANCE|NETWORK:$SELECTED_NETWORK"
        SIGNED=$(get_signed_tx "$TX_DATA")
        SIG=$(echo "$SIGNED" | cut -d'=' -f2)
        solana withdraw-stake --blockhash "$NONCE_VALUE" --nonce "$NONCE_ACCOUNT" --nonce-authority "$SELECTED_WALLET" --withdraw-authority "$SELECTED_WALLET" --fee-payer "$SELECTED_WALLET" --signer "$SELECTED_WALLET=$SIG" "$STAKE_PUBKEY" "$SELECTED_WALLET" "$STAKE_BALANCE"
        ;;
    5)
        read -p "Enter Pubkey of the account to be ABSORBED (Source): " SOURCE_STAKE
        NONCE_VALUE=$(solana nonce "$NONCE_ACCOUNT" | head -1)
        TX_DATA="ACTION:MERGE_STAKE|NONCE:$NONCE_VALUE|NONCE_ACCOUNT:$NONCE_ACCOUNT|WALLET:$SELECTED_WALLET|STAKE_ACCOUNT:$STAKE_PUBKEY|SOURCE_STAKE:$SOURCE_STAKE|NETWORK:$SELECTED_NETWORK"
        SIGNED=$(get_signed_tx "$TX_DATA")
        SIG=$(echo "$SIGNED" | cut -d'=' -f2)
        solana merge-stake --blockhash "$NONCE_VALUE" --nonce "$NONCE_ACCOUNT" --nonce-authority "$SELECTED_WALLET" --stake-authority "$SELECTED_WALLET" --fee-payer "$SELECTED_WALLET" --signer "$SELECTED_WALLET=$SIG" "$STAKE_PUBKEY" "$SOURCE_STAKE"
        ;;
    6)
        read -p "Amount to split OFF (SOL): " SPLIT_AMOUNT
        read -p "Enter Pubkey of the NEW (empty) stake account: " NEW_STAKE_PUBKEY
        NONCE_VALUE=$(solana nonce "$NONCE_ACCOUNT" | head -1)
        TX_DATA="ACTION:SPLIT_STAKE|NONCE:$NONCE_VALUE|NONCE_ACCOUNT:$NONCE_ACCOUNT|WALLET:$SELECTED_WALLET|STAKE_ACCOUNT:$STAKE_PUBKEY|NEW_STAKE:$NEW_STAKE_PUBKEY|AMOUNT:$SPLIT_AMOUNT|NETWORK:$SELECTED_NETWORK"
        SIGNED=$(get_signed_tx "$TX_DATA")
        SIG=$(echo "$SIGNED" | cut -d'=' -f2)
        solana split-stake --blockhash "$NONCE_VALUE" --nonce "$NONCE_ACCOUNT" --nonce-authority "$SELECTED_WALLET" --stake-authority "$SELECTED_WALLET" --fee-payer "$SELECTED_WALLET" --signer "$SELECTED_WALLET=$SIG" "$STAKE_PUBKEY" "$NEW_STAKE_PUBKEY" "$SPLIT_AMOUNT"
        ;;
    7)
        solana stake-account "$STAKE_PUBKEY"
        echo "--- Rewards (last 5) ---"
        solana stake-history --limit 5
        ;;
    8) exit 0 ;;
    *) echo "Invalid choice" ;;
esac

echo "✓ Operation beendet."
