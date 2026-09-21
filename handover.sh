#!/usr/bin/env bash
# Moves governance off the deploying account, in two deliberate transactions.
#
#   ./handover.sh status     who holds what right now (read-only, run it between the steps)
#   ./handover.sh grant      put every role and beacon on its target; deployer keeps its own
#   ./handover.sh renounce   stand the deployer down; refuses unless grant is fully in place
#
#   ./handover.sh renounce --keep vault-pauser,registry-pauser
#                            ...but leave the named roles on the deployer. Any of
#                            iai-admin, vault-admin, registry-admin, vault-pauser and
#                            registry-pauser, comma-separated; anything else is an error,
#                            not a skipped word. `PAUSE_EXEMPT_MINTER_ROLE` is always given
#                            up and cannot be named.
#
# Targets come from deployments/iai-$CHAIN_ID.json: Admin, Guardian, BeaconOwner.
# They ship as zero addresses and have to be filled in by hand.
#
# Confirm the Safe responds -- execute something from it and watch it land -- *before* `grant`,
# and read `status` back between the two steps. `grant` is where the upgrade key stops being
# recoverable: beacon ownership is one-step `Ownable` with no acceptance step, and admin has no
# power over a beacon, so nothing hands it back. Do not run `renounce` in the same sitting.
set -euo pipefail
# IAI_CONFIG / IAI_ENV point the script at another config.sh and .env -- how a rehearsal against a
# local anvil runs from a scratch directory. Resolved to absolute paths *before* the cd below;
# resolved after it, a relative path would be looked up inside the repository, and one that
# happened to be named config.sh or .env would silently source the real files, real key included.
_abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
if [ -n "${IAI_CONFIG:-}" ]; then IAI_CONFIG=$(_abs "$IAI_CONFIG"); fi
if [ -n "${IAI_ENV:-}" ]; then IAI_ENV=$(_abs "$IAI_ENV"); fi
cd "$(dirname "$0")"

# The comment header, printed on a usage error. Read off the file rather than by line number,
# which went stale the first time the header grew and took the safety notice with it.
usage() { awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; }

source "${IAI_CONFIG:-./config.sh}"
set -a; source "${IAI_ENV:-.env}"; set +a

export FOUNDRY_PROFILE=deploy

case "${1:-status}" in
  status)   forge script script/Handover.s.sol --sig "status()" --rpc-url "$RPC" ;;
  grant)    forge script script/Handover.s.sol --sig "grant()" --rpc-url "$RPC" --broadcast $GAS_FLAGS ;;
  renounce)
    shift
    KEEP=""
    KEEP_GIVEN=""
    while [ $# -gt 0 ]; do
      case "$1" in
        # Spaces are stripped so that a quoted "a, b" is the same list as "a,b"; every other
        # difference is left to the script, which rejects a name it does not know.
        #
        # An empty list and a second --keep are both refused here rather than resolved. Every
        # way of misreading this flag has to fail loudly, and the two quiet readings -- "" as
        # "keep nothing" and a repeat as "the last one wins" -- are the destructive ones: each
        # gives up roles the operator wrote the flag to save. A full stand-down is available by
        # leaving --keep off, which nobody does by accident.
        --keep|--keep=*)
          [ -z "$KEEP_GIVEN" ] || { echo "--keep given twice; put every role in one list"; exit 1; }
          case "$1" in
            --keep=*) KEEP=${1#--keep=}; shift ;;
            *)        [ $# -ge 2 ] || { echo "--keep needs a comma-separated list"; exit 1; }
                      KEEP=$2; shift 2 ;;
          esac
          KEEP=$(printf '%s' "$KEEP" | tr -d '[:space:]')
          [ -n "$KEEP" ] || { echo "--keep needs a comma-separated list"; exit 1; }
          KEEP_GIVEN=1
          ;;
        *) echo "unknown option: $1"; usage; exit 1 ;;
      esac
    done

    echo "This gives up the deployer's keys. It cannot be undone."
    if [ -n "$KEEP" ]; then
      echo "Keeping on the deployer: $KEEP"
      echo "Giving up: every other role it holds, the paused-mint exemption included."
    else
      echo "Keeping on the deployer: nothing -- it stands down completely."
    fi
    echo "Run './handover.sh status' first and confirm the targets respond."
    read -p "Type the chain id ($CHAIN_ID) to continue: " confirm
    [ "$confirm" = "$CHAIN_ID" ] || { echo "aborted"; exit 1; }
    if [ -n "$KEEP" ]; then
      forge script script/Handover.s.sol --sig "renounce(string)" "$KEEP" \
        --rpc-url "$RPC" --broadcast $GAS_FLAGS
    else
      forge script script/Handover.s.sol --sig "renounce()" --rpc-url "$RPC" --broadcast $GAS_FLAGS
    fi
    ;;
  *) echo "unknown command: $1"; usage; exit 1 ;;
esac
