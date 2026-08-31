// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {MintCurve} from "../../src/libraries/MintCurve.sol";

/**
 * @notice Pins the curve arithmetic to exact wei values computed independently of the
 *         Solidity implementation. If any of these move, the curve changed — which is
 *         a parameter decision, never an incidental refactor.
 */
contract MintCurveTest is Test {
    uint256 internal constant WAD = 1e18;

    uint256 internal constant R0 = 4_330e18;
    uint256 internal constant CAP = 9_270e18;
    uint256 internal constant TARGET = 127_000_000e18;

    uint256 internal constant SLOPE = 2_021_598_247_004_348_741;
    uint256 internal constant R1 = 23_070_215_749_730_312_829_070;

    /// @dev `slope` is floored, so the closed form lands this many wei below TARGET.
    ///      Nothing may assert `lockedAt(cap) == target`; this is the exact gap.
    uint256 internal constant CAP_SHORTFALL = 37_260_550;

    function test_DeriveSlope_MatchesGoldenValue() public pure {
        assertEq(MintCurve.deriveSlope(R0, CAP, TARGET), SLOPE, "slope");
    }

    function test_DeriveSlope_EndRateMatchesProductDocs() public pure {
        uint256 slope = MintCurve.deriveSlope(R0, CAP, TARGET);
        // rate(cap) = R0 + slope*cap/WAD -- the product docs quote 23,070.2157497303
        assertEq(R0 + (slope * CAP) / WAD, R1, "R1");
        // avg = target/cap -- the docs quote 13,700.1079
        assertEq((TARGET * WAD) / CAP, 13_700_107_874_865_156_418_554, "avg");
    }

    /// @dev MintCurve is an internal library, so its bodies are inlined and
    ///      `vm.expectRevert` has no call frame to latch onto. Route through a harness.
    function test_DeriveSlope_RejectsBadParameters() public {
        CurveHarness h = new CurveHarness();

        vm.expectRevert(MintCurve.InvalidCurveCap.selector);
        h.deriveSlope(R0, 0, TARGET);

        vm.expectRevert(MintCurve.InvalidCurveCap.selector);
        h.deriveSlope(R0, uint256(type(uint128).max) + 1, TARGET);

        // A target at or below the flat portion leaves no room for the slope.
        vm.expectRevert(MintCurve.InvalidCurveTarget.selector);
        h.deriveSlope(R0, CAP, 1e18);

        vm.expectRevert(MintCurve.InvalidCurveTarget.selector);
        h.deriveSlope(R0, CAP, (R0 * CAP) / WAD);
    }

    function test_Cost_GoldenVectors() public pure {
        assertEq(MintCurve.cost(R0, SLOPE, 0, 1), 4_331, "1 wei");
        assertEq(MintCurve.cost(R0, SLOPE, 0, 1e18), 4_331_010_799_123_502_174_371, "1 iAI");
        assertEq(MintCurve.cost(R0, SLOPE, 0, 100e18), 443_107_991_235_021_743_705_000, "100 iAI");
        assertEq(MintCurve.cost(R0, SLOPE, 0, 2_000e18), 12_703_196_494_008_697_482_000_000, "2000 iAI");
        assertEq(MintCurve.cost(R0, SLOPE, 0, CAP), 126_999_999_999_999_999_962_739_450, "full cap");
        // A one-iAI mint at the midpoint costs the average rate, as the linear curve requires.
        assertEq(MintCurve.cost(R0, SLOPE, 4_635e18, 1e18), 13_701_118_673_988_658_588_906, "midpoint");
    }

    function test_LockedAt_IsShortOfTargetByExactlyTheKnownGap() public pure {
        uint256 locked = MintCurve.lockedAt(R0, SLOPE, CAP);
        assertEq(locked, TARGET - CAP_SHORTFALL, "lockedAt(cap)");
        assertLt(locked, TARGET, "must undershoot, never overshoot");
    }

    /// @dev cost() ceils each of its two terms, lockedAt() floors. cost must therefore
    ///      sit at or above lockedAt -- never below, which would let the write path
    ///      under-collect relative to the curve's own accounting.
    function test_CostFromZero_IsNeverBelowLockedAt() public pure {
        uint256[4] memory points = [uint256(1), 1e18, 4_635e18, CAP];
        for (uint256 i = 0; i < points.length; i++) {
            uint256 c = MintCurve.cost(R0, SLOPE, 0, points[i]);
            uint256 l = MintCurve.lockedAt(R0, SLOPE, points[i]);
            assertGe(c, l, "cost must cover lockedAt");
            assertLe(c - l, 2, "and exceed it only by the two ceilings");
        }
    }

    function test_Cost_Telescopes() public pure {
        // cost(a->b) + cost(b->c) must cover cost(a->c): splitting can only ever cost more.
        uint256 whole = MintCurve.cost(R0, SLOPE, 0, CAP);
        uint256 first = MintCurve.cost(R0, SLOPE, 0, 4_000e18);
        uint256 second = MintCurve.cost(R0, SLOPE, 4_000e18, CAP - 4_000e18);
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
            total += MintCurve.cost(R0, SLOPE, s, d);
            s += d;
        }
        uint256 single = MintCurve.cost(R0, SLOPE, 0, CAP);
        assertGe(total, single, "1000-way split must not be cheaper");
        assertEq(total - single, 501, "measured rounding gap");
    }

    function test_Cost_IsMonotonicInSupply() public pure {
        uint256 prev;
        for (uint256 s = 0; s <= CAP - 1e18; s += CAP / 20) {
            uint256 c = MintCurve.cost(R0, SLOPE, s, 1e18);
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
            uint256 delta = MintCurve.cost(R0, SLOPE, 0, amounts[i]);
            uint256 quoted = MintCurve.quoteForValue(R0, SLOPE, 0, delta);
            assertLe(quoted, amounts[i], "quote must never exceed what the value buys");
            assertLe(amounts[i] - quoted, 1, "and must be short by at most one wei");
        }
    }

    function test_QuoteForValue_NeverQuotesMoreThanCostCharges() public pure {
        // The write path re-prices with cost(); a quote that overshot would revert on slippage.
        uint256[4] memory deltas =
            [uint256(649_500e18), 1_000_000e18, 50_000_000e18, 126_000_000e18];
        for (uint256 i = 0; i < deltas.length; i++) {
            uint256 d = MintCurve.quoteForValue(R0, SLOPE, 0, deltas[i]);
            assertLe(MintCurve.cost(R0, SLOPE, 0, d), deltas[i], "quote must be affordable");
        }
    }

    function testFuzz_QuoteForValue_IsAffordable(uint256 s, uint256 delta) public pure {
        s = bound(s, 0, CAP - 1e18);
        delta = bound(delta, 1e18, MintCurve.cost(R0, SLOPE, s, CAP - s));
        uint256 d = MintCurve.quoteForValue(R0, SLOPE, s, delta);
        if (d == 0) return;
        assertLe(MintCurve.cost(R0, SLOPE, s, d), delta, "quoted amount must be affordable");
    }

    function testFuzz_Cost_SplitNeverCheaperThanSingle(uint256 s, uint256 d, uint256 split) public pure {
        s = bound(s, 0, CAP - 2);
        d = bound(d, 2, CAP - s);
        split = bound(split, 1, d - 1);
        uint256 single = MintCurve.cost(R0, SLOPE, s, d);
        uint256 parts = MintCurve.cost(R0, SLOPE, s, split) + MintCurve.cost(R0, SLOPE, s + split, d - split);
        assertGe(parts, single, "splitting must never be cheaper");
    }
}

/// @notice Gives the inlined library an external call frame so reverts can be asserted.
contract CurveHarness {
    function deriveSlope(uint256 r0, uint256 cap, uint256 target) external pure returns (uint256) {
        return MintCurve.deriveSlope(r0, cap, target);
    }
}
