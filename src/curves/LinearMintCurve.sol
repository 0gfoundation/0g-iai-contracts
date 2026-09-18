// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IMintCurve} from "../interfaces/IMintCurve.sol";
import {LinearCurveMath} from "./LinearCurveMath.sol";

/**
 * @title LinearMintCurve
 * @notice The linear bonding curve, as a deployed value.
 *
 * @dev A thin wrapper over `LinearCurveMath`. Every parameter is `immutable`, so the contract
 *      holds **no storage at all** and nobody — no admin, no upgrade — can reshape a curve
 *      that is already in service. Changing the curve means deploying a different one and
 *      pointing the vault at it, which is a visible, auditable act rather than a silent write.
 *
 *      Keeping the maths in a library rather than inlining it here is deliberate: the golden
 *      vectors in `test/unit/curves/LinearCurveMath.t.sol` exercise it as `pure` code with no
 *      external call, which keeps a 1,000-iteration split test and two 1,024-run fuzz tests
 *      fast. This contract is then checked against those same vectors through the external
 *      interface, so both the maths and the wrapper are pinned.
 *
 *      `anchorCap` is where `slope` was pinned and it is also this curve's supply ceiling:
 *      the vault has no cap of its own and refuses any mint past `maxSafeSupply()`, which
 *      returns it. `target` is provenance -- the 0G the curve accounts for at that ceiling,
 *      kept so "127,000,000 0G at full supply" stays readable on chain. Both are immutable;
 *      neither can drift out of agreement with anything.
 */
contract LinearMintCurve is IMintCurve {
    /// @notice Marginal price at supply zero, in wei-0G per iAI.
    uint256 public immutable r0;
    /// @notice Rise of the marginal price per unit of supply, scaled by 1e18. Derived, never supplied.
    uint256 public immutable slope;
    /// @notice The supply `slope` was derived against, and the ceiling this curve permits
    ///         issuance up to. Also `maxSafeSupply()`.
    uint256 public immutable anchorCap;
    /// @notice The 0G this curve locks at `anchorCap`. Provenance only.
    uint256 public immutable target;

    /// @notice `deriveSlope` and `lockedAt` stopped being inverses of one another. Not
    ///         reachable from any parameters a caller can supply -- see the constructor.
    error CurveFormulasDisagree(uint256 lockedAtCap, uint256 target);
    /// @notice A curve that charges nothing for a real amount would hand out free iAI.
    error CurveChargesNothing();

    /**
     * @param r0_     Marginal price at supply zero, in wei-0G per iAI.
     * @param cap_    Supply the curve is anchored to; fixes `slope` together with `target_`.
     * @param target_ Total 0G locked once supply reaches `cap_`, in wei-0G.
     *
     * @dev **This is the last chance to validate anything.** The contract is immutable, so
     *      there is no later opportunity to notice a bad parameter — every property the vault
     *      and the conformance suite rely on is checked here, once, at construction.
     *
     *      Malformed parameters are already rejected by `deriveSlope` (zero or oversized cap,
     *      a target the flat portion alone would exceed, a slope that floors to zero). What is
     *      added here is what `deriveSlope` cannot see: that the curve charges something for a
     *      single wei, and that both the top of the curve and the root solver are evaluable
     *      without an intermediate product overflowing. The last one matters because
     *      `quoteForValue` squares `k ~= s + r0*WAD/slope`, which depends on the parameters
     *      rather than on supply, so `maxSafeSupply()` does not cover it.
     */
    constructor(uint256 r0_, uint256 cap_, uint256 target_) {
        uint256 slope_ = LinearCurveMath.deriveSlope(r0_, cap_, target_);

        r0 = r0_;
        slope = slope_;
        anchorCap = cap_;
        target = target_;

        // Not a check on the parameters -- it cannot be one. `slope` is derived *from*
        // `target_`, so composing `deriveSlope` with `lockedAt` returns the target it started
        // from, to within the single flooring step each performs. Every triple that survives
        // `deriveSlope` therefore passes this, provably: no caller can trip it.
        //
        // What it guards is the pair of formulas. `deriveSlope` and `lockedAt` are inverses,
        // stated once in `LinearCurveMath` and nowhere enforced; edit either so they stop
        // agreeing and construction fails here rather than shipping a curve whose published
        // `target` is not the 0G it accounts for. Deploying a curve is the moment to notice.
        //
        // The tolerance is the exact flooring quantum, not a round number. It scales with
        // `cap^2` -- roughly 4.3e7 wei-0G at the production anchor and 5e15 at a hundred
        // million iAI -- so a constant chosen for one anchor is either blind or spuriously
        // strict at the other.
        uint256 atCap = LinearCurveMath.lockedAt(r0_, slope_, cap_);
        if (atCap > target_ || target_ - atCap > LinearCurveMath.maxFlooringGap(cap_)) {
            revert CurveFormulasDisagree(atCap, target_);
        }
        if (LinearCurveMath.cost(r0_, slope_, 0, 1) == 0) revert CurveChargesNothing();

        // Evaluable at the extremes: the top of the curve, and the root solver's squared term.
        LinearCurveMath.cost(r0_, slope_, cap_ - 1, 1);
        LinearCurveMath.quoteForValue(r0_, slope_, cap_, target_);
    }

    /// @inheritdoc IMintCurve
    function cost(uint256 supply, uint256 amount) external view returns (uint256) {
        return LinearCurveMath.cost(r0, slope, supply, amount);
    }

    /// @inheritdoc IMintCurve
    function quoteForValue(uint256 supply, uint256 delta0G) external view returns (uint256) {
        return LinearCurveMath.quoteForValue(r0, slope, supply, delta0G);
    }

    /**
     * @inheritdoc IMintCurve
     * @dev The anchor. It is the one supply figure this curve carries, and it is where the
     *      curve was designed to end: `target` is the 0G it accounts for exactly there. The
     *      arithmetic reaches much further -- `cost` multiplies `d * (2s + d)` outside `mulDiv`
     *      and stays inside uint256 up to `s = d = 2^127`, and `deriveSlope` caps the anchor at
     *      2^127 for that reason -- so a supply past the anchor is refused by the vault rather
     *      than by an overflow here.
     */
    function maxSafeSupply() external view returns (uint256) {
        return anchorCap;
    }

    /**
     * @notice Total 0G this curve accounts for at `supply` — the area under `rate`.
     * @param supply Supply to evaluate at, in wei-iAI.
     * @return 0G value, in wei-0G, rounded down.
     *
     * @dev Deliberately **not** on `IMintCurve`, and deliberately **not** forwarded by the
     *      vault. It describes the shape of this one curve, which is a different question from
     *      "how much collateral is actually locked" — after a curve swap the two diverge, and
     *      only `IAIVault.totalLocked0G()` answers the second. Kept here for charts,
     *      reconciliation and this contract's own construction check.
     */
    function lockedAt(uint256 supply) external view returns (uint256) {
        return LinearCurveMath.lockedAt(r0, slope, supply);
    }
}
