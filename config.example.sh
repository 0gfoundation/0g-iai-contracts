#!/usr/bin/env bash
# Copy to config.sh and edit. config.sh is gitignored: each developer keeps their own
# endpoints, and nothing here should ever reach the repository.

# The chain every script in this directory talks to. Everything else follows from it:
# which deployments/iai-<chainid>.json is read, and which explorer verifies contracts.
export CHAIN_ID=16602

case "$CHAIN_ID" in
  16661) export RPC="https://evmrpc.0g.ai" ;;          # 0G mainnet
  16602) export RPC="https://evmrpc-testnet.0g.ai" ;;  # 0G Galileo testnet
  31337) export RPC="http://127.0.0.1:8545" ;;         # anvil
  *)     export RPC="http://127.0.0.1:8545" ;;
esac

# 0G's EIP-1559 needs both prices pinned, and --slow makes each transaction wait for its
# receipt so a nonce gap cannot strand the rest of a deployment.
# `--timeout` is how long forge waits for each receipt. The default is short enough that the
# public 0G RPCs occasionally miss one, which aborts a run midway -- harmlessly, since --slow
# means nothing later was sent, but it leaves the deployment file naming a contract that was
# never deployed (the file is written during simulation, before broadcasting).
export GAS_FLAGS="--slow --timeout 300 --with-gas-price 3gwei --priority-gas-price 3gwei"

# `cast` spells the same thing differently and has no --slow (it sends one transaction).
export CAST_GAS_FLAGS="--gas-price 3gwei --priority-gas-price 3gwei"
