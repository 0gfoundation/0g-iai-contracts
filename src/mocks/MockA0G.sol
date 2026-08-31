// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IA0G} from "../interfaces/external/IA0G.sol";
import {IA0GOracle} from "../interfaces/external/IA0GOracle.sol";

/**
 * @title MockA0G
 * @notice Stand-in for a0G on networks where the real one is not deployed or not useful.
 *
 * @dev Only reproduces the surface iAI actually depends on: ERC-20 plus `oracle()`. The
 *      ERC-4626 side of the real token is deliberately absent — its redemption functions
 *      revert upstream anyway, so mimicking them would only invite reliance on them.
 *
 *      Minting is unrestricted: on a testnet this doubles as the faucet.
 */
contract MockA0G is IA0G, ERC20 {
    IA0GOracle private immutable _oracle;

    constructor(address oracle_) ERC20("Mock Ascend Staked 0G", "a0G") {
        _oracle = IA0GOracle(oracle_);
    }

    /// @inheritdoc IA0G
    function oracle() external view returns (IA0GOracle) {
        return _oracle;
    }

    /// @notice Open faucet.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Funds many addresses in one transaction, for seeding test accounts.
    function batchMint(address[] calldata recipients, uint256 amount) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            _mint(recipients[i], amount);
        }
    }
}
