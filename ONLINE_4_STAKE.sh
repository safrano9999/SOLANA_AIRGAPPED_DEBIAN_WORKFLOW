#!/bin/bash
# ============================================================================
# Manage Solana Stake Accounts
# ============================================================================

set -e

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
NONCE_FILE="$SOLANA_DIR/$SELECTED_WALLET-nonce-$(echo $SELECTED_NETWORK | cut -d'-' -f1).json"
NONCE_ACCOUNT=$(solana-keygen pubkey "$NONCE_FILE")

if [ "$SELECTED_NETWORK" == "mainnet" ]; then
    RPC_URL="https://api.mainnet-beta.solana.com"
else
    RPC_URL="https://api.devnet.solana.com"
fi

# Simple status block
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
echo "Account Balances:"
echo "  Wallet balance: $WALLET_BALANCE SOL"
echo "  Stake account balance: $STAKE_BALANCE SOL"
echo ""
echo "What would you like to do?"
echo "[0] Fund stake account (Transfer from Cold Wallet)"
echo "[1] Delegate stake to validator"
echo "[2] Deactivate stake (unstake)"
echo "[3] Withdraw stake (after deactivation)"
echo "[4] Check detailed status"
echo "[5] Merge stake"
echo "[6] Split stake"

echo "[7] Exit"
echo ""
read -p "Choice [0-5]: " OPERATION

