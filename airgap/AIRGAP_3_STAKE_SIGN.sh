#!/bin/bash
# ============================================================================
# stake-offline.sh - Sign stake transactions offline (FINAL VERSION)
# ============================================================================

set -e

# NEU: Header für Container-Aliase (Bare-Metal safe)
[ -d "./container_alias" ] && shopt -s expand_aliases && source ./container_alias/check.sh

# Check for debug mode
TEST_MODE=0
if [ "$1" = "--debug" ]; then
    TEST_MODE=1
    echo "[DEBUG MODE]"
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLANA_DIR="$SCRIPT_DIR/solana"

if [ $TEST_MODE -eq 1 ]; then
    echo "Paste transaction data:"
    read -r TX_DATA
else
    echo "Point camera at QR code..."
    TX_DATA=$(zbarcam --raw -q -1)
fi

# Parsing der Daten aus dem QR-Code
ACTION=$(echo "$TX_DATA" | grep -oP 'ACTION:\K[^|]+' || echo "")
NONCE_VALUE=$(echo "$TX_DATA" | grep -oP 'NONCE:\K[^|]+' || echo "")
NONCE_ACCOUNT=$(echo "$TX_DATA" | grep -oP 'NONCE_ACCOUNT:\K[^|]+' || echo "")
WALLET=$(echo "$TX_DATA" | grep -oP 'WALLET:\K[^|]+' || echo "")
STAKE_ACCOUNT=$(echo "$TX_DATA" | grep -oP 'STAKE_ACCOUNT:\K[^|]+' || echo "")
VALIDATOR=$(echo "$TX_DATA" | grep -oP 'VALIDATOR:\K[^|]+' || echo "")
VALIDATOR_NAME=$(echo "$TX_DATA" | grep -oP 'VALIDATOR_NAME:\K[^|]+' || echo "Unknown")
AMOUNT=$(echo "$TX_DATA" | grep -oP 'AMOUNT:\K[^|]+' || echo "")
SOURCE_STAKE=$(echo "$TX_DATA" | grep -oP 'SOURCE_STAKE:\K[^|]+' || echo "")
NETWORK=$(echo "$TX_DATA" | grep -oP 'NETWORK:\K[^|]+' || echo "mainnet")


# --- BACKUP LOGIK (Anforderung 2026-01-19) ---
BACKUP_FILE="$SOLANA_DIR/stake-${NETWORK}-accounts.json"

if [ ! -f "$BACKUP_FILE" ]; then echo "{}" > "$BACKUP_FILE"; fi

# Speichere Stake-Account + Wallet + Validator Info
if ! grep -q "$STAKE_ACCOUNT" "$BACKUP_FILE"; then
    echo "Backing up new stake account address..."
    sed -i "s/}/  \"$STAKE_ACCOUNT\": {\"wallet\": \"$WALLET\", \"validator\": \"$VALIDATOR_NAME\", \"validator_addr\": \"$VALIDATOR\"},\n}/" "$BACKUP_FILE"
    sed -i 's/,\n}/\n}/' "$BACKUP_FILE"
fi

WALLET_KEYPAIR="$SOLANA_DIR/$WALLET.json"

if [ ! -f "$WALLET_KEYPAIR" ]; then
    echo "ERROR: Keypair not found at $WALLET_KEYPAIR"
    exit 1
fi

case "$ACTION" in
    FUND_STAKE)
        echo "Signing transfer of $AMOUNT SOL to stake account..."
        SIGNED_OUTPUT=$(solana transfer "$STAKE_ACCOUNT" "$AMOUNT" \
            --from "$WALLET_KEYPAIR" \
            --blockhash "$NONCE_VALUE" \
            --nonce "$NONCE_ACCOUNT" \
            --nonce-authority "$WALLET_KEYPAIR" \
            --fee-payer "$WALLET_KEYPAIR" \
            --sign-only 2>&1)
        ;;

    DELEGATE_STAKE)
        echo "Signing delegation to $VALIDATOR..."
        SIGNED_OUTPUT=$(solana delegate-stake \
            --blockhash "$NONCE_VALUE" \
            --nonce "$NONCE_ACCOUNT" \
            --nonce-authority "$WALLET_KEYPAIR" \
            --stake-authority "$WALLET_KEYPAIR" \
            --fee-payer "$WALLET_KEYPAIR" \
            --sign-only \
            "$STAKE_ACCOUNT" \
            "$VALIDATOR" 2>&1)
        ;;

    DEACTIVATE_STAKE)
        echo "Signing deactivation..."
        SIGNED_OUTPUT=$(solana deactivate-stake \
            --blockhash "$NONCE_VALUE" \
            --nonce "$NONCE_ACCOUNT" \
            --nonce-authority "$WALLET_KEYPAIR" \
            --stake-authority "$WALLET_KEYPAIR" \
            --fee-payer "$WALLET_KEYPAIR" \
            --sign-only \
            "$STAKE_ACCOUNT" 2>&1)
        ;;

    WITHDRAW_STAKE)
        echo "Signing withdrawal of $AMOUNT SOL..."
        SIGNED_OUTPUT=$(solana withdraw-stake \
            --blockhash "$NONCE_VALUE" \
            --nonce "$NONCE_ACCOUNT" \
            --nonce-authority "$WALLET_KEYPAIR" \
            --fee-payer "$WALLET_KEYPAIR" \
            --sign-only \
            "$STAKE_ACCOUNT" \
            "$WALLET" \
            "$AMOUNT" 2>&1)
        ;;

    MERGE_STAKE)
        echo "Signing merge: $SOURCE_STAKE into $STAKE_ACCOUNT..."
        SIGNED_OUTPUT=$(solana merge-stake \
            --blockhash "$NONCE_VALUE" \
            --nonce "$NONCE_ACCOUNT" \
            --nonce-authority "$WALLET_KEYPAIR" \
            --stake-authority "$WALLET_KEYPAIR" \
            --fee-payer "$WALLET_KEYPAIR" \
            --sign-only \
            "$STAKE_ACCOUNT" \
            "$SOURCE_STAKE" 2>&1)
        ;;

    *)
        echo "ERROR: Unknown action: $ACTION"
        exit 1
        ;;
esac

# Signatur extrahieren
SIGNATURE_LINE=$(echo "$SIGNED_OUTPUT" | grep "=" | grep -v "Signers" | grep -v "Blockhash" | sed 's/^[[:space:]]*//' | head -1)

if [ -z "$SIGNATURE_LINE" ]; then
    echo "ERROR: Could not create signature."
    exit 1
fi

echo ""
echo "=== SIGNATURE CREATED ==="
if [ $TEST_MODE -eq 1 ]; then
    echo "$SIGNATURE_LINE"
else
    # NEU: Pipe entfernt, $SIGNATURE_LINE direkt als Argument
    qrencode -t UTF8 "$SIGNATURE_LINE"
fi
