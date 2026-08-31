// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/**
 * @title Constants
 * @notice Chain identities. Everything that can reasonably be a parameter lives in the
 *         deployment JSON instead; only facts about the chain itself belong here.
 */
contract Constants {
    uint256 internal constant OG_MAINNET = 16_661;
    uint256 internal constant OG_GALILEO = 16_602;
    uint256 internal constant OG_DEVNET = 16_601;
    uint256 internal constant ANVIL = 31_337;

    /// @notice Whether this chain should get mock collateral rather than the live a0G.
    function usesMockCollateral() internal view returns (bool) {
        return block.chainid != OG_MAINNET;
    }

    function networkName() internal view returns (string memory) {
        if (block.chainid == OG_MAINNET) return "0G mainnet";
        if (block.chainid == OG_GALILEO) return "0G Galileo testnet";
        if (block.chainid == OG_DEVNET) return "0G devnet";
        if (block.chainid == ANVIL) return "anvil";
        return "unknown";
    }
}
