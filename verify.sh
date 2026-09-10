#!/usr/bin/env bash
# Verifies every deployed contract on the 0G explorer. Reads the addresses from the
# deployment record, so it verifies what was actually deployed rather than a hand-kept list.
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

# The curve takes constructor arguments, so they have to be supplied to verify it. They are read
# back off the deployed contract rather than out of the deployment record, because the record
# describes the curve the parameters would build *now* while this verifies the one that is
# actually deployed -- and after a parameter edit those are different curves. Reading the chain
# cannot drift from the bytecode being verified.
verify_curve() {
  local address; address=$(addr MintCurve)
  local kind; kind=$(addr MintCurveKind)
  if [ -z "$address" ] || [ "$address" = "0x0000000000000000000000000000000000000000" ]; then
    echo "skip MintCurve (not deployed)"; return
  fi
  [ -n "$kind" ] || { echo "skip MintCurve (no MintCurveKind recorded)"; return; }

  local args
  case "$kind" in
    LinearMintCurve)
      local r0 anchor target
      r0=$(cast call "$address" "r0()(uint256)" --rpc-url "$RPC" | awk "{print \$1}")
      anchor=$(cast call "$address" "anchorCap()(uint256)" --rpc-url "$RPC" | awk "{print \$1}")
      target=$(cast call "$address" "target()(uint256)" --rpc-url "$RPC" | awk "{print \$1}")
      args=$(cast abi-encode "constructor(uint256,uint256,uint256)" "$r0" "$anchor" "$target")
      ;;
    ExponentialMintCurve)
      # Everything off the chain, the table included: the record's table may already describe
      # the *next* curve (after `genCurve` + `deployCurve`, before `setCurve`) while `MintCurve`
      # still names the one in service. `cast call` annotates large numbers for humans
      # (`123 [1.23e2]`); the annotations are stripped before re-encoding.
      local width base exponent target prices
      width=$(cast call "$address" "bucketWidth()(uint256)" --rpc-url "$RPC" | awk "{print \$1}")
      base=$(cast call "$address" "base()(uint256)" --rpc-url "$RPC" | awk "{print \$1}")
      exponent=$(cast call "$address" "exponent()(uint256)" --rpc-url "$RPC" | awk "{print \$1}")
      target=$(cast call "$address" "target()(uint256)" --rpc-url "$RPC" | awk "{print \$1}")
      prices=$(cast call "$address" "prices()(uint128[])" --rpc-url "$RPC" | sed -E 's/ \[[^]]*\]//g')
      args=$(cast abi-encode "constructor(uint256,uint128[],uint256,uint256,uint256)" \
        "$width" "$prices" "$base" "$exponent" "$target")
      ;;
    *) echo "skip MintCurve (unknown kind $kind)"; return ;;
  esac

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

# The mocks take constructor arguments too, and never had them supplied -- so their
# verification has been quietly falling into the "failed, continuing" branch. Same approach as
# the curve: read the values back off the deployed contracts, which cannot drift from the
# bytecode being verified the way the record can.
verify_mocks() {
  local a0g asset oracle
  a0g=$(addr MockA0G)
  if [ -z "$a0g" ] || [ "$a0g" = "0x0000000000000000000000000000000000000000" ]; then
    echo "skip MockA0G (not deployed)"; return
  fi

  asset=$(cast call "$a0g" "asset()(address)" --rpc-url "$RPC")
  oracle=$(cast call "$a0g" "oracle()(address)" --rpc-url "$RPC")
  verify MockA0G MockA0G \
    --constructor-args "$(cast abi-encode "constructor(address,address)" "$asset" "$oracle")"

  # `baseValue` is what the constructor was given only while nobody has moved the rate --
  # `setValue` and `setApr` both re-anchor it. If this one fails, that is the first thing
  # to check.
  local base apr maxAge owner
  base=$(cast call "$oracle" "baseValue()(uint256)" --rpc-url "$RPC" | awk "{print \$1}")
  apr=$(cast call "$oracle" "apr()(uint256)" --rpc-url "$RPC" | awk "{print \$1}")
  maxAge=$(cast call "$oracle" "maxAge()(uint256)" --rpc-url "$RPC" | awk "{print \$1}")
  owner=$(cast call "$oracle" "owner()(address)" --rpc-url "$RPC")
  verify MockA0GOracle MockA0GOracle \
    --constructor-args "$(cast abi-encode "constructor(uint256,uint256,uint256,address)" \
      "$base" "$apr" "$maxAge" "$owner")"

  # The underlying is only ours to verify when we deployed it. On a network that already had
  # the real W0G the record names that instead, and it is somebody else's contract. Decide by
  # comparing the deployed code with our own build rather than by matching an address.
  local onchain ours
  onchain=$(cast code "$asset" --rpc-url "$RPC")
  ours=$(jq -r '.deployedBytecode.object' out/MockW0G.sol/MockW0G.json)
  if [ "$onchain" = "$ours" ]; then
    verify W0G MockW0G
  else
    echo "skip W0G ($asset is not our MockW0G)"
  fi
}

if [ "$CHAIN_ID" != "16661" ]; then
  verify_mocks
fi
