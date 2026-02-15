#!/bin/bash
# ============================================================================
# Sign transaction offline
# ============================================================================

set -e

# NEU: Header für Container-Aliase (Bare-Metal safe)
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

echo "=== Solana Airgapped Transaction Signer (XL) ==="
echo ""

# Check for zbarcam only if not in test mode
if [ $TEST_MODE -eq 0 ]; then
    if ! command -v zbarcam &> /dev/null; then
        echo "ERROR: zbarcam not found. Install with: sudo apt install zbar-tools"
        exit 1
    fi
fi

if [ $TEST_MODE -eq 1 ]; then
    echo "Paste transaction data from online PC (Ctrl+Shift+V):"
    read -r TX_DATA
else
    echo "Point camera at QR code from online PC..."
    TX_DATA=$(zbarcam --raw -q -1)
fi

if [ -z "$TX_DATA" ]; then
    echo "ERROR: No data received from QR code"
    exit 1
fi

# Parse transaction data
NONCE_VALUE=$(echo "$TX_DATA" | grep -oP 'NONCE_VALUE:\K[^|]+')
NONCE_ACCOUNT=$(echo "$TX_DATA" | grep -oP 'NONCE_ACCOUNT:\K[^|]+')
SIGNER_PUBKEY=$(echo "$TX_DATA" | grep -oP 'SIGNER:\K[^|]+')
RECIPIENT=$(echo "$TX_DATA" | grep -oP 'RECIPIENT:\K[^|]+')
AMOUNT=$(echo "$TX_DATA" | grep -oP 'AMOUNT:\K[^|]+')
TOKEN=$(echo "$TX_DATA" | grep -oP 'TOKEN:\K[^|]+')
MINT=$(echo "$TX_DATA" | grep -oP 'MINT:\K[^|]+')
DECIMALS=$(echo "$TX_DATA" | grep -oP 'DECIMALS:\K[^|]+')

echo ""
echo "Transaction details received:"
echo "  Nonce account: $NONCE_ACCOUNT"
echo "  Recipient: $RECIPIENT"
echo "  Amount: $AMOUNT $TOKEN"
echo "  Decimals: $DECIMALS"
echo "  Signer required: $SIGNER_PUBKEY"
echo ""

# Look for the keypair file
SIGNING_KEYPAIR="$SOLANA_DIR/${SIGNER_PUBKEY}.json"

if [ ! -f "$SIGNING_KEYPAIR" ]; then
    echo "ERROR: Keypair not found: $SIGNING_KEYPAIR"
    echo "Please add ${SIGNER_PUBKEY}.json to $SOLANA_DIR/"
    exit 1
fi

echo "Found keypair: $(basename $SIGNING_KEYPAIR)"
echo ""

read -p "Sign this transaction? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Transaction cancelled"
    exit 0
fi

# Sign the transaction
echo ""
echo "Signing transaction..."

if [ "$TOKEN" == "SOL" ]; then
    # SOL transfer
    SIGNED_OUTPUT=$(solana transfer \
      --keypair "$SIGNING_KEYPAIR" \
      --blockhash "$NONCE_VALUE" \
      --nonce "$NONCE_ACCOUNT" \
      --nonce-authority "$SIGNING_KEYPAIR" \
      --sign-only \
      "$RECIPIENT" \
      "$AMOUNT" 2>&1)

  else
    # SPL token transfer
    S_ATA=$(echo "$TX_DATA" | grep -oP 'S_ATA:\K[^|]+')
    R_ATA=$(echo "$TX_DATA" | grep -oP 'R_ATA:\K[^|]+')
    echo "DEBUG - Signing SPL: $S_ATA -> $R_ATA"

    SIGNED_OUTPUT=$(spl-token transfer \
  --blockhash "$NONCE_VALUE" \
  --nonce "$NONCE_ACCOUNT" \
  --nonce-authority "$SIGNING_KEYPAIR" \
  --fee-payer "$SIGNING_KEYPAIR" \
  --owner "$SIGNING_KEYPAIR" \
  --mint-decimals "$DECIMALS" \
  --from "$S_ATA" \
  --use-unchecked-instruction \
  --sign-only \
  "$MINT" \
  "$AMOUNT" \
  "$R_ATA" 2>&1)
fi

SIGNATURE_LINE=$(echo "$SIGNED_OUTPUT" | grep "=" | grep -v "Signers" | grep -v "Blockhash" | sed 's/^[[:space:]]*//' | head -1)

if [ -z "$SIGNATURE_LINE" ]; then
    echo "ERROR: Failed to extract signature"
    echo "Command output:"
    echo "$SIGNED_OUTPUT"
    exit 1
fi

echo ""
echo "✓ Transaction signed successfully!"
echo "Signature: $SIGNATURE_LINE"
echo ""
echo "Generating output for online PC..."
echo ""

# Display signed transaction
if [ $TEST_MODE -eq 1 ]; then
    echo "════════════════════════════════════════════════════════════════"
    echo "SIGNED TX (copy this with Ctrl+Shift+C):"
    echo "════════════════════════════════════════════════════════════════"
    echo "$SIGNATURE_LINE"
    echo "════════════════════════════════════════════════════════════════"
else
    # NEU: Pipe entfernt, $SIGNATURE_LINE direkt als Argument
    qrencode -t UTF8 "$SIGNATURE_LINE"
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "Show this QR code to the online PC camera"
    echo "════════════════════════════════════════════════════════════════"
fi
