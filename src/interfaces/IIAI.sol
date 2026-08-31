// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IIAI
 * @notice The iAI token: a plain, freely transferable ERC-20 with a hard supply cap
 *         whose issuance is controlled entirely by the vault.
 */
interface IIAI is IERC20 {
    /// @notice A mint would push total supply past the immutable cap.
    error CapExceeded(uint256 attempted, uint256 cap);
    /// @notice Cap must be non-zero.
    error ZeroCap();

    /// @notice Hard supply ceiling, written once at initialization.
    function cap() external view returns (uint256);

    /// @notice Role held only by the vault; there is no other issuance path.
    function MINTER_BURNER_ROLE() external view returns (bytes32);

    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;
}
