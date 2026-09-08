// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IIAI
 * @notice The iAI token: a plain, freely transferable ERC-20 whose issuance is controlled
 *         entirely by the vault. It has no supply ceiling of its own -- the cap lives in the
 *         vault, where it is adjustable, rather than being fixed here.
 */
interface IIAI is IERC20 {
    /// @notice Role held only by the vault; there is no other issuance path.
    function MINTER_BURNER_ROLE() external view returns (bytes32);

    /**
     * @notice Issues new iAI. `MINTER_BURNER_ROLE`.
     * @param to     Recipient of the newly minted tokens.
     * @param amount Amount to mint, in wei-iAI. The supply ceiling is enforced by the vault, not here.
     */
    function mint(address to, uint256 amount) external;

    /**
     * @notice Destroys iAI. `MINTER_BURNER_ROLE`.
     * @param from   Holder whose balance is reduced. Needs no allowance: the role, not an
     *               approval, is what authorises this.
     * @param amount Amount to burn, in wei-iAI.
     */
    function burn(address from, uint256 amount) external;
}
