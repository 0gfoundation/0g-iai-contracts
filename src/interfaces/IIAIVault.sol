// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {EpochMath} from "../EpochMath.sol";
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
     * @notice A minter's whole relationship with the vault.
     *
     * @dev The claim is held in two denominations, and which one a wei sits in decides who
     *      receives its appreciation: `claim0G` redeems for fewer a0G as a0G appreciates, so
     *      that appreciation is left behind for the foundation, while `claimA0G` is returned
     *      as deposited and keeps its own. The proportion between them is set at mint from the
     *      harvest share then in force, and restated whenever governance changes that share --
     *      see `EpochMath` for why restating every position costs a constant.
     *
     *      Per-mint records are not kept: redemption settles at the wallet's blend, so the
     *      individual tranches carry no information.
     */
    struct Position {
        /// 0G-denominated claim, in wei-0G. Its appreciation accrues to the foundation.
        uint256 claim0G;
        /// Share-denominated claim, in wei-a0G. Its appreciation stays with the minter.
        uint256 claimA0G;
        /// iAI minted by this address and not yet redeemed, in wei-iAI. Bounded by the vault's
        /// own absolute supply bound of 2**127, so it cannot overflow this width.
        uint128 iaiOutstanding;
        /// Index of the epoch these claims were last restated under.
        uint64 epoch;
    }

    /**
     * @param iai        The iAI token. The vault must hold its minter/burner role.
     * @param a0G        Collateral token.
     * @param foundation Recipient of harvested yield.
     * @param curve      Pricing curve to start with. Swappable afterwards via `setCurve`.
     * @param cap          Starting supply ceiling, wei-iAI. Adjustable afterwards via `setCap`.
     * @param harvestShare Foundation's starting cut of collateral appreciation, WAD.
     *                     Adjustable afterwards via `setHarvestShare`.
     */
    struct InitParams {
        address iai;
        address a0G;
        address foundation;
        address curve;
        uint256 cap;
        uint256 harvestShare;
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
    ///      picture from the log stream alone, with no follow-up RPC calls.
    ///
    ///      `totalLocked0GAfter` is the 0G value of every outstanding position, so it moves
    ///      with the exchange rate as well as with mints and burns. It is therefore no longer
    ///      the running sum it once was, and continuity across two events is not a plain
    ///      delta. An indexer wanting exact reconstruction tracks the harvest share from
    ///      `HarvestShareUpdated` and splits each mint the way the vault does; the fields
    ///      needed for that -- the curve's price and the a0G collected -- are already here.
    event Minted(
        address indexed minter,
        uint256 iaiOut,
        uint256 locked0G,
        uint256 a0GIn,
        uint256 exchangeRate,
        uint256 supplyAfter,
        uint256 totalLocked0GAfter
    );

    /// @dev One address only: redemption settles the caller's own position, so the burner and
    ///      the position owner are always the same account. Symmetric with `Minted`.
    event Burned(
        address indexed minter,
        uint256 iaiIn,
        uint256 unlocked0G,
        uint256 a0GOut,
        uint256 exchangeRate,
        uint256 supplyAfter,
        uint256 totalLocked0GAfter
    );

    event Harvested(address indexed to, uint256 a0GSurplus, uint256 exchangeRate, uint256 totalLocked0G);

    /**
     * @notice The split of collateral appreciation changed.
     * @dev Carries the rate and running product the new epoch opened with, which is everything
     *      an indexer needs to restate the positions it tracks. The change itself transfers
     *      nothing: every position is worth exactly what it was worth a moment earlier.
     */
    event HarvestShareUpdated(
        uint256 indexed epoch, uint256 previousShare, uint256 newShare, uint256 exchangeRate, uint256 cumulativeGrowth
    );

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
     *
     * @dev Reverts `EnforcedPause` while issuance is paused, unless the caller holds the
     *      vault's `PAUSE_EXEMPT_MINTER_ROLE`. That exemption changes nothing else: the price,
     *      the supply ceiling, the slippage bound and the recipient are all the same. A client
     *      deciding whether to offer minting therefore needs `paused()` **and** `hasRole` for
     *      that account, not `paused()` alone.
     */
    function mint(uint256 d, uint256 maxA0GIn, uint256 deadline) external;

    /**
     * @notice Burns `b` of the caller's iAI and returns their share of the collateral.
     * @param b        Amount of iAI to burn, in wei-iAI. Needs no allowance.
     * @param deadline Latest block timestamp the caller accepts, in seconds.
     *
     * @dev The only way collateral leaves a position, and it settles the caller's own. There
     *      is deliberately no on-behalf variant: one would have to burn somebody else's iAI to
     *      unwind a position, which nobody has a reason to do, and the vault is upgradeable if
     *      a specific case ever needs one.
     */
    function burn(uint256 b, uint256 deadline) external;

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

    /**
     * @notice Sets the foundation's cut of collateral appreciation from here on.
     * @param newShare Foundation's cut, WAD. `1e18` sends all appreciation to the foundation,
     *                 which is how the vault behaved before the share was adjustable; zero
     *                 sends all of it to minters.
     *
     * @dev Prospective in time, not in cohort: every outstanding position is restated by value
     *      at the current rate, so appreciation already earned keeps the split it was earned
     *      under and everything after this point uses the new one. Nothing moves between
     *      minter and foundation at the moment of the change, so there is no advantage in
     *      choosing when to make it.
     *
     *      Refused if the rate has fallen since the last change. See `EpochMath`.
     */
    function setHarvestShare(uint256 newShare) external;

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
     * @return locked0G       What the position is worth right now, in wei-0G. Dividing it by
     *                        `exchangeRate()` gives the a0G a full redemption would pay. It
     *                        rises as the collateral appreciates, by the minter's share of
     *                        that appreciation.
     * @return iaiOutstanding iAI minted by this address and not yet redeemed, in wei-iAI.
     * @return avgRate        `locked0G / iaiOutstanding`, in wei-0G per iAI; zero when the
     *                        position is empty. The 0G currently behind each iAI, which is
     *                        the entry rate only while the rate has not moved.
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
     * @notice What every outstanding position is worth, in 0G, right now.
     * @dev **This is the collateral the vault actually holds claims against** -- derived from
     *      what was really collected, not from what any curve says it should have been. After
     *      a curve swap those two diverge, and only this figure is a fact about the system.
     *
     *      It ratchets upward under churn: a redeemer releases 0G at their own average while
     *      the freed supply is resold at the marginal rate. It also rises with the exchange
     *      rate, by the minters' share of the appreciation. Never bound it by a curve's target.
     * @return 0G value, in wei-0G.
     */
    function totalLocked0G() external view returns (uint256);

    /// @return Foundation's current cut of collateral appreciation, WAD.
    function harvestShare() external view returns (uint256);

    /// @return Index of the epoch now in force. Rises by one on each `setHarvestShare`.
    function currentEpoch() external view returns (uint256);

    /**
     * @notice One entry in the history of the harvest share.
     * @param index Epoch index, `0 <= index <= currentEpoch()`.
     * @return The rate and running product it opened with, and the share it put in force.
     */
    function epochAt(uint256 index) external view returns (EpochMath.Epoch memory);

    /**
     * @notice Sum of the 0G-denominated half of every claim.
     * @dev Internal accounting, exposed so tests and monitoring can watch the two halves move
     *      independently -- a fault that shifted value between them while preserving the total
     *      would be invisible in `totalLocked0G()` alone. **Integrators should use
     *      `totalLocked0G()`**, which is the figure with a meaning outside this contract.
     * @return 0G, in wei-0G.
     */
    function totalClaim0G() external view returns (uint256);

    /**
     * @notice Sum of the share-denominated half of every claim.
     * @dev Internal accounting, as `totalClaim0G()`. **Integrators should use
     *      `totalLocked0G()`.**
     * @return a0G, in wei-a0G.
     */
    function totalClaimA0G() external view returns (uint256);

    /**
     * @notice The two halves of one position, brought up to date, and the epoch they now sit in.
     * @param account Address to read.
     * @return claim0G  0G-denominated half, in wei-0G.
     * @return claimA0G Share-denominated half, in wei-a0G.
     * @return epoch    Epoch the halves are stated under, always the current one.
     * @dev Internal accounting, exposed for the same reason as `totalClaim0G()`: value moved
     *      between the two halves leaves `positionOf` unchanged, so a fault there would be
     *      invisible to anything watching only the total. **Integrators should use
     *      `positionOf`**, and unlike this pair it needs no explanation of the split.
     */
    function positionClaims(address account)
        external
        view
        returns (uint256 claim0G, uint256 claimA0G, uint256 epoch);

    /// @return Current iAI supply, in wei-iAI. Identical to `iai().totalSupply()`.
    function supply() external view returns (uint256);
}
