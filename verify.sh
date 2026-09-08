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

JSON="${DEPLOYMENT_PATH:-deployments}/iai-${CHAIN_ID}.json"
[ -f "$JSON" ] || { echo "missing $JSON"; exit 1; }

addr() { jq -r --arg k "$1" '.[$k] // empty' "$JSON"; }

# verify <json key> <contract name> [extra forge args...]
verify() {
  local address; address=$(addr "$1")
  if [ -z "$address" ] || [ "$address" = "0x0000000000000000000000000000000000000000" ]; then
    echo "skip $1 (not deployed)"; return
  fi
  local key="$1" name="$2"; shift 2
  echo "verifying $key ($address) as $name"
  forge verify-contract "$address" "$name" \
    --verifier custom --verifier-api-key "${VERIFIER_KEY:-00}" \
    --verifier-url "$VERIFIER_URL" --chain "$CHAIN_ID" "$@" || echo "  ... failed, continuing"
}

# The curve takes constructor arguments, so they have to be supplied to verify it. They are
# read back off the deployed contract rather than out of the deployment record: `Cap` in the
# record is the vault's cap, which is adjustable and drifts away from the `anchorCap` the curve
# was actually constructed with. Reading the chain cannot drift.
verify_curve() {
  local address; address=$(addr MintCurve)
  local kind; kind=$(addr MintCurveKind)
  if [ -z "$address" ] || [ "$address" = "0x0000000000000000000000000000000000000000" ]; then
    echo "skip MintCurve (not deployed)"; return
  fi
  [ -n "$kind" ] || { echo "skip MintCurve (no MintCurveKind recorded)"; return; }

  local r0 anchor target args
  r0=$(cast call "$address" "r0()(uint256)" --rpc-url "$RPC" | awk "{print \$1}")
  anchor=$(cast call "$address" "anchorCap()(uint256)" --rpc-url "$RPC" | awk "{print \$1}")
  target=$(cast call "$address" "target()(uint256)" --rpc-url "$RPC" | awk "{print \$1}")
  args=$(cast abi-encode "constructor(uint256,uint256,uint256)" "$r0" "$anchor" "$target")

  verify MintCurve "$kind" --constructor-args "$args"
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
verify_curve

if [ "$CHAIN_ID" != "16661" ]; then
  verify MockA0G       MockA0G
  verify MockA0GOracle MockA0GOracle
fi
