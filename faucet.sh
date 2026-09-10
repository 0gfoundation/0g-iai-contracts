#!/usr/bin/env bash
# Mints mock a0G on a test network. The mock's faucet is deliberately open, so this works
# from any funded key, not only the deployer's.
#
#   ./faucet.sh 0xRecipient            1,000,000 a0G
#   ./faucet.sh 0xRecipient 5000       5,000 a0G
set -euo pipefail
cd "$(dirname "$0")"

source ./config.sh
set -a; source .env; set +a

[ "$CHAIN_ID" = "16661" ] && { echo "there is no faucet on mainnet"; exit 1; }

TO="${1:?recipient address}"
AMOUNT="${2:-1000000}"

CONFIG="${DEPLOYMENT_PATH:-deployments}/iai-${CHAIN_ID}.json"
A0G=$(jq -r '.MockA0G // empty' "$CONFIG" 2>/dev/null)
[ -n "$A0G" ] || { echo "no MockA0G in $CONFIG -- run ./run.sh first"; exit 1; }

cast send "$A0G" "faucetMint(address,uint256)" "$TO" "$(cast to-wei "$AMOUNT")" \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" ${CAST_GAS_FLAGS:-}

echo "balance: $(cast to-unit "$(cast call "$A0G" 'balanceOf(address)(uint256)' "$TO" --rpc-url "$RPC" | awk '{print $1}')" ether) a0G"
