#!/usr/bin/env bash
# Beacon upgrades, and the fork rehearsal that must pass before any of them go to a live
# chain. Each contract has its own beacon, so one upgrade cannot reach the others.
#
#   ./upgrade.sh rehearse vault     fork the chain, upgrade there, compare state (safe)
#   ./upgrade.sh vault              upgrade for real
#   ./upgrade.sh iai | registry
#
# CHECK_ACCOUNTS=0xabc,0xdef adds real positions to the comparison. On a fork of a live
# deployment, pass the largest holders.
set -euo pipefail
cd "$(dirname "$0")"

source ./config.sh
set -a; source .env; set +a

target_sig() {
  case "$1" in
    vault)    echo "upgradeVault()" ;;
    iai)      echo "upgradeIAI()" ;;
    registry) echo "upgradeRegistry()" ;;
    *) echo "unknown target: $1 (vault|iai|registry)" >&2; exit 1 ;;
  esac
}

contract_name() {
  case "$1" in
    vault) echo "IAIVault" ;; iai) echo "IAI" ;; registry) echo "CreditRegistry" ;;
  esac
}

if [ "${1:-}" = "rehearse" ]; then
  TARGET="${2:?which contract? vault|iai|registry}"
  SIG=$(target_sig "$TARGET")
  NAME=$(contract_name "$TARGET")
  FORK_RPC="http://127.0.0.1:8545"

  # The layout diff needs the *current* on-chain build, so capture it before recompiling.
  forge inspect "$NAME" storageLayout > /tmp/iai-layout-before.json

  echo "Forking $RPC as chain $CHAIN_ID ..."
  anvil --fork-url "$RPC" --chain-id "$CHAIN_ID" --silent &
  ANVIL_PID=$!
  trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
  until cast block-number --rpc-url "$FORK_RPC" >/dev/null 2>&1; do sleep 1; done

  forge script script/Upgrade.s.sol --sig "snapshot()"         --rpc-url "$FORK_RPC"
  forge script script/Upgrade.s.sol --sig "$SIG"               --rpc-url "$FORK_RPC" --broadcast
  forge script script/Upgrade.s.sol --sig "postUpgradeCheck()" --rpc-url "$FORK_RPC"

  # The snapshot the fork wrote is not the live chain's; drop it so a later real upgrade
  # cannot compare against it by accident.
  rm -f "deployments/upgrade-snapshot-${CHAIN_ID}.json"

  forge inspect "$NAME" storageLayout > /tmp/iai-layout-after.json
  echo
  echo "--- storage layout diff ($NAME) ---"
  diff /tmp/iai-layout-before.json /tmp/iai-layout-after.json && echo "(identical)"
  echo
  echo "Rehearsal PASSED. Re-run without 'rehearse' to upgrade $CHAIN_ID for real."
  exit 0
fi

TARGET="${1:?which contract? vault|iai|registry (or: rehearse <target>)}"
SIG=$(target_sig "$TARGET")

forge script script/Upgrade.s.sol --sig "snapshot()" --rpc-url "$RPC"
forge script script/Upgrade.s.sol --sig "$SIG" --rpc-url "$RPC" --broadcast $GAS_FLAGS
forge script script/Upgrade.s.sol --sig "postUpgradeCheck()" --rpc-url "$RPC"
