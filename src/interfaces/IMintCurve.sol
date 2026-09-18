// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/**
 * @title IMintCurve
 * @notice The pricing surface the vault calls. One curve is in force at a time; governance
 *         swaps it by pointing the vault at a different contract.
 *
 * @dev **Every member here is something the vault actually calls.** An interface member with
 *      no caller is a liability: whoever writes the next curve has to implement it, and it
 *      buys no guarantee. That is why `r0()`, `slope()` and `lockedAt()` are absent —
 *      the first two are specific to a linear curve, and `lockedAt` would be self-referential
 *      as a check (a curve that under-charges could simply report a matching under-stated
 *      integral). Concrete curves are free to expose all three for tooling.
 *
 *      **All functions are `view`, so the vault reaches them by `STATICCALL`.** A curve
 *      therefore cannot write state, and reentrancy is impossible by construction rather than
 *      by guard. Two things that does *not* buy, which a reviewer should know:
 *
 *      - `view` is not `pure`. A curve may read `block.timestamp` or `tx.origin` and price
 *        differently per transaction or per originator. The vault sees a price; it cannot see
 *        how the price was reached.
 *      - "A curve is an immutable value" is a property of the deployment convention, not of
 *        this type. The vault cannot distinguish a plain curve from a proxy in front of one.
 *
 *      Swapping curves does not reprice anything already minted: positions record an absolute
 *      0G amount, and redemption never consults a curve.
 *
 * ## Behavioural contract
 *
 * Signatures cannot express these, so they are stated here and enforced by the shared
 * conformance suite in `test/unit/curves/CurveConformance.t.sol`. **A new curve is not fit to
 * deploy until it passes that suite.**
 *
 * 1. `cost` rounds **up**; `quoteForValue` rounds **down**. Rounding always favours the vault.
 * 2. `cost(s, d) > 0` for every `d > 0`. A curve that gives iAI away lets the recipient claim
 *    compute for nothing and permanently inflates the supply the vault prices against.
 * 3. `cost(s, d)` is non-decreasing in `s`. The marginal price never falls as supply rises.
 * 4. Splitting is never cheaper: `cost(s, a) + cost(s + a, b) >= cost(s, a + b)`. Otherwise a
 *    minter can grind a large mint into pieces and pay less than the curve intends.
 * 5. A quote is affordable: `cost(s, quoteForValue(s, d)) <= d`. This is a genuine
 *    cross-check between the two functions rather than a curve grading its own work.
 * 6. No arithmetic reverts anywhere in `[0, maxSafeSupply()]`.
 * 7. Outside that range a curve owes no answer, and the two functions need not fail alike:
 *    `cost` may revert where `quoteForValue` returns zero, which is also what it returns for
 *    a budget that buys nothing. Neither return value distinguishes "nothing is available
 *    here" from "this supply is off the curve", so a caller that needs the edge reads
 *    `maxSafeSupply()` -- the only authoritative answer -- rather than inferring it.
 */
interface IMintCurve {
    /**
     * @notice Collateral required to move supply from `supply` to `supply + amount`.
     * @param supply Current iAI supply, in wei-iAI.
     * @param amount Amount being minted, in wei-iAI.
     * @return delta0G 0G value to lock, in wei-0G. Rounded **up**.
     *
     * @dev The only pricing primitive. The vault records this figure as the minter's claim and
     *      collects `ceil(delta0G / exchangeRate)` of collateral against it — both derived from
     *      this one return value, so the vault can never record more than it collects.
     */
    function cost(uint256 supply, uint256 amount) external view returns (uint256 delta0G);

    /**
     * @notice How much iAI a given amount of 0G value buys at `supply`.
     * @param supply  Current iAI supply, in wei-iAI.
     * @param delta0G 0G value the caller intends to spend, in wei-0G.
     * @return amount Amount mintable, in wei-iAI. Rounded **down**, so feeding it back into
     *                `cost` never exceeds `delta0G`.
     *
     * @dev Quoting is not pricing: the result is fed back into the vault's `mint`, which
     *      re-prices with `cost`. Implementations may be gas-heavy — this is only ever reached
     *      through an `eth_call`.
     */
    function quoteForValue(uint256 supply, uint256 delta0G) external view returns (uint256 amount);

    /**
     * @notice The supply this curve permits issuance up to.
     * @return Supply ceiling, in wei-iAI.
     *
     * @dev **This is the vault's supply cap.** The vault keeps no ceiling of its own: `mint`
     *      and every quote refuse to take the supply past this figure, so the ceiling moves
     *      when, and only when, governance swaps the curve. A curve may report a ceiling
     *      below the live supply; the vault then simply issues nothing until it is swapped
     *      again, and redemption is unaffected.
     *
     *      `cost` and `quoteForValue` must be evaluable everywhere in `[0, maxSafeSupply()]`
     *      (property 6 above). Whether they are evaluable beyond it is the curve's own
     *      business; the vault never asks.
     *
     *      The vault does not trust this figure on its own — it also applies its own hard
     *      bound of 2^127, so a curve reporting `type(uint256).max` cannot widen the domain
     *      past what the vault's own arithmetic is proven at.
     */
    function maxSafeSupply() external view returns (uint256);
}
