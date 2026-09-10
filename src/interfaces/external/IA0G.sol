// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IA0GOracle} from "./IA0GOracle.sol";

/**
 * @title IA0G
 * @notice The slice of a0G (Mellow `SourceCore`) that iAI actually uses: plain ERC-20
 *         plus the address of its pricing oracle.
 *
 * @dev a0G is an ERC-4626 restaking vault share, not a consensus liquid-staking token,
 *      and it is upgradeable by a third party. Two consequences this project is built around:
 *
 *      - It is **freely transferable**, so collateral must be genuinely escrowed. The
 *        "flag the balance in place" trick used by non-transferable staking receipts
 *        is not available here.
 *      - It has **no `permit`** (`ERC4626Upgradeable` does not inherit `ERC20Permit`),
 *        so every deposit needs a separate `approve` transaction.
 *
 *      Deliberately omits the ERC-4626 surface, which iAI never calls. Note what that
 *      omission does *not* mean: a0G is redeemable. It reverts in `_withdraw`, so ERC-4626's
 *      `withdraw` and `redeem` do not work, but redemption goes through `requestWithdrawal`
 *      into an epoch-based queue instead. `maxWithdraw`/`maxRedeem` still return non-zero,
 *      describing an exit that is not the one a holder actually takes — which is the reason
 *      to leave the whole surface out rather than expose numbers that do not mean what they
 *      appear to.
 */
interface IA0G is IERC20 {
    /// @notice The oracle whose value prices a0G against 0G. Fixed at construction upstream.
    function oracle() external view returns (IA0GOracle);
}
