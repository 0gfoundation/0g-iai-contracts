// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {LinearCurveMath} from "../../../src/curves/LinearCurveMath.sol";

/**
 * @notice Pins the curve arithmetic to exact wei values computed independently of the
 *         Solidity implementation. If any of these move, the curve changed — which is
 *         a parameter decision, never an incidental refactor.
 */
contract LinearCurveMathTest is Test {
    uint256 internal constant WAD = 1e18;

    uint256 internal constant R0 = 4_330e18;
    uint256 internal constant CAP = 9_270e18;
    uint256 internal constant TARGET = 127_000_000e18;

    uint256 internal constant SLOPE = 2_021_598_247_004_348_741;
    uint256 internal constant R1 = 23_070_215_749_730_312_829_070;

    /// @dev `slope` is floored, so the closed form lands this many wei below TARGET.
    ///      Nothing may assert `lockedAt(cap) == target`; this is the exact gap.
    uint256 internal constant CAP_SHORTFALL = 37_260_550;

    /// @dev The library is `internal`, so a revert from it has no call frame for
    ///      `vm.expectRevert` or `try` to latch onto. Deployed once here rather than per fuzz
    ///      run, which would dominate the cost of a 1,024-run test.
    LinearCurveMathHarness internal harness = new LinearCurveMathHarness();

    function test_DeriveSlope_MatchesGoldenValue() public pure {
        assertEq(LinearCurveMath.deriveSlope(R0, CAP, TARGET), SLOPE, "slope");
    }

    function test_DeriveSlope_EndRateMatchesProductDocs() public pure {
        uint256 slope = LinearCurveMath.deriveSlope(R0, CAP, TARGET);
        // rate(cap) = R0 + slope*cap/WAD -- the product docs quote 23,070.2157497303
        assertEq(R0 + (slope * CAP) / WAD, R1, "R1");
        // avg = target/cap -- the docs quote 13,700.1079
        assertEq((TARGET * WAD) / CAP, 13_700_107_874_865_156_418_554, "avg");
    }

    /// @dev LinearCurveMath is an internal library, so its bodies are inlined and
    ///      `vm.expectRevert` has no call frame to latch onto. Route through a harness.
    function test_DeriveSlope_RejectsBadParameters() public {
        LinearCurveMathHarness h = new LinearCurveMathHarness();

        vm.expectRevert(LinearCurveMath.InvalidCurveCap.selector);
        h.deriveSlope(R0, 0, TARGET);

        vm.expectRevert(LinearCurveMath.InvalidCurveCap.selector);
        h.deriveSlope(R0, uint256(type(uint128).max) + 1, TARGET);

        // A target at or below the flat portion leaves no room for the slope.
        vm.expectRevert(LinearCurveMath.InvalidCurveTarget.selector);
        h.deriveSlope(R0, CAP, 1e18);

        vm.expectRevert(LinearCurveMath.InvalidCurveTarget.selector);
        h.deriveSlope(R0, CAP, (R0 * CAP) / WAD);
    }

    function test_Cost_GoldenVectors() public pure {
        assertEq(LinearCurveMath.cost(R0, SLOPE, 0, 1), 4_331, "1 wei");
        assertEq(LinearCurveMath.cost(R0, SLOPE, 0, 1e18), 4_331_010_799_123_502_174_371, "1 iAI");
        assertEq(LinearCurveMath.cost(R0, SLOPE, 0, 100e18), 443_107_991_235_021_743_705_000, "100 iAI");
        assertEq(LinearCurveMath.cost(R0, SLOPE, 0, 2_000e18), 12_703_196_494_008_697_482_000_000, "2000 iAI");
        assertEq(LinearCurveMath.cost(R0, SLOPE, 0, CAP), 126_999_999_999_999_999_962_739_450, "full cap");
        // A one-iAI mint at the midpoint costs the average rate, as the linear curve requires.
        assertEq(LinearCurveMath.cost(R0, SLOPE, 4_635e18, 1e18), 13_701_118_673_988_658_588_906, "midpoint");
    }

    // -------------------------------------------------------------------------
    // deriveSlope and lockedAt are inverses, and maxFlooringGap says by how much
    // -------------------------------------------------------------------------

    /// @dev The production anchor's quantum, stated as a number so a change to the formula has
    ///      to come here and say so.
    function test_MaxFlooringGap_GoldenValue() public pure {
        assertEq(LinearCurveMath.maxFlooringGap(CAP), 42_966_451);
        // It is quadratic in the anchor: ten thousand times the supply, a hundred million
        // times the gap. This is why the constructor computes it rather than fixing it.
        assertEq(LinearCurveMath.maxFlooringGap(CAP * 10_000), 4_296_645_000_000_001);
    }

    /**
     * @dev The property the curve constructor's consistency check rests on: compose
     *      `deriveSlope` with `lockedAt` and you land back within one flooring step of the
     *      target you started from. If this ever fails, the two formulas have stopped being
     *      inverses and every published `target` is a number the curve does not account for.
     */
    function testFuzz_DeriveSlopeAndLockedAtAreInverses(uint256 r0, uint256 cap, uint256 target)
        public
        view
    {
        cap = bound(cap, 1e15, 2 ** 100);
        r0 = bound(r0, 0, 1e25);
        uint256 flat = (r0 * cap) / WAD;
        target = bound(target, flat + 1, type(uint160).max);

        uint256 slope;
        try harness.deriveSlope(r0, cap, target) returns (uint256 s) {
            slope = s;
        } catch {
            return; // rejected upstream; nothing to say about it here
        }

        uint256 atCap = LinearCurveMath.lockedAt(r0, slope, cap);
        assertLe(atCap, target, "composing the two can never overshoot the target");
        assertLe(
            target - atCap,
            LinearCurveMath.maxFlooringGap(cap),
            "and never undershoots by more than one flooring step"
        );
    }

    /// @dev The bound is not slack: a target sitting just under the next slope unit uses
    ///      almost all of it. A looser bound would still pass the fuzz above while letting a
    ///      genuinely broken pair of formulas through.
    function test_MaxFlooringGap_IsTight() public pure {
        uint256 quantum = (CAP * CAP) / (2 * WAD * WAD);
        uint256 target = (R0 * CAP) / WAD + (SLOPE + 1) * quantum - 1;

        uint256 slope = LinearCurveMath.deriveSlope(R0, CAP, target);
        uint256 shortfall = target - LinearCurveMath.lockedAt(R0, slope, CAP);

        assertEq(shortfall, quantum - 1, "one wei inside the bound");
        assertLe(shortfall, LinearCurveMath.maxFlooringGap(CAP));
    }

    function test_LockedAt_IsShortOfTargetByExactlyTheKnownGap() public pure {
        uint256 locked = LinearCurveMath.lockedAt(R0, SLOPE, CAP);
        assertEq(locked, TARGET - CAP_SHORTFALL, "lockedAt(cap)");
        assertLt(locked, TARGET, "must undershoot, never overshoot");
    }

    /// @dev cost() ceils each of its two terms, lockedAt() floors. cost must therefore
    ///      sit at or above lockedAt -- never below, which would let the write path
    ///      under-collect relative to the curve's own accounting.
    function test_CostFromZero_IsNeverBelowLockedAt() public pure {
        uint256[4] memory points = [uint256(1), 1e18, 4_635e18, CAP];
        for (uint256 i = 0; i < points.length; i++) {
            uint256 c = LinearCurveMath.cost(R0, SLOPE, 0, points[i]);
            uint256 l = LinearCurveMath.lockedAt(R0, SLOPE, points[i]);
            assertGe(c, l, "cost must cover lockedAt");
            assertLe(c - l, 2, "and exceed it only by the two ceilings");
        }
    }

    function test_Cost_Telescopes() public pure {
        // cost(a->b) + cost(b->c) must cover cost(a->c): splitting can only ever cost more.
        uint256 whole = LinearCurveMath.cost(R0, SLOPE, 0, CAP);
        uint256 first = LinearCurveMath.cost(R0, SLOPE, 0, 4_000e18);
        uint256 second = LinearCurveMath.cost(R0, SLOPE, 4_000e18, CAP - 4_000e18);
        assertGe(first + second, whole, "split must not be cheaper");
        assertLe(first + second - whole, 2, "and only by rounding dust");
    }

    /// @dev The rounding-direction attack: grinding a mint into many pieces must never
    ///      be cheaper than doing it at once. Measured gap for 1000 pieces is 501 wei.
    function test_Cost_SplittingIsNeverCheaper() public pure {
        uint256 pieces = 1_000;
        uint256 chunk = CAP / pieces;
        uint256 s;
        uint256 total;
        for (uint256 i = 0; i < pieces; i++) {
            uint256 d = i == pieces - 1 ? CAP - s : chunk;
            total += LinearCurveMath.cost(R0, SLOPE, s, d);
            s += d;
        }
        uint256 single = LinearCurveMath.cost(R0, SLOPE, 0, CAP);
        assertGe(total, single, "1000-way split must not be cheaper");
        assertEq(total - single, 501, "measured rounding gap");
    }

    function test_Cost_IsMonotonicInSupply() public pure {
        uint256 prev;
        for (uint256 s = 0; s <= CAP - 1e18; s += CAP / 20) {
            uint256 c = LinearCurveMath.cost(R0, SLOPE, s, 1e18);
            assertGe(c, prev, "marginal price must not fall as supply rises");
            prev = c;
        }
    }

    /// @dev The conservative rounding costs at most 1 wei-iAI of quote precision, and buys
    ///      the guarantee that the quote is always affordable. That is the right trade:
    ///      a quote that is one wei short is invisible, a quote that is one wei over
    ///      reverts the user's mint on slippage.
    function test_QuoteForValue_RoundTripsWithinOneWei() public pure {
        uint256[3] memory amounts = [uint256(1e18), 100e18, 2_000e18];
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 delta = LinearCurveMath.cost(R0, SLOPE, 0, amounts[i]);
            uint256 quoted = LinearCurveMath.quoteForValue(R0, SLOPE, 0, delta);
            assertLe(quoted, amounts[i], "quote must never exceed what the value buys");
            assertLe(amounts[i] - quoted, 1, "and must be short by at most one wei");
        }
    }

    function test_QuoteForValue_NeverQuotesMoreThanCostCharges() public pure {
        // The write path re-prices with cost(); a quote that overshot would revert on slippage.
        uint256[4] memory deltas =
            [uint256(649_500e18), 1_000_000e18, 50_000_000e18, 126_000_000e18];
        for (uint256 i = 0; i < deltas.length; i++) {
            uint256 d = LinearCurveMath.quoteForValue(R0, SLOPE, 0, deltas[i]);
            assertLe(LinearCurveMath.cost(R0, SLOPE, 0, d), deltas[i], "quote must be affordable");
        }
    }

    function testFuzz_QuoteForValue_IsAffordable(uint256 s, uint256 delta) public pure {
        s = bound(s, 0, CAP - 1e18);
        // From 1 wei, not 1e18: dust quotes are where an off-by-one in the root would show.
        delta = bound(delta, 1, LinearCurveMath.cost(R0, SLOPE, s, CAP - s));
        uint256 d = LinearCurveMath.quoteForValue(R0, SLOPE, s, delta);
        if (d == 0) return;
        assertLe(LinearCurveMath.cost(R0, SLOPE, s, d), delta, "quoted amount must be affordable");
    }

    function testFuzz_Cost_SplitNeverCheaperThanSingle(uint256 s, uint256 d, uint256 split) public pure {
        s = bound(s, 0, CAP - 2);
        d = bound(d, 2, CAP - s);
        split = bound(split, 1, d - 1);
        uint256 single = LinearCurveMath.cost(R0, SLOPE, s, d);
        uint256 parts = LinearCurveMath.cost(R0, SLOPE, s, split) + LinearCurveMath.cost(R0, SLOPE, s + split, d - split);
        assertGe(parts, single, "splitting must never be cheaper");
    }
}

/// @notice Gives the inlined library an external call frame so reverts can be asserted.
contract LinearCurveMathHarness {
    function deriveSlope(uint256 r0, uint256 cap, uint256 target) external pure returns (uint256) {
        return LinearCurveMath.deriveSlope(r0, cap, target);
    }
}
