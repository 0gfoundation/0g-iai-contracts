#!/usr/bin/env bash
# Verifies every deployed contract on the 0G explorer. Reads the addresses from the
# deployment record, so it verifies what was actually deployed rather than a hand-kept list.
set -euo pipefail
cd "$(dirname "$0")"

source ./config.sh
set -a; source .env; set +a

case "$CHAIN_ID" in
  16661) VERIFIER_URL="https://chainscan.0g.ai/open/api" ;;
  16602) VERIFIER_URL="https://chainscan-galileo.0g.ai/open/api" ;;
  *) echo "no explorer for chain $CHAIN_ID"; exit 1 ;;
esac

JSON="deployments/iai-${CHAIN_ID}.json"
[ -f "$JSON" ] || { echo "missing $JSON"; exit 1; }

addr() { jq -r --arg k "$1" '.[$k] // empty' "$JSON"; }

verify() {
  local address; address=$(addr "$1")
  if [ -z "$address" ] || [ "$address" = "0x0000000000000000000000000000000000000000" ]; then
    echo "skip $1 (not deployed)"; return
  fi
  echo "verifying $1 ($address) as $2"
  forge verify-contract "$address" "$2" \
    --verifier custom --verifier-api-key "${VERIFIER_KEY:-00}" \
    --verifier-url "$VERIFIER_URL" --chain "$CHAIN_ID" || echo "  ... failed, continuing"
}

# Every proxy verifies as BeaconProxy; the readable source lives on the implementation.
verify IAI                  BeaconProxy
verify IAIBeacon            UpgradeableBeacon
verify IAIImpl              IAI
verify IAIVault             BeaconProxy
verify IAIVaultBeacon       UpgradeableBeacon
verify IAIVaultImpl         IAIVault
verify CreditRegistry       BeaconProxy
verify CreditRegistryBeacon UpgradeableBeacon
verify CreditRegistryImpl   CreditRegistry

if [ "$CHAIN_ID" != "16661" ]; then
  verify MockA0G       MockA0G
  verify MockA0GOracle MockA0GOracle
fi