case $OPERATION in
    0)
        echo "=== Fund Stake Account ==="
        read -p "Amount to transfer (SOL): " AMOUNT
        NONCE_VALUE=$(solana nonce "$NONCE_ACCOUNT" | head -1)
        TX_DATA="ACTION:FUND_STAKE|NONCE:$NONCE_VALUE|NONCE_ACCOUNT:$NONCE_ACCOUNT|WALLET:$SELECTED_WALLET|STAKE_ACCOUNT:$STAKE_PUBKEY|AMOUNT:$AMOUNT|NETWORK:$SELECTED_NETWORK"
        if [ $TEST_MODE -eq 1 ]; then echo "$TX_DATA"; else echo "$TX_DATA" | qrencode -t UTF8; fi
        read -p "Press ENTER when ready to receive signed transaction..."
        if [ $TEST_MODE -eq 1 ]; then read -r SIGNED_TX; else SIGNED_TX=$(zbarcam --raw -q -1); fi
        SIGNER=$(echo "$SIGNED_TX" | cut -d'=' -f1)
        SIGNATURE=$(echo "$SIGNED_TX" | cut -d'=' -f2)
        solana transfer "$STAKE_PUBKEY" "$AMOUNT" --from "$SELECTED_WALLET" --blockhash "$NONCE_VALUE" --nonce "$NONCE_ACCOUNT" --nonce-authority "$SELECTED_WALLET" --fee-payer "$SELECTED_WALLET" --signer "$SIGNER=$SIGNATURE"
        ;;
    1)
        echo "=== Delegate Stake ==="
        if [ "$SELECTED_NETWORK" == "devnet" ]; then
            echo "NETWORK: devnet detected."
            read -p "Enter devnet validator vote account pubkey: " VALIDATOR_PUBKEY
            VALIDATOR_NAME="Devnet Validator"
        else
            echo "Select mainnet validator:"
            echo "[1] Jito (MEV enabled - 5% fee)"
            echo "[2] Marinade (Native Staking - variable fee)"
            echo "[3] Everstake (7% fee)"
            echo "[4] Laine (5% fee)"
            echo "[5] Shinobi Systems (6% fee)"
            echo "[6] Chorus One (8% fee)"
            echo "[7] Enter custom validator pubkey"
            echo ""
            read -p "Choice [1-7]: " VALIDATOR_CHOICE
            case $VALIDATOR_CHOICE in
                1) VALIDATOR_PUBKEY="6i65S85F6Yy1T2V8B3FjW2B5T4Y3V5S8S85F6Yy1T2V" ; VALIDATOR_NAME="Jito" ;;
                2) VALIDATOR_PUBKEY="8888888888888888888888888888888888888888" ; VALIDATOR_NAME="Marinade" ;;
                3) VALIDATOR_PUBKEY="EARNynHRWg6GfyJCmrriZeZzY8Y8gYmejN2m7mDUUtBD" ; VALIDATOR_NAME="Everstake" ;;
                4) VALIDATOR_PUBKEY="ey7Git54dtxJ42T9T8dvH1HE5cHT8cv3otSTFSGUucQ" ; VALIDATOR_NAME="Laine" ;;
                5) VALIDATOR_PUBKEY="SHNBi6Ug4VF3gWx3R3gPFiJhU4u5KqfWKEU5Zy9n2sC" ; VALIDATOR_NAME="Shinobi Systems" ;;
                6) VALIDATOR_PUBKEY="ChorusMMchKRt4sqYSwKfWRy2NUFPARh7WxKRcvCy9m" ; VALIDATOR_NAME="Chorus One" ;;
                7) read -p "Enter validator vote account pubkey: " VALIDATOR_PUBKEY ; VALIDATOR_NAME="Custom Validator" ;;
                *) echo "ERROR: Invalid choice" ; exit 1 ;;
            esac
        fi

        NONCE_VALUE=$(solana nonce "$NONCE_ACCOUNT" | head -1)
        TX_DATA="ACTION:DELEGATE_STAKE|NONCE:$NONCE_VALUE|NONCE_ACCOUNT:$NONCE_ACCOUNT|WALLET:$SELECTED_WALLET|STAKE_ACCOUNT:$STAKE_PUBKEY|VALIDATOR:$VALIDATOR_PUBKEY|VALIDATOR_NAME:$VALIDATOR_NAME|NETWORK:$SELECTED_NETWORK"

        echo ""
        echo "Transaction ready for $VALIDATOR_NAME ($VALIDATOR_PUBKEY)"
        if [ $TEST_MODE -eq 1 ]; then echo "$TX_DATA"; else echo "$TX_DATA" | qrencode -t UTF8; fi
        read -p "Press ENTER when ready to receive signed transaction..."
        if [ $TEST_MODE -eq 1 ]; then read -r SIGNED_TX; else SIGNED_TX=$(zbarcam --raw -q -1); fi
        SIGNER=$(echo "$SIGNED_TX" | cut -d'=' -f1)
        SIGNATURE=$(echo "$SIGNED_TX" | cut -d'=' -f2)
        echo "Broadcasting delegation..."
        solana delegate-stake --blockhash "$NONCE_VALUE" --nonce "$NONCE_ACCOUNT" --nonce-authority "$SELECTED_WALLET" --stake-authority "$SELECTED_WALLET" --fee-payer "$SELECTED_WALLET" --signer "$SIGNER=$SIGNATURE" "$STAKE_PUBKEY" "$VALIDATOR_PUBKEY"
        ;;
    2)
        echo "=== Deactivate Stake (Unstake) ==="
        NONCE_VALUE=$(solana nonce "$NONCE_ACCOUNT" | head -1)
        TX_DATA="ACTION:DEACTIVATE_STAKE|NONCE:$NONCE_VALUE|NONCE_ACCOUNT:$NONCE_ACCOUNT|WALLET:$SELECTED_WALLET|STAKE_ACCOUNT:$STAKE_PUBKEY|NETWORK:$SELECTED_NETWORK"
        if [ $TEST_MODE -eq 1 ]; then echo "$TX_DATA"; else echo "$TX_DATA" | qrencode -t UTF8; fi
        read -p "Press ENTER when ready to receive signed transaction..."
        if [ $TEST_MODE -eq 1 ]; then read -r SIGNED_TX; else SIGNED_TX=$(zbarcam --raw -q -1); fi
        SIGNER=$(echo "$SIGNED_TX" | cut -d'=' -f1)
        SIGNATURE=$(echo "$SIGNED_TX" | cut -d'=' -f2)
        solana deactivate-stake --blockhash "$NONCE_VALUE" --nonce "$NONCE_ACCOUNT" --nonce-authority "$SELECTED_WALLET" --stake-authority "$SELECTED_WALLET" --fee-payer "$SELECTED_WALLET" --signer "$SIGNER=$SIGNATURE" "$STAKE_PUBKEY"
        ;;
    3)
        echo "=== Withdraw Stake (To Cold Wallet) ==="
        NONCE_VALUE=$(solana nonce "$NONCE_ACCOUNT" | head -1)
        TX_DATA="ACTION:WITHDRAW_STAKE|NONCE:$NONCE_VALUE|NONCE_ACCOUNT:$NONCE_ACCOUNT|WALLET:$SELECTED_WALLET|STAKE_ACCOUNT:$STAKE_PUBKEY|AMOUNT:$STAKE_BALANCE|NETWORK:$SELECTED_NETWORK"
        if [ $TEST_MODE -eq 1 ]; then echo "$TX_DATA"; else echo "$TX_DATA" | qrencode -t UTF8; fi
        read -p "Press ENTER when ready to receive signed transaction..."
        if [ $TEST_MODE -eq 1 ]; then read -r SIGNED_TX; else SIGNED_TX=$(zbarcam --raw -q -1); fi
        SIGNER=$(echo "$SIGNED_TX" | cut -d'=' -f1)
        SIGNATURE=$(echo "$SIGNED_TX" | cut -d'=' -f2)
        solana withdraw-stake --blockhash "$NONCE_VALUE" --nonce "$NONCE_ACCOUNT" --nonce-authority "$SELECTED_WALLET" --withdraw-authority "$SELECTED_WALLET" --fee-payer "$SELECTED_WALLET" --signer "$SIGNER=$SIGNATURE" "$STAKE_PUBKEY" "$SELECTED_WALLET" "$STAKE_BALANCE"
        ;;
    4)
        echo "=== Detailed Status ==="
        solana stake-account "$STAKE_PUBKEY"
        echo ""
        echo "Inflation Rewards (last 5 epochs):"
        solana stake-history --limit 5
        ;;


    5)
        echo "=== Merge Stake Accounts ==="
        echo "Hinweis: Beide müssen ACTIVE sein und beim selben Validator liegen."
        read -p "Enter Pubkey of the account to be ABSORBED (Source): " SOURCE_STAKE
        NONCE_VALUE=$(solana nonce "$NONCE_ACCOUNT" | head -1)
        TX_DATA="ACTION:MERGE_STAKE|NONCE:$NONCE_VALUE|NONCE_ACCOUNT:$NONCE_ACCOUNT|WALLET:$SELECTED_WALLET|STAKE_ACCOUNT:$STAKE_PUBKEY|SOURCE_STAKE:$SOURCE_STAKE|NETWORK:$SELECTED_NETWORK"

        if [ $TEST_MODE -eq 1 ]; then echo "$TX_DATA"; else echo "$TX_DATA" | qrencode -t UTF8; fi
        read -p "Press ENTER when ready to receive signed transaction..."
        if [ $TEST_MODE -eq 1 ]; then read -r SIGNED_TX; else SIGNED_TX=$(zbarcam --raw -q -1); fi

        SIGNER=$(echo "$SIGNED_TX" | cut -d'=' -f1)
        SIGNATURE=$(echo "$SIGNED_TX" | cut -d'=' -f2)
        solana merge-stake --blockhash "$NONCE_VALUE" --nonce "$NONCE_ACCOUNT" --nonce-authority "$SELECTED_WALLET" --stake-authority "$SELECTED_WALLET" --fee-payer "$SELECTED_WALLET" --signer "$SIGNER=$SIGNATURE" "$STAKE_PUBKEY" "$SOURCE_STAKE"
        ;;
    6)
        echo "=== Split Stake Account ==="
        read -p "Amount to split OFF (SOL): " SPLIT_AMOUNT
        read -p "Enter Pubkey of the NEW (empty) stake account: " NEW_STAKE_PUBKEY
        NONCE_VALUE=$(solana nonce "$NONCE_ACCOUNT" | head -1)
        TX_DATA="ACTION:SPLIT_STAKE|NONCE:$NONCE_VALUE|NONCE_ACCOUNT:$NONCE_ACCOUNT|WALLET:$SELECTED_WALLET|STAKE_ACCOUNT:$STAKE_PUBKEY|NEW_STAKE:$NEW_STAKE_PUBKEY|AMOUNT:$SPLIT_AMOUNT|NETWORK:$SELECTED_NETWORK"

        if [ $TEST_MODE -eq 1 ]; then echo "$TX_DATA"; else echo "$TX_DATA" | qrencode -t UTF8; fi
        read -p "Press ENTER when ready to receive signed transaction..."
        if [ $TEST_MODE -eq 1 ]; then read -r SIGNED_TX; else SIGNED_TX=$(zbarcam --raw -q -1); fi

        SIGNER=$(echo "$SIGNED_TX" | cut -d'=' -f1)
        SIGNATURE=$(echo "$SIGNED_TX" | cut -d'=' -f2)
        solana split-stake --blockhash "$NONCE_VALUE" --nonce "$NONCE_ACCOUNT" --nonce-authority "$SELECTED_WALLET" --stake-authority "$SELECTED_WALLET" --fee-payer "$SELECTED_WALLET" --signer "$SIGNER=$SIGNATURE" "$STAKE_PUBKEY" "$NEW_STAKE_PUBKEY" "$SPLIT_AMOUNT"
        ;;

        7)
        echo "Exiting..."
        exit 0
        ;;
    *)
        echo "Invalid operation."
        ;;
esac

echo ""
echo "Done."
