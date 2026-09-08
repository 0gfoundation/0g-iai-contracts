// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title LinearCurveMath
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
library LinearCurveMath {
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
        // `cost` multiplies `d * (2s + d)` outside `mulDiv`. Within the cap that peaks at
        // `cap^2`, but bounding cap at 2^127 keeps even `s = d = cap` (3*cap^2) inside
        // uint256, so a caller that ignores the domain note on `cost` still reverts on the
        // supply check rather than on an overflow deep in the arithmetic. Production cap is
        // 9.27e21, about 2^73.
        if (cap == 0 || cap > 2 ** 127) revert InvalidCurveCap();

        uint256 flatPortion = Math.mulDiv(r0, cap, WAD);
        if (target <= flatPortion) revert InvalidCurveTarget();

        slope = Math.mulDiv(2 * (target - flatPortion), WAD * WAD, cap * cap);
        if (slope == 0) revert InvalidCurveSlope();
    }

    /**
     * @notice Collateral required to move supply from `s` to `s + d`.
     * @param  r0    Marginal price at supply zero, in wei-0G per iAI.
     * @param  slope Rise of the marginal price per unit of supply, scaled by 1e18.
     * @param  s     Supply before the mint, in wei-iAI.
     * @param  d     Amount being minted, in wei-iAI.
     * @return 0G value to lock, in wei-0G.
     *
     * @dev    cost = R0*d/WAD + slope*d*(2s+d)/(2*WAD^2), each term rounded **up**.
     *
     *         Two independent ceilings mean the result can sit up to 2 wei above the
     *         exact integral. That direction favours the vault, and it makes splitting
     *         a mint into many small ones strictly more expensive than doing it in one
     *         transaction, so there is no rounding arbitrage in either direction.
     *
     *         Caller must keep `s + d` within the supply cap. `deriveSlope` bounds cap so
     *         that the bare products below stay inside uint256 even outside that range;
     *         Solidity's checked arithmetic reverts rather than wrapping if it is ever
     *         exceeded.
     */
    function cost(uint256 r0, uint256 slope, uint256 s, uint256 d) internal pure returns (uint256) {
        uint256 linear = Math.mulDiv(r0, d, WAD, Math.Rounding.Ceil);
        uint256 quadratic = Math.mulDiv(slope, d * (2 * s + d), 2 * WAD * WAD, Math.Rounding.Ceil);
        return linear + quadratic;
    }

    /**
     * @notice Total collateral the curve accounts for at supply `s` (the area under `rate`).
     * @param  r0    Marginal price at supply zero, in wei-0G per iAI.
     * @param  slope Rise of the marginal price per unit of supply, scaled by 1e18.
     * @param  s     Supply to evaluate at, in wei-iAI.
     * @return 0G value, in wei-0G.
     *
     * @dev    Floored. **Views and invariant checks only** — never the write path.
     *         `lockedAt(cap)` is deliberately a hair under `target`; asserting equality
     *         will fail.
     */
    function lockedAt(uint256 r0, uint256 slope, uint256 s) internal pure returns (uint256) {
        return Math.mulDiv(r0, s, WAD) + Math.mulDiv(slope, s * s, 2 * WAD * WAD);
    }

    /**
     * @notice The largest gap flooring alone can open between `lockedAt(cap)` and the `target`
     *         that `deriveSlope` was given.
     * @param  cap Anchor supply the slope was derived against, in wei-iAI.
     * @return Bound in wei-0G, inclusive.
     *
     * @dev    `deriveSlope` and `lockedAt` are inverse operations, so composing them returns
     *         the target it started from -- but each floors once, and the loss is one slope
     *         unit's worth of 0G. Writing `D = target - flat` and `c = cap^2 / (2*WAD^2)`:
     *
     *             slope            = floor(D / c)      >  D/c - 1
     *             slope * c                            >  D - c
     *             floor(slope * c)                     >  D - c - 1
     *             D - floor(slope * c)                 <  c + 1
     *
     *         so the gap is at most `floor(c) + 1`, which is what this returns. The bound is
     *         tight: a random search over 200,000 parameter triples reached 0.999992 of it.
     *
     *         It scales with `cap^2`, which is the reason it is computed rather than written
     *         as a constant. At the production anchor of 9,270 iAI it is about 4.3e7 wei-0G;
     *         at 100,000,000 iAI it is 5e15. A fixed tolerance generous enough for the second
     *         is blind at the first, and one tight enough for the first rejects the second
     *         although its relative error is around 1e-19.
     *
     *         `cap` is bounded by `deriveSlope` at 2^127, so `cap * cap` cannot overflow.
     */
    function maxFlooringGap(uint256 cap) internal pure returns (uint256) {
        return (cap * cap) / (2 * WAD * WAD) + 1;
    }

    /**
     * @notice Inverse of `cost`: how much iAI a given amount of 0G value buys at supply `s`.
     * @param  r0    Marginal price at supply zero, in wei-0G per iAI.
     * @param  slope Rise of the marginal price per unit of supply, scaled by 1e18.
     * @param  s     Current supply, in wei-iAI.
     * @param  delta 0G value the caller intends to spend, in wei-0G.
     * @return d     Amount mintable, in wei-iAI. Never quotes more than `delta` can pay for.
     *
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
     *         `k * k` is a bare product: at the smallest legal slope with a large `r0` it can
     *         overflow and revert. That needs a slope some 18 orders of magnitude below the
     *         production value (k^2 there is ~1.3e44), and it is a view, so the failure is a
     *         failed quote rather than a wrong one.
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
