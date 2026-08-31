// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/**
 * @title IA0GOracle
 * @notice Minimal view of the a0G exchange-rate oracle (Mellow `Oracle`).
 *
 * @dev Hand-written rather than imported: the upstream interface pins an exact compiler
 *      version and transitively drags in LayerZero and OpenZeppelin-upgradeable trees,
 *      none of which this project needs to read a single number.
 *
 *      Operational facts that matter to every consumer:
 *      - `getValue()` **reverts** once `lastUpdated + maxAge < block.timestamp`. On 0G
 *        mainnet `maxAge` is 21 days and the value is written by an external EOA roughly
 *        every 8 hours. That keeper is not under this project's control.
 *      - `setValue` has no bounds, no rate limit, no monotonicity constraint and no
 *        timelock, and its role is checked against the vault contract's AccessControl,
 *        not the oracle's. Treat the returned value as trusted-but-unverified input.
 */
interface IA0GOracle {
    /// @notice Exchange rate scaled by 1e18: how much 0G one a0G is worth.
    /// @dev Reverts with "Oracle: stale value" past `lastUpdated + maxAge`.
    function getValue() external view returns (uint256);

    /// @notice Same number as `getValue` but without the staleness check.
    function value() external view returns (uint256);

    /// @notice Timestamp of the most recent write.
    function lastUpdated() external view returns (uint256);

    /// @notice Seconds after `lastUpdated` at which `getValue` starts reverting.
    function maxAge() external view returns (uint256);
}
