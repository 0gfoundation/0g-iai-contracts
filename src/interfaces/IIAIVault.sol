// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IA0G} from "./external/IA0G.sol";
import {IA0GOracle} from "./external/IA0GOracle.sol";
import {IIAI} from "./IIAI.sol";

/**
 * @title IIAIVault
 * @notice Custody, position accounting, issuance and yield extraction for iAI.
 */
interface IIAIVault {
    /**
     * @notice A minter's whole relationship with the vault, in two numbers.
     * @dev The weighted-average entry rate is `locked0G / iaiOutstanding`, computed on
     *      demand rather than stored. Per-mint records are not kept: redemption settles
     *      at the wallet's average, so the individual tranches carry no information.
     * @param locked0G       Principal in 0G value. Set from the curve, never from the
     *                       a0G amount actually received, so the sum across positions
     *                       reconciles exactly against the curve.
     * @param iaiOutstanding iAI minted by this address and not yet redeemed.
     */
    struct Position {
        uint256 locked0G;
        uint256 iaiOutstanding;
    }

    /**
     * @param iai        The iAI token. The vault must hold its minter/burner role.
     * @param a0G        Collateral token.
     * @param foundation Recipient of harvested yield.
     * @param r0         Marginal price at supply zero, 0G per iAI.
     * @param cap        Hard supply ceiling, wei-iAI.
     * @param target     Total 0G locked at full supply. Fixes `slope` by construction.
     */
    struct InitParams {
        address iai;
        address a0G;
        address foundation;
        uint256 r0;
        uint256 cap;
        uint256 target;
    }

    error ZeroAddress();
    error ZeroAmount();
    /// @notice Mint would push supply past the hard cap.
    error CapExceeded(uint256 supplyAfter, uint256 cap);
    /// @notice Transaction sat past the caller's deadline.
    error Expired(uint256 deadline, uint256 nowTs);
    /// @notice Someone minted ahead of the caller and moved the curve.
    error CurveSlippage(uint256 delta0G, uint256 maxDelta0G);
    /// @notice The a0G exchange rate moved between quoting and execution.
    error ExcessiveInput(uint256 required, uint256 maxAccepted);
    /// @notice Same, on the redemption side.
    error InsufficientOutput(uint256 available, uint256 minAccepted);
    /**
     * @notice The token's own supply and the vault's counter disagree.
     * @dev Fail-closed rather than trusting either. Drifting low would let the curve sell
     *      the same slice twice and silently break the cap; drifting high would underflow
     *      the counter on redemption and permanently brick the one path that must always work.
     */
    error SupplyDesync(uint256 tokenSupply, uint256 vaultSupply);
    /// @notice Caller holds no redeemable position, or asked to redeem more than it holds.
    error BurnExceedsPosition(uint256 requested, uint256 outstanding);
    /// @notice Collateral token delivered less than it was asked to.
    error UnexpectedTransferAmount(uint256 expected, uint256 received);

    /// @dev Every event carries the resulting state so an indexer can rebuild the full
    ///      picture from the log stream alone, with no follow-up RPC calls, and can spot
    ///      a gap by checking continuity of the running totals.
    event Minted(
        address indexed minter,
        uint256 iaiOut,
        uint256 locked0G,
        uint256 a0GIn,
        uint256 exchangeRate,
        uint256 supplyAfter,
        uint256 totalLocked0GAfter
    );

    /// @dev `caller` differs from `minter` only on a rescue, which makes those
    ///      operations distinguishable in an index without extra state.
    event Burned(
        address indexed minter,
        address indexed caller,
        uint256 iaiIn,
        uint256 unlocked0G,
        uint256 a0GOut,
        uint256 exchangeRate,
        uint256 supplyAfter,
        uint256 totalLocked0GAfter
    );

    event Harvested(address indexed to, uint256 a0GSurplus, uint256 exchangeRate, uint256 totalLocked0G);

    event FoundationUpdated(address indexed previous, address indexed current);

    function mint(uint256 d, uint256 maxDelta0G, uint256 maxA0GIn, uint256 deadline) external;

    function burn(uint256 b, uint256 minA0GOut, uint256 deadline) external;

    function burnFor(address minter, uint256 b, uint256 minA0GOut, uint256 deadline) external;

    function harvest() external returns (uint256 surplus);

    function setFoundation(address newFoundation) external;

    // --- views ---

    function quoteMint(uint256 d) external view returns (uint256 delta0G, uint256 a0GIn);

    function quoteBurn(address minter, uint256 b) external view returns (uint256 unlocked0G, uint256 a0GOut);

    function quoteMintForA0G(uint256 a0GAmount) external view returns (uint256 d);

    function positionOf(address account)
        external
        view
        returns (uint256 locked0G, uint256 iaiOutstanding, uint256 avgRate);

    function exchangeRate() external view returns (uint256);

    function lockedAt(uint256 s) external view returns (uint256);

    function pendingSurplus() external view returns (uint256);

    function iai() external view returns (IIAI);

    function a0G() external view returns (IA0G);

    function oracle() external view returns (IA0GOracle);

    function foundation() external view returns (address);

    function r0() external view returns (uint256);

    function slope() external view returns (uint256);

    function cap() external view returns (uint256);

    function target() external view returns (uint256);

    function totalLocked0G() external view returns (uint256);

    function supply() external view returns (uint256);
}
