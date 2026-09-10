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
#   ./run.sh deployCurve <Kind>   deploy a curve and record it under its kind name
#   ./run.sh setCurve <Kind>      point the vault at a previously deployed curve
#   ./run.sh setCap <amount>      move the supply ceiling (wei-iAI; below the live supply
#                                 closes issuance and leaves redemption open)
set -euo pipefail
cd "$(dirname "$0")"

source ./config.sh
set -a; source .env; set +a

# Tests run under the default profile, where `deployments/` is read-only so a stray test
# cannot overwrite a deployment record. Writing those records is this script's job.
export FOUNDRY_PROFILE=deploy

# Honour DEPLOYMENT_PATH the same way the scripts do, or this guard checks a different file
# from the one they will actually read.
CONFIG="${DEPLOYMENT_PATH:-deployments}/iai-${CHAIN_ID}.json"
[ -f "$CONFIG" ] || { echo "missing $CONFIG -- copy deployments/iai-example.json and fill it in"; exit 1; }

send() { forge script "$1" --rpc-url "$RPC" --broadcast $GAS_FLAGS "${@:2}"; }
read_only() { forge script "$1" --rpc-url "$RPC" "${@:2}"; }

case "${1:-deploy}" in
  deploy)
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
  check)    read_only script/deploy/IAI.s.sol --sig "checkDeployment()" ;;
  unpause)  send script/deploy/IAI.s.sol --sig "unpause()" ;;
  pause)    send script/deploy/IAI.s.sol --sig "pause()" ;;
  harvest)  send script/deploy/IAI.s.sol --sig "harvest()" ;;
  deployCurve)
    [ $# -eq 2 ] || { echo "usage: ./run.sh deployCurve <Kind>   e.g. LinearMintCurve"; exit 1; }
    send script/deploy/IAI.s.sol --sig "deployCurve(string)" "$2"
    ;;
  setCurve)
    [ $# -eq 2 ] || { echo "usage: ./run.sh setCurve <Kind>   e.g. LinearMintCurve"; exit 1; }
    send script/deploy/IAI.s.sol --sig "setCurve(string)" "$2"
    read_only script/deploy/IAI.s.sol --sig "checkDeployment()"
    ;;
  setCap)
    [ $# -eq 2 ] || { echo "usage: ./run.sh setCap <amount in wei-iAI>"; exit 1; }
    send script/deploy/IAI.s.sol --sig "setCap(uint256)" "$2"
    ;;
  *) echo "unknown command: $1"; sed -n '2,12p' "$0"; exit 1 ;;
esac
