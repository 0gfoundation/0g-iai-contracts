// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title EpochMath
 * @notice Bookkeeping for an adjustable split of collateral appreciation between the minter
 *         who deposited it and the foundation.
 *
 * @dev **The two buckets.** A position's claim on the vault is held in two denominations,
 *      and which denomination a wei sits in decides who receives its appreciation:
 *
 *        - `claim0G`  is denominated in 0G. It redeems for `claim0G / rate` a0G, so as a0G
 *          appreciates it buys fewer shares and the difference stays behind for the
 *          foundation.
 *        - `claimA0G` is denominated in a0G shares. It is returned exactly as deposited, so
 *          its appreciation stays with the minter.
 *
 *      There is no third denomination, so a split of `share` / `1 - share` is not one choice
 *      among many: it is the only linear interpolation between the two, and the interpolation
 *      coefficient *is* the split. A position's value in 0G is
 *
 *          V(rate) = claim0G + claimA0G * rate
 *
 *      whose derivative in `rate` is `claimA0G`, a constant, while the derivative of the
 *      deposited shares' value is the (also constant) number of shares deposited. So for as
 *      long as the split stands the minter captures the same fraction of every increment,
 *      however far the rate travels and by whatever path: the two sides divide the gain since
 *      the mint linearly, and neither compounds on what it has already accrued.
 *
 *      **That last part stops holding across a change of split, and the difference is real.**
 *      A change re-bases the minter's share onto the position's current value rather than the
 *      deposit, and turns the foundation's accrued part into shares that do compound for it.
 *      Re-issuing the same share is therefore not a no-op going forward -- it moves a little
 *      future yield to the foundation each time. Nothing here can prevent that: expressing
 *      "the new split applies to the original deposit's appreciation" needs the deposit kept
 *      as a third figure and a 0G half allowed to go negative, which two unsigned buckets
 *      cannot represent.
 *
 *      **Why a cumulative factor can stand in for replaying every past change.** A change of
 *      split, made at rate `r_i` with new share `s_i`, rewrites every position by value:
 *
 *          V         = claim0G + claimA0G * r_i
 *          claim0G'  = s_i * V
 *          claimA0G' = (1 - s_i) * V / r_i
 *
 *      Value is preserved exactly -- `claim0G' + claimA0G' * r_i == V` -- so nothing moves
 *      between minter and foundation at the moment of the change, whatever rate it is made at.
 *      It only sets how the *next* increment is divided, and re-bases what that increment is
 *      measured against; see the note above on why that is not the same as being neutral. The foundation's already
 *      accrued share needs no handling here at all: it is the vault's balance in excess of
 *      what the positions claim, so it is untouched by a rewrite of the positions and goes on
 *      appreciating as shares.
 *
 *      After that rewrite both buckets are pinned by the single number `V`, in a ratio that is
 *      the same for every position: `claim0G' / claimA0G' == s_i * r_i / (1 - s_i)`. Feeding
 *      that shape into the next change, at `r_{i+1}`, collapses two numbers into one:
 *
 *          V_{i+1} = s_i * V_i + (1 - s_i) * V_i / r_i * r_{i+1}
 *                  = V_i * [ s_i + (1 - s_i) * r_{i+1} / r_i ]
 *                  = V_i * g_i
 *
 *      `g_i` carries no position data -- only two adjacent rates and the share between them --
 *      so every position rewritten at change `i` grows by the same factor. Recording the
 *      running product `cumG_i = g_0 * ... * g_{i-1}` at each change turns the replay of every
 *      missed change into a single ratio: a position that last settled at change `j` arrives
 *      at change `n` holding `V * cumG_n / cumG_j`, however many changes lie between. That is
 *      what keeps redemption a fixed cost no matter how often the split is retuned.
 *
 *      One step cannot be folded in. A position minted *during* an epoch was recorded at its
 *      own mint rate, so its buckets are not in the canonical ratio above and `g` does not
 *      describe it. Its first step is computed directly, at the rate of the first change it
 *      missed; the ratio carries it from there. `g_0` is therefore never applied to anything
 *      -- no position can be canonical at epoch 0, since the vault is empty when it opens --
 *      and it cancels out of every `cumG_n / cumG_j` a caller can ask for.
 *
 *      **Rates may not go backwards, and that is what keeps `cumG` safe.** Requiring
 *      `r_{i+1} >= r_i` at each change makes `g_i >= 1` by construction, so `cumG` never
 *      decreases from its starting value of one. Since `cumG` appears as a divisor, a value of
 *      zero would brick every position that pointed at or before it -- and settling sits in
 *      front of redemption, so that would be permanent and unrecoverable. Monotonicity rules
 *      the case out structurally rather than guarding against it, which is why no such guard
 *      appears below. Growth is the only remaining direction, and an overflow there reverts
 *      the governance call that caused it without touching any user path.
 *
 *      **Precision.** `cumG` is a running product and every step floors, so its error is
 *      systematic and one-directional: a position is understated, never overstated. The
 *      worst case is about 6e-28 of relative value per change. On a position the size of the
 *      whole vault at its cap -- around 1e26 wei-0G -- that is 6 wei after a hundred changes
 *      and 63 after a thousand, so the phrase to avoid is "a fraction of a wei"; the right
 *      one is 6e-17 0G, which is nothing, but is not nothing wei. Held at 1e18 instead the
 *      same thousand changes would cost 6e10 wei, still immaterial in 0G -- what 1e27 buys is
 *      that a single missed change settles bit-for-bit identically either way, which is a
 *      property a test can assert. The drift is also confined to positions: the vault
 *      restates its totals from the same transform at each change and never routes them
 *      through `cumG`, so it can never reach solvency or the sweep.
 *
 *      **Rounding.** Everything a position claims rounds down and everything the vault owes
 *      rounds up, so the residue always lands in the vault. Applied to the totals the
 *      transform rounds up and applied to a position it rounds down, which -- the transform
 *      being linear, so that `T(sum) == sum of T` before rounding -- keeps the totals at or
 *      above the sum of the positions they stand for. The gap is at most a wei per position
 *      per change and is never claimable by anyone; it shows up as a sweep a few wei short.
 */
library EpochMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    /// @notice One entry in the history of the split.
    struct Epoch {
        /// Exchange rate at the instant this epoch opened, in 0G per a0G, WAD-scaled.
        uint256 rate;
        /// Running product of the growth factors of all earlier epochs, RAY-scaled.
        uint256 cumG;
        /// Foundation's cut of appreciation while this epoch is in force, WAD-scaled.
        uint64 share;
    }

    /// @notice A split above one would hand the foundation more than the whole appreciation.
    error ShareAboveOne(uint256 share);
    /// @notice A zero rate cannot open an epoch: it is a divisor in every later settlement.
    error ZeroRate();
    /// @notice The rate fell below the previous epoch's. See the note on monotonicity above.
    error RateWentBackwards(uint256 rate, uint256 previous);

    /**
     * @notice Opens the first epoch.
     * @param rate  Exchange rate at deployment, WAD. Never applied to a position -- the vault
     *              is empty when this epoch opens, so nothing can be canonical at it -- but it
     *              anchors the monotonicity check and must therefore be a real reading.
     * @param share Starting split, WAD.
     * @return The genesis epoch.
     */
    function genesis(uint256 rate, uint256 share) internal pure returns (Epoch memory) {
        if (share > WAD) revert ShareAboveOne(share);
        if (rate == 0) revert ZeroRate();
        return Epoch({rate: rate, cumG: RAY, share: uint64(share)});
    }

    /**
     * @notice Opens the epoch that follows `prev`.
     * @param prev  The epoch currently in force.
     * @param rate  Exchange rate at this moment, WAD. Must not be below `prev.rate`.
     * @param share The split that takes effect from here, WAD.
     * @return The new epoch, carrying the running product forward.
     *
     * @dev `g` is computed as one `mulDiv` over `share * prev.rate + (1 - share) * rate`
     *      rather than as a sum of two rounded terms: one flooring instead of two, so the
     *      running product drifts half as fast. Both forms floor to at least `RAY` when
     *      `rate >= prev.rate` -- `RAY / WAD` is a whole number, so the two-term form loses
     *      nothing at the bound either -- and it is that inequality, not any runtime check,
     *      that keeps `cumG` away from zero.
     *
     *      The products stay far inside `uint256`: the rate would have to exceed 1e59 before
     *      `WAD * prev.rate` came close, and checked arithmetic would revert the governance
     *      call rather than wrap if it ever did.
     */
    function next(Epoch memory prev, uint256 rate, uint256 share) internal pure returns (Epoch memory) {
        if (share > WAD) revert ShareAboveOne(share);
        if (rate < prev.rate) revert RateWentBackwards(rate, prev.rate);

        uint256 g = Math.mulDiv(RAY, prev.share * prev.rate + (WAD - prev.share) * rate, WAD * prev.rate);
        return Epoch({rate: rate, cumG: Math.mulDiv(prev.cumG, g, RAY), share: uint64(share)});
    }

    /**
     * @notice Carries a position forward across every split change it has missed.
     * @param claim0G  The position's 0G-denominated claim as last settled.
     * @param claimA0G The position's share-denominated claim as last settled.
     * @param first    The first epoch the position missed, i.e. the one after the epoch it
     *                 last settled in.
     * @param last     The epoch now in force.
     * @return The two claims restated under `last`.
     *
     * @dev Reads no oracle. Every rate it uses was recorded when the corresponding change was
     *      made, so bringing a position up to date cannot fail on a stale feed and adds no
     *      revert path to redemption. It also leaves the vault's totals alone: those were
     *      transformed in full at the moment of each change, so they already account for this
     *      position and adjusting them here would count it twice.
     *
     *      Both results round down. See the note on rounding above.
     */
    function sync(uint256 claim0G, uint256 claimA0G, Epoch memory first, Epoch memory last)
        internal
        pure
        returns (uint256, uint256)
    {
        // Direct, because a position minted during its epoch is not in the canonical ratio
        // and no growth factor describes it. From `first` onward it is, and one ratio covers
        // every remaining change.
        uint256 v = claim0G + Math.mulDiv(claimA0G, first.rate, WAD);
        if (last.cumG != first.cumG) v = Math.mulDiv(v, last.cumG, first.cumG);

        return (Math.mulDiv(v, last.share, WAD), Math.mulDiv(v, WAD - last.share, last.rate));
    }

    /**
     * @notice Restates the vault's totals under a new split.
     * @param total0G  Sum of the 0G-denominated claims.
     * @param totalA0G Sum of the share-denominated claims.
     * @param rate     Exchange rate at this moment, WAD.
     * @param share    The split taking effect, WAD.
     * @return The two totals restated.
     *
     * @dev The same transform `sync` applies to a position, at a single change and rounded the
     *      other way. Because the transform is linear, applying it once to the totals gives the
     *      same answer as applying it to every position and adding up -- which is what lets the
     *      totals move the moment the split changes while positions catch up whenever they are
     *      next touched. Rounding up here and down there keeps the totals on the safe side of
     *      that identity.
     *
     *      Of the three ceilings, the two on the results are what dominance rests on. The one
     *      on `v` is not: `sum of floor <= floor of sum` already covers it, so flooring there
     *      would keep the totals above the positions too. It rounds up for consistency with
     *      the other two and because a larger `v` can only make the obligation more
     *      conservative -- not because anything depends on it. No test distinguishes it, and
     *      inventing one that did would be pinning a choice rather than a property.
     */
    function resplitTotals(uint256 total0G, uint256 totalA0G, uint256 rate, uint256 share)
        internal
        pure
        returns (uint256, uint256)
    {
        uint256 v = total0G + Math.mulDiv(totalA0G, rate, WAD, Math.Rounding.Ceil);
        return (
            Math.mulDiv(v, share, WAD, Math.Rounding.Ceil),
            Math.mulDiv(v, WAD - share, rate, Math.Rounding.Ceil)
        );
    }

    /**
     * @notice Splits a fresh deposit into the two buckets.
     * @param delta0G The curve's price for this mint, in 0G.
     * @param a0GIn   The a0G actually collected for it.
     * @param share   The split in force, WAD.
     * @return claim0G  The 0G-denominated claim to record.
     * @return claimA0G The share-denominated claim to record.
     *
     * @dev The split is consumed here and nowhere else, which is what makes a change of split
     *      an act on the future only: a position already carries its own history in its two
     *      buckets, and nothing downstream reads the share again.
     *
     *      Both round down, so a mint records marginally less than it paid for and the
     *      difference stays in the vault. The two together can never exceed what was collected:
     *      `share * delta0G / rate <= share * a0GIn` because `a0GIn` is the ceiling of
     *      `delta0G / rate`, and the remaining `(1 - share) * a0GIn` completes it.
     */
    function split(uint256 delta0G, uint256 a0GIn, uint256 share)
        internal
        pure
        returns (uint256 claim0G, uint256 claimA0G)
    {
        claim0G = Math.mulDiv(delta0G, share, WAD);
        claimA0G = Math.mulDiv(a0GIn, WAD - share, WAD);
    }

    /**
     * @notice What a pair of claims is worth, in 0G, at `rate`.
     * @param claim0G  0G-denominated claim.
     * @param claimA0G Share-denominated claim.
     * @param rate     Exchange rate, WAD.
     * @return The value in 0G.
     */
    function value0G(uint256 claim0G, uint256 claimA0G, uint256 rate) internal pure returns (uint256) {
        return claim0G + Math.mulDiv(claimA0G, rate, WAD);
    }

    /**
     * @notice The a0G a pair of claims settles for.
     * @param claim0G  0G-denominated claim.
     * @param claimA0G Share-denominated claim.
     * @param rate     Exchange rate, WAD.
     * @return The a0G to pay out.
     *
     * @dev Rounds down: value leaving the vault is never generous. Must stay the mirror image
     *      of `owed` -- the sweep is the vault's balance less what it owes, so if these two
     *      ever disagree about what a claim settles for, `harvest` either strands value or
     *      hands out value that a redeemer is still entitled to.
     */
    function payout(uint256 claim0G, uint256 claimA0G, uint256 rate) internal pure returns (uint256) {
        return Math.mulDiv(claim0G, WAD, rate, Math.Rounding.Floor) + claimA0G;
    }

    /**
     * @notice The a0G the vault owes against a pair of totals.
     * @param total0G  Sum of the 0G-denominated claims.
     * @param totalA0G Sum of the share-denominated claims.
     * @param rate     Exchange rate, WAD.
     * @return The obligation in a0G.
     *
     * @dev Rounds up, the mirror of `payout`. A function of recorded claims alone: it must
     *      never be made to depend on the vault's balance. Were it to, each sweep would take a
     *      cut of whatever the previous one left behind, and repeated calls would drain a
     *      surplus that is only partly the foundation's.
     */
    function owed(uint256 total0G, uint256 totalA0G, uint256 rate) internal pure returns (uint256) {
        return Math.mulDiv(total0G, WAD, rate, Math.Rounding.Ceil) + totalA0G;
    }
}
