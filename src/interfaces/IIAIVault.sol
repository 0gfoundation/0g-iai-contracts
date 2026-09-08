// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IA0G} from "./external/IA0G.sol";
import {IA0GOracle} from "./external/IA0GOracle.sol";
import {IMintCurve} from "./IMintCurve.sol";
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
     * @param curve      Pricing curve to start with. Swappable afterwards via `setCurve`.
     * @param cap         Starting supply ceiling, wei-iAI. Adjustable afterwards via `setCap`.
     */
    struct InitParams {
        address iai;
        address a0G;
        address foundation;
        address curve;
        uint256 cap;
    }

    error ZeroAddress();
    error ZeroAmount();
    /// @notice Mint would push supply past the hard cap.
    error CapExceeded(uint256 supplyAfter, uint256 cap);
    /// @notice Transaction sat past the caller's deadline.
    error Expired(uint256 deadline, uint256 nowTs);
    /**
     * @notice Minting would cost more a0G than the caller allowed.
     * @dev Covers both causes at once: someone minting ahead and moving the curve, and the
     *      a0G rate moving between quote and execution. Retry with a fresh quote.
     */
    error ExcessiveInput(uint256 required, uint256 maxAccepted);
    /// @notice Caller holds no redeemable position, or asked to redeem more than it holds.
    error BurnExceedsPosition(uint256 requested, uint256 outstanding);
    /// @notice A curve address with no code behind it. Installing it would kill issuance.
    error NotAContract(address target);
    /**
     * @notice The cap would sit above the supply the curve's arithmetic is proven at.
     * @dev `bound` is the lower of the curve's own `maxSafeSupply()` and the vault's hard
     *      limit, so a curve reporting an absurd domain cannot widen it.
     */
    error CapAboveCurveDomain(uint256 requested, uint256 bound);

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

    /**
     * @notice The pricing curve was replaced. Everything already minted keeps its own price.
     * @dev Only the addresses: an indexer places the era boundary by block order, and
     *      `Minted.supplyAfter` already carries the supply, so a price snapshot here would be
     *      redundant.
     */
    event CurveUpdated(address indexed previous, address indexed current);

    /// @notice The supply ceiling moved. Below the current supply this closes issuance.
    event CapUpdated(uint256 previous, uint256 current);

    /**
     * @notice Locks a0G and mints exactly `d` iAI to the caller. Requires an a0G allowance.
     * @param d        Amount of iAI to mint, in wei-iAI.
     * @param maxA0GIn Maximum a0G the caller accepts spending, in wei-a0G.
     * @param deadline Latest block timestamp the caller accepts, in seconds.
     */
    function mint(uint256 d, uint256 maxA0GIn, uint256 deadline) external;

    /**
     * @notice Burns `b` of the caller's iAI and returns their share of the collateral.
     * @param b        Amount of iAI to burn, in wei-iAI. Needs no allowance.
     * @param deadline Latest block timestamp the caller accepts, in seconds.
     */
    function burn(uint256 b, uint256 deadline) external;

    /**
     * @notice Settles `minter`'s position using iAI supplied by the caller. `RESCUE_ROLE`.
     * @param minter   Position owner, and the sole recipient of the released collateral.
     * @param b        Amount of iAI to burn, in wei-iAI, taken from the caller.
     * @param deadline Latest block timestamp the caller accepts, in seconds.
     */
    function burnFor(address minter, uint256 b, uint256 deadline) external;

    /**
     * @notice Sends collateral in excess of what the vault owes to the foundation.
     * @dev Permissionless: it can only move value along one fixed path.
     * @return surplus a0G swept, in wei-a0G.
     */
    function harvest() external returns (uint256 surplus);

    /**
     * @notice Redirects future harvests. `DEFAULT_ADMIN_ROLE`.
     * @param newFoundation New recipient. Must be non-zero.
     */
    function setFoundation(address newFoundation) external;

    /**
     * @notice Replaces the pricing curve. `DEFAULT_ADMIN_ROLE`.
     * @param newCurve The curve to install. Must hold code, and the current cap must sit
     *                 inside its safe domain.
     *
     * @dev Prices only future mints. Positions already open record an absolute 0G amount and
     *      redeem at their own average, untouched.
     */
    function setCurve(IMintCurve newCurve) external;

    /**
     * @notice Moves the supply ceiling. `DEFAULT_ADMIN_ROLE`.
     * @param newCap New ceiling in wei-iAI. **May be below the current supply, and may be
     *               zero** -- that closes issuance while leaving redemption untouched.
     */
    function setCap(uint256 newCap) external;

    // --- views ---

    /**
     * @notice Prices minting `d` iAI at the current supply and exchange rate.
     * @param d Amount of iAI to price, in wei-iAI. Beyond the remaining headroom this reverts
     *          with `CapExceeded` -- the same error `mint` gives.
     * @return delta0G 0G value the curve charges, in wei-0G. Rounded up.
     * @return a0GIn   a0G that would be taken, in wei-a0G. Rounded up. Use it, widened by
     *                 a tolerance, as `maxA0GIn`.
     */
    function quoteMint(uint256 d) external view returns (uint256 delta0G, uint256 a0GIn);

    /**
     * @notice Prices burning `b` of `minter`'s iAI at the current exchange rate.
     * @param minter Position owner whose average rate applies.
     * @param b      Amount of iAI to burn, in wei-iAI. Above the position, this reverts with
     *               `BurnExceedsPosition` -- the same error `burn` gives, so a caller sees the
     *               same failure whether it quotes or executes.
     * @return unlocked0G 0G value released from the position, in wei-0G. Rounded down.
     * @return a0GOut     a0G that would be sent, in wei-a0G. Rounded down.
     */
    function quoteBurn(address minter, uint256 b) external view returns (uint256 unlocked0G, uint256 a0GOut);

    /**
     * @notice Inverts the curve: how much iAI a given amount of a0G buys right now.
     * @param a0GAmount Amount the caller intends to spend, in wei-a0G.
     * @return d Amount of iAI mintable, in wei-iAI. Rounded down, so minting `d` never costs
     *           more than `a0GAmount` at an unchanged rate.
     *
     * @dev Unlike `quoteMint`, more a0G than the curve has room for is **not** an error here:
     *      the caller asked what a given spend buys, and the remaining headroom is a true and
     *      mintable answer to that. It is returned clamped.
     */
    function quoteMintForA0G(uint256 a0GAmount) external view returns (uint256 d);

    /**
     * @notice The redeemable position of one address.
     * @param account Address to read.
     * @return locked0G       0G value backing the position, in wei-0G.
     * @return iaiOutstanding iAI minted by this address and not yet redeemed, in wei-iAI.
     * @return avgRate        `locked0G / iaiOutstanding`, in wei-0G per iAI; zero when the
     *                        position is empty.
     */
    function positionOf(address account)
        external
        view
        returns (uint256 locked0G, uint256 iaiOutstanding, uint256 avgRate);

    /**
     * @notice The a0G/0G exchange rate the vault prices against.
     * @dev Read live from the a0G oracle, so it reverts if that value has gone stale.
     * @return 0G per a0G, scaled by 1e18.
     */
    function exchangeRate() external view returns (uint256);

    /**
     * @notice How much more iAI may still be minted.
     * @return Headroom in wei-iAI. Zero once supply has reached or passed the cap — including
     *         after the cap was lowered below it, where `cap - supply` would be negative.
     *         Prefer this over computing the difference yourself.
     */
    function remainingCap() external view returns (uint256);

    /// @return The pricing curve currently in force.
    function curve() external view returns (IMintCurve);

    /**
     * @notice Collateral held beyond what the vault owes; what `harvest` would sweep.
     * @return a0G, in wei-a0G. Zero when there is nothing to sweep.
     */
    function pendingSurplus() external view returns (uint256);

    /// @return The iAI token this vault issues.
    function iai() external view returns (IIAI);

    /// @return The collateral token.
    function a0G() external view returns (IA0G);

    /// @return The a0G exchange-rate oracle, cached at initialization.
    function oracle() external view returns (IA0GOracle);

    /// @return Current recipient of harvested yield.
    function foundation() external view returns (address);

    /// @return Current supply ceiling, in wei-iAI. Governance-adjustable, so read it rather
    ///         than assuming the value a deployment started with.
    function cap() external view returns (uint256);

    /**
     * @notice Sum of every position's locked 0G.
     * @dev **This is the collateral the vault actually holds claims against** -- the sum of
     *      what was really collected, not what any curve says it should have been. After a
     *      curve swap those two diverge, and only this figure is a fact about the system.
     *
     *      It ratchets upward under churn: a redeemer releases 0G at their own average while
     *      the freed supply is resold at the marginal rate. Never bound it by a curve's
     *      target.
     * @return 0G value, in wei-0G.
     */
    function totalLocked0G() external view returns (uint256);

    /// @return Current iAI supply, in wei-iAI. Identical to `iai().totalSupply()`.
    function supply() external view returns (uint256);
}
