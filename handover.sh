#!/usr/bin/env bash
# Moves governance off the deploying account, in two deliberate transactions.
#
#   ./handover.sh status     who holds what right now (read-only, run it between the steps)
#   ./handover.sh grant      put every role and beacon on its target; deployer keeps its own
#   ./handover.sh renounce   stand the deployer down; refuses unless grant is fully in place
#
# Targets come from deployments/iai-$CHAIN_ID.json: Admin, Guardian, Rescuer, BeaconOwner.
# They ship as zero addresses and have to be filled in by hand.
#
# Do not run `renounce` in the same sitting as `grant`. Between them, confirm the targets
# actually respond -- execute something from the Safe. Beacon ownership is one-step, and the
# admin role is the only thing that can hand it back.
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

export FOUNDRY_PROFILE=deploy

case "${1:-status}" in
  status)   forge script script/Handover.s.sol --sig "status()" --rpc-url "$RPC" ;;
  grant)    forge script script/Handover.s.sol --sig "grant()" --rpc-url "$RPC" --broadcast $GAS_FLAGS ;;
  renounce)
    echo "This gives up the deployer's keys. It cannot be undone."
    echo "Run './handover.sh status' first and confirm the targets respond."
    read -p "Type the chain id ($CHAIN_ID) to continue: " confirm
    [ "$confirm" = "$CHAIN_ID" ] || { echo "aborted"; exit 1; }
    forge script script/Handover.s.sol --sig "renounce()" --rpc-url "$RPC" --broadcast $GAS_FLAGS
    ;;
  *) echo "unknown command: $1"; sed -n '2,10p' "$0"; exit 1 ;;
esac
