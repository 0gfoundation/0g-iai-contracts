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
# IAI_CONFIG / IAI_ENV point the script at another config.sh and .env -- how a rehearsal against a
# local anvil runs from a scratch directory. Resolved to absolute paths *before* the cd below;
# resolved after it, a relative path would be looked up inside the repository, and one that
# happened to be named config.sh or .env would silently source the real files, real key included.
_abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
if [ -n "${IAI_CONFIG:-}" ]; then IAI_CONFIG=$(_abs "$IAI_CONFIG"); fi
if [ -n "${IAI_ENV:-}" ]; then IAI_ENV=$(_abs "$IAI_ENV"); fi
cd "$(dirname "$0")"

source "${IAI_CONFIG:-./config.sh}"
set -a; source "${IAI_ENV:-.env}"; set +a

# Tests run under the default profile, where `deployments/` is read-only so a stray test
# cannot overwrite a deployment record. Writing those records is this script's job.
export FOUNDRY_PROFILE=deploy

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

  # The rehearsal calls the same entry point a real upgrade does, and that entry point records
  # the implementation address it just deployed. On a fork that address exists nowhere else,
  # so letting it write the real record would replace a live implementation with one that has
  # no code -- silently, until `./run.sh check` refused to pass. Point the whole rehearsal at
  # a throwaway copy of the record instead; the snapshot lands there too, so nothing the fork
  # produces can outlive it.
  REHEARSAL_DIR="cache/upgrade-rehearsal-${CHAIN_ID}"
  rm -rf "$REHEARSAL_DIR"; mkdir -p "$REHEARSAL_DIR"
  cp "${DEPLOYMENT_PATH:-deployments}/iai-${CHAIN_ID}.json" "$REHEARSAL_DIR/"
  export DEPLOYMENT_PATH="$REHEARSAL_DIR"

  echo "Forking $RPC as chain $CHAIN_ID ..."
  anvil --fork-url "$RPC" --chain-id "$CHAIN_ID" --silent &
  ANVIL_PID=$!
  trap 'kill $ANVIL_PID 2>/dev/null || true; rm -rf "$REHEARSAL_DIR"' EXIT
  until cast block-number --rpc-url "$FORK_RPC" >/dev/null 2>&1; do sleep 1; done

  forge script script/Upgrade.s.sol --sig "snapshot()"         --rpc-url "$FORK_RPC"
  forge script script/Upgrade.s.sol --sig "$SIG"               --rpc-url "$FORK_RPC" --broadcast
  forge script script/Upgrade.s.sol --sig "postUpgradeCheck()" --rpc-url "$FORK_RPC"

  # No storage-layout diff here, on purpose. Every contract keeps its state in an ERC-7201
  # struct reached by assembly, so `forge inspect <C> storageLayout` reports zero state
  # variables and prints an empty table -- its diff read "(identical)" across any change at
  # all, including a full rewrite of the struct, which is the one thing it looked like it was
  # guarding. It also compiled the same working tree on both sides. What this rehearsal
  # establishes is the state comparison above; for layout, read the diff of the struct itself.
  echo
  echo "Rehearsal PASSED: state compared before and after on a fork of $CHAIN_ID. This says"
  echo "nothing about storage layout -- diff the namespaced struct by hand for that."
  echo "Re-run without 'rehearse' to upgrade $CHAIN_ID for real."
  exit 0
fi

TARGET="${1:?which contract? vault|iai|registry (or: rehearse <target>)}"
SIG=$(target_sig "$TARGET")

forge script script/Upgrade.s.sol --sig "snapshot()" --rpc-url "$RPC"
forge script script/Upgrade.s.sol --sig "$SIG" --rpc-url "$RPC" --broadcast $GAS_FLAGS
forge script script/Upgrade.s.sol --sig "postUpgradeCheck()" --rpc-url "$RPC"
