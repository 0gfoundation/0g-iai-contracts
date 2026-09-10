#!/usr/bin/env bash
# Deploys the iAI system. Parameters come from deployments/iai-$CHAIN_ID.json, and the
# addresses are written back to the same file.
#
#   ./run.sh              deploy (mock collateral first, on any chain but mainnet)
#   ./run.sh accounts     derive and fund the testnet account set
#   ./run.sh status       read the live deployment
#   ./run.sh check        re-check the recorded addresses against the chain
#   ./run.sh unpause      open issuance
#   ./run.sh pause        close issuance
#   ./run.sh harvest      sweep accrued yield to the foundation
#   ./run.sh redeployMock  replace the mock collateral -- ABANDONS every balance on the
#                          old token; only for when the mock itself must change shape
#   ./run.sh genCurve [flags]     (re)generate the ExponentialMintCurve price table into the
#                                 record from its parameters (see script/curve/gen_exponential_table.py)
#   ./run.sh deployCurve <Kind>   deploy a curve and record it under its kind name
#   ./run.sh setCurve <Kind>      point the vault at a previously deployed curve
#   ./run.sh setCap <amount>      move the supply ceiling (wei-iAI; below the live supply
#                                 closes issuance and leaves redemption open)
#
# IAI_CONFIG and IAI_ENV override which config.sh and .env are sourced (see below).
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

# Honour DEPLOYMENT_PATH the same way the scripts do, or this guard checks a different file
# from the one they will actually read.
CONFIG="${DEPLOYMENT_PATH:-deployments}/iai-${CHAIN_ID}.json"
[ -f "$CONFIG" ] || { echo "missing $CONFIG -- copy deployments/iai-example.json and fill it in"; exit 1; }

send() { forge script "$1" --rpc-url "$RPC" --broadcast $GAS_FLAGS "${@:2}"; }
read_only() { forge script "$1" --rpc-url "$RPC" "${@:2}"; }

# The exponential curve's table is derived from the parameters beside it, never hand-edited.
# Re-derive and compare before anything reads it, so a stale table cannot be deployed or pass
# a check. A record without the block passes unless the block is required: because the kind
# in force is the exponential one, or because it is about to be deployed (--require).
check_table() { python3 script/curve/gen_exponential_table.py "$CONFIG" --check "$@"; }

case "${1:-deploy}" in
  deploy)
    check_table
    # Mock collateral exists only off mainnet; the script refuses to run there, so skip it
    # rather than let a non-zero exit stop the deployment.
    if [ "$CHAIN_ID" != "16661" ]; then
      send script/deploy/Mock.s.sol
    fi
    send script/deploy/IAI.s.sol
    # The record is written during simulation, so an interrupted run leaves a file naming
    # contracts that were never deployed. Check it before anyone builds on it.
    read_only script/deploy/IAI.s.sol --sig "checkDeployment()"
    echo
    echo "Deployed and PAUSED. Review 'run.sh status', then 'run.sh unpause' to open issuance."
    echo "DEFAULT_ADMIN, PAUSER and beacon ownership are all on the deployer -- hand them to"
    echo "the multisig before launch."
    ;;
  accounts) send script/deploy/Accounts.s.sol ;;
  redeployMock)
    # Deliberately not part of `deploy`: it walks past the guard that stops a rerun from
    # orphaning every balance on the existing mock.
    send script/deploy/Mock.s.sol --sig "redeploy()"
    ;;
  status)   read_only script/deploy/IAI.s.sol --sig "status()" ;;
  check)
    check_table
    read_only script/deploy/IAI.s.sol --sig "checkDeployment()"
    ;;
  genCurve)
    python3 script/curve/gen_exponential_table.py "$CONFIG" "${@:2}"
    echo "Regenerated. The chain still has the old table: 'run.sh deployCurve ExponentialMintCurve'"
    echo "then 'run.sh setCurve ExponentialMintCurve' puts the new one in service. The vault's cap"
    echo "must fit under the table in force: a taller table is deployCurve, setCurve, then setCap;"
    echo "a table whose top is below the current cap needs setCap (to at most the new top) first."
    ;;
  unpause)  send script/deploy/IAI.s.sol --sig "unpause()" ;;
  pause)    send script/deploy/IAI.s.sol --sig "pause()" ;;
  harvest)  send script/deploy/IAI.s.sol --sig "harvest()" ;;
  deployCurve)
    [ $# -eq 2 ] || { echo "usage: ./run.sh deployCurve <Kind>   e.g. ExponentialMintCurve"; exit 1; }
    # Only the exponential kind reads the table; a stale block must not block a linear deploy.
    if [ "$2" = ExponentialMintCurve ]; then check_table --require; fi
    send script/deploy/IAI.s.sol --sig "deployCurve(string)" "$2"
    ;;
  setCurve)
    [ $# -eq 2 ] || { echo "usage: ./run.sh setCurve <Kind>   e.g. ExponentialMintCurve"; exit 1; }
    send script/deploy/IAI.s.sol --sig "setCurve(string)" "$2"
    read_only script/deploy/IAI.s.sol --sig "checkDeployment()"
    ;;
  setCap)
    [ $# -eq 2 ] || { echo "usage: ./run.sh setCap <amount in wei-iAI>"; exit 1; }
    send script/deploy/IAI.s.sol --sig "setCap(uint256)" "$2"
    ;;
  *) echo "unknown command: $1"; sed -n '2,19p' "$0"; exit 1 ;;
esac
