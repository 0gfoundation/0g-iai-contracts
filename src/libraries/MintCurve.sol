// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MintCurve
 * @notice Stateless math for the iAI linear bonding curve.
 *
 * @dev The marginal price of the next iAI rises linearly with supply:
 *
 *          rate(s) = R0 + slope * s                (0G per iAI)
 *
 *      A mint is charged the *integral* of that line over the slice it consumes,
 *      never `rate(s) * d`. Charging the entry rate for the whole slice would
 *      under-collect by `slope/2 * d^2`, which is quadratic in the size of a single
 *      mint and independent of where on the curve it happens — a single max-size
 *      mint would pay roughly a third of what it owes.
 *
 *          cost(s -> s+d) = lockedAt(s+d) - lockedAt(s)
 *                         = R0*d + slope/2 * d*(2s+d)
 *
 *      `slope` is never supplied by a caller. It is derived from (R0, cap, target)
 *      so that `lockedAt(cap) == target` holds by construction and a mistyped
 *      constant cannot silently reshape the curve.
 *
 *      Rounding: every quantity that flows *into* the vault rounds up. `cost` is the
 *      only pricing primitive used on the write path; `lockedAt` floors and exists
 *      purely for views and invariant checks. The two differ by a few tens of
 *      millions of wei (~1e-11 0G) because `slope` itself is floored, so they must
 *      never be mixed as if interchangeable.
 *
 *      All values are 18-decimal fixed point. Divisions always go through
 *      `Math.mulDiv`, which carries a 512-bit intermediate product.
 */
library MintCurve {
    uint256 internal constant WAD = 1e18;

    /// @notice `target` must exceed the collateral the flat part of the curve alone would lock.
    error InvalidCurveTarget();
    /// @notice `cap` must be non-zero and small enough that `cap * cap` cannot overflow.
    error InvalidCurveCap();
    /// @notice Derived slope came out zero, which would flatten the curve.
    error InvalidCurveSlope();

    /**
     * @notice Derives `slope` such that `lockedAt(cap) == target`.
     * @dev    slope = 2 * WAD^2 * (target - R0*cap/WAD) / cap^2
     *
     *         Floored, so `lockedAt(cap)` lands a few tens of millions of wei *below*
     *         `target` rather than above it — the safe direction, since nothing is
     *         allowed to assert equality.
     *
     * @param r0     Marginal price at supply zero, 0G per iAI (18 decimals).
     * @param cap    Hard supply cap, in wei-iAI.
     * @param target Total 0G locked once supply reaches `cap`, in wei-0G.
     */
    function deriveSlope(uint256 r0, uint256 cap, uint256 target) internal pure returns (uint256 slope) {
        // cap^2 is computed unchecked-free below; bound cap so the square cannot overflow.
        if (cap == 0 || cap > type(uint128).max) revert InvalidCurveCap();

        uint256 flatPortion = Math.mulDiv(r0, cap, WAD);
        if (target <= flatPortion) revert InvalidCurveTarget();

        slope = Math.mulDiv(2 * (target - flatPortion), WAD * WAD, cap * cap);
        if (slope == 0) revert InvalidCurveSlope();
    }

    /**
     * @notice Collateral required to move supply from `s` to `s + d`.
     * @dev    cost = R0*d/WAD + slope*d*(2s+d)/(2*WAD^2), each term rounded **up**.
     *
     *         Two independent ceilings mean the result can sit up to 2 wei above the
     *         exact integral. That direction favours the vault, and it makes splitting
     *         a mint into many small ones strictly more expensive than doing it in one
     *         transaction, so there is no rounding arbitrage in either direction.
     *
     *         Caller must keep `s + d` within the supply cap; the products below are
     *         sized for that range and Solidity's checked arithmetic reverts otherwise.
     */
    function cost(uint256 r0, uint256 slope, uint256 s, uint256 d) internal pure returns (uint256) {
        uint256 linear = Math.mulDiv(r0, d, WAD, Math.Rounding.Ceil);
        uint256 quadratic = Math.mulDiv(slope, d * (2 * s + d), 2 * WAD * WAD, Math.Rounding.Ceil);
        return linear + quadratic;
    }

    /**
     * @notice Total collateral the curve accounts for at supply `s` (the area under `rate`).
     * @dev    Floored. **Views and invariant checks only** — never the write path.
     *         `lockedAt(cap)` is deliberately a hair under `target`; asserting equality
     *         will fail.
     */
    function lockedAt(uint256 r0, uint256 slope, uint256 s) internal pure returns (uint256) {
        return Math.mulDiv(r0, s, WAD) + Math.mulDiv(slope, s * s, 2 * WAD * WAD);
    }

    /**
     * @notice Inverse of `cost`: how much iAI a given amount of 0G value buys at supply `s`.
     * @dev    Solves `slope/2*D^2 + (R0 + slope*s)*D = delta` for D:
     *
     *             K = (R0 + slope*s/WAD) * WAD / slope
     *             D = sqrt(K^2 + 2*WAD^2*delta/slope) - K
     *
     *         The intermediate is scaled down by WAD relative to the naive form
     *         specifically to keep `K^2` inside uint256 — the unscaled square overflows.
     *
     *         Every rounding leans toward quoting *less*: `k` rounds **up** and the
     *         discriminant term rounds **down**, because the result decreases in `k`
     *         and increases in the discriminant. Getting `k`'s direction wrong makes
     *         the quote exceed what the caller can actually afford roughly a fifth of
     *         the time, and the subsequent `mint` then reverts on slippage.
     *
     *         The trailing loop is a correctness backstop, not an expected cost: with
     *         the rounding above it does not execute (0 iterations across 30k sampled
     *         (s, delta) pairs). It terminates unconditionally because `cost` is
     *         monotonically increasing in `d` and `cost(s, 0) == 0 <= delta`.
     *
     *         **View helper only.** Quoting is not pricing: feed the result back into
     *         `mint`, which re-prices with `cost`.
     */
    function quoteForValue(
        uint256 r0,
        uint256 slope,
        uint256 s,
        uint256 delta
    ) internal pure returns (uint256 d) {
        uint256 k = Math.mulDiv(r0 + Math.mulDiv(slope, s, WAD, Math.Rounding.Ceil), WAD, slope, Math.Rounding.Ceil);
        uint256 discriminant = k * k + Math.mulDiv(2 * delta, WAD * WAD, slope);
        d = Math.sqrt(discriminant) - k;

        while (d != 0 && cost(r0, slope, s, d) > delta) {
            unchecked {
                --d;
            }
        }
    }
}
