#!/usr/bin/env bash
# Source this file:  source ./aliases_$1.sh
# Routes Solana CLI commands to $1 exec

alias solana="$1 exec -it solana-cli solana"
alias solana-keygen="$1 exec -it solana-cli solana-keygen"
alias solana-test-validator="$1 exec -it solana-cli solana-test-validator"
alias solana-faucet="$1 exec -it solana-cli solana-faucet"
alias solana-install="$1 exec -it solana-cli solana-install"
alias solana-ledger-tool="$1 exec -it solana-cli solana-ledger-tool"
alias solana-log-analyzer="$1 exec -it solana-cli solana-log-analyzer"
alias solana-net-shaper="$1 exec -it solana-cli solana-net-shaper"
alias solana-stake="$1 exec -it solana-cli solana-stake"
alias solana-validator="$1 exec -it solana-cli solana-validator"
alias solana-watchtower="$1 exec -it solana-cli solana-watchtower"
alias spl-token="$1 exec -it solana-cli spl-token"
alias spl-token-cli="$1 exec -it solana-cli spl-token-cli"
