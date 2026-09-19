// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {CurveConformanceTest} from "./CurveConformance.t.sol";
import {ExponentialTable} from "./ExponentialTable.sol";
import {IMintCurve} from "../../../src/interfaces/IMintCurve.sol";
import {ExponentialMintCurve} from "../../../src/curves/ExponentialMintCurve.sol";

/**
 * @title ExponentialMintCurveTest
 * @notice The production curve -- the exponential step table -- as a deployed contract.
 *
 * @dev Two jobs. Inheriting `CurveConformanceTest` runs the shared behavioural contract
 *      against it, which proves it is a well-formed curve. The golden vectors are the second
 *      job: they pin that it is the *right* curve. **None of these numbers may be edited.**
 *      They were computed outside this codebase with `mpmath` at 80 digits, independently of
 *      the `decimal`-based generator that produced the table, and the two agreed to the wei
 *      on every entry. Changing one to make a test pass converts an independent check into a
 *      copy of whatever the code now does.
 *
 *      The table itself comes from `ExponentialTable.sol`, generated from the deployment
 *      record; `test/script/Deploy.t.sol` asserts the two are identical.
 */
contract ExponentialMintCurveTest is CurveConformanceTest {
    uint256 internal constant W = 25e18;
    /// @dev The supply the exponent is normalised against: a scale in the formula, not a
    ///      ceiling of anything.
    uint256 internal constant TARGET = 9270e18;
    /// @dev The supply ceiling, a constructor argument. Not a multiple of the bucket width:
    ///      the table's 371 buckets cover 9,275 iAI and the last one is used for 20 of its 25.
    uint256 internal constant TOP = 9270e18;
    uint256 internal constant COUNT = 371;
    uint256 internal constant TABLE_END = COUNT * W;

    uint256 internal constant BASE = 586e18;
    uint256 internal constant EXPONENT = 4.711e18;

    // --- golden vectors, computed with mpmath outside this codebase ---
    uint256 internal constant P0 = 593_492_603_713_227_388_873;
    uint256 internal constant P1 = 601_081_007_956_153_530_058;
    /// @dev Bucket [2000, 2025): the first public mint after the 2,000 iAI pre-mint.
    uint256 internal constant P80 = 1_639_951_145_958_071_970_563;
    uint256 internal constant P185 = 6_225_709_974_284_080_163_438;
    uint256 internal constant P369 = 64_482_930_205_520_036_911_513;
    /// @dev The last bucket, [9250, 9275), of which only [9250, 9270) is issuable.
    uint256 internal constant P370 = 65_307_409_799_884_647_803_034;

    uint256 internal constant COST_PREMINT = 2_046_100_158_323_122_128_597_800;
    /// @dev The whole issuable supply, 0 to 9,270 iAI: ~127.84M 0G.
    uint256 internal constant COST_TO_TOP = 127_838_782_672_610_268_612_331_555;
    /// @dev [24, 26): one iAI in bucket 0 and one in bucket 1.
    uint256 internal constant COST_ACROSS_FIRST_BOUNDARY = 1_194_573_611_669_380_918_931;

    ExponentialMintCurve internal curve;

    function setUp() public {
        curve = new ExponentialMintCurve(W, ExponentialTable.prices(), TOP, BASE, EXPONENT, TARGET);
    }

    // --- conformance hooks ---

    function _curve() internal view override returns (IMintCurve) {
        return curve;
    }

    /// @dev Both sides of the first boundary, the pre-mint edge, the start of the clipped last
    ///      bucket and the top: the places a step function can go wrong. Kept short because
    ///      the split test is quadratic in it.
    function _supplies() internal pure override returns (uint256[] memory s) {
        s = new uint256[](11);
        s[0] = 0;
        s[1] = 1;
        s[2] = W - 1;
        s[3] = W;
        s[4] = W + 1;
        s[5] = 2000e18;
        s[6] = TOP / 2;
        s[7] = TOP - W;
        s[8] = TABLE_END - W;
        s[9] = TOP - 1;
        s[10] = TOP;
    }

    function _amounts() internal pure override returns (uint256[] memory d) {
        d = new uint256[](7);
        d[0] = 1;
        d[1] = 1e12;
        d[2] = 1e18;
        d[3] = W;
        d[4] = W + 1;
        d[5] = 100e18;
        d[6] = 1000e18;
    }

    // --- the curve is the one the product promised ---

    function test_Constructor_KeepsItsProvenance() public view {
        assertEq(curve.bucketWidth(), W);
        assertEq(curve.bucketCount(), COUNT);
        assertEq(curve.top(), TOP, "the ceiling it was given");
        assertEq(curve.maxSafeSupply(), TOP, "the ceiling is the declared top");
        assertEq(curve.bucketCount() * curve.bucketWidth(), TABLE_END, "371 buckets of 25 iAI cover 9,275");
        assertEq(curve.base(), BASE);
        assertEq(curve.exponent(), EXPONENT);
        assertEq(curve.target(), TARGET);
        assertEq(curve.top(), TARGET, "the ceiling is the normalising supply itself");
    }

    /// @dev The table is exactly as long as the ceiling needs: `ceil(9270 / 25)` buckets, the
    ///      last of them 5 iAI longer than the issuable supply.
    function test_Table_IsSizedToCoverTheCeiling() public view {
        assertGe(TABLE_END, TOP, "the table covers the ceiling");
        assertLt(TABLE_END - TOP, W, "and runs less than a bucket past it");
        assertEq(TABLE_END - TOP, 5e18);
        assertEq(ExponentialTable.TOP, TOP, "the mirror records the ceiling it was sized for");
    }

    function test_Table_GoldenVectors() public view {
        assertEq(curve.priceAt(0), P0, "586 0G at the origin, times e^(4.711 * 25/9270)");
        assertEq(curve.priceAt(1), P1);
        assertEq(curve.priceAt(80), P80, "the first public mint after the 2,000 pre-mint");
        assertEq(curve.priceAt(185), P185, "halfway to the normalising supply");
        assertEq(curve.priceAt(369), P369);
        assertEq(curve.priceAt(370), P370, "the last bucket, priced at its upper bound of 9,275: ~65,307 0G");

        uint128[] memory table = curve.prices();
        assertEq(table.length, COUNT);
        assertEq(uint256(table[80]), P80, "the whole-table view agrees with priceAt");
    }

    function test_Cost_GoldenVectors() public view {
        assertEq(curve.cost(0, 1), 594, "1 wei: the smallest charge on the curve");
        assertEq(curve.cost(0, 1e18), P0, "one whole iAI in the first bucket is the bucket price");
        assertEq(curve.cost(0, 2000e18), COST_PREMINT, "the foundation's pre-mint, ~2.05M 0G");
        assertEq(curve.cost(2000e18, 1e18), P80, "the first public mint");
        assertEq(curve.cost(24e18, 2e18), COST_ACROSS_FIRST_BOUNDARY, "one iAI on each side of a boundary");
        assertEq(curve.cost(TOP - 20e18, 20e18), 20 * P370, "the issuable part of the last bucket, flat");
        assertEq(curve.cost(TOP - 25e18, 20e18), 5 * P369 + 15 * P370, "20 iAI across the last boundary");
        assertEq(curve.cost(0, TOP), COST_TO_TOP, "the whole issuable supply, ~127.84M 0G");
    }

    /// @dev What a step function is: flat inside a bucket, a jump at its edge. The jump on
    ///      the production table is the same everywhere -- a pure exponential rises by the
    ///      same factor per bucket, e^(4.711 * 25/9270) = 1.01279 -- and never exceeds 1.28%,
    ///      which is what makes a race for the last few units of a cheaper bucket not worth
    ///      running.
    function test_Cost_IsFlatWithinABucketAndStepsAtItsEdge() public view {
        assertEq(curve.cost(0, 1e18), curve.cost(24e18, 1e18), "flat within bucket 0");
        assertEq(curve.cost(25e18, 1e18), P1, "bucket 1 prices at its own upper bound");
        assertGt(P1, P0, "and it is dearer");

        uint128[] memory table = ExponentialTable.prices();
        for (uint256 i = 1; i < table.length; i++) {
            assertLe(uint256(table[i]) * 10_000, uint256(table[i - 1]) * 10_128, "adjacent buckets differ by <= 1.28%");
            assertGe(
                uint256(table[i]) * 10_000, uint256(table[i - 1]) * 10_127, "and by >= 1.27%: the ratio is constant"
            );
        }
    }

    /// @dev The ceiling is the declared top, not the end of the table: the last 5 iAI the
    ///      table prices are not for sale. The vault never asks: it checks `maxSafeSupply()`
    ///      before pricing.
    function test_Cost_RevertsPastTheCeiling_NotTheTable() public {
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.SupplyOutOfDomain.selector, TOP + 1e18, TOP));
        curve.cost(TOP - 25e18, 26e18);

        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.SupplyOutOfDomain.selector, TOP + 1, TOP));
        curve.cost(TOP, 1);

        // Inside the table but past the ceiling: still refused.
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.SupplyOutOfDomain.selector, TABLE_END, TOP));
        curve.cost(TOP - 20e18, 25e18);

        assertEq(curve.cost(TOP, 0), 0, "nothing costs nothing, even at the edge");
        assertEq(curve.cost(TOP - 1, 1), 65_308, "the last wei below the ceiling is priceable");
    }

    /// @dev Past the top the two pricing functions answer in different shapes on purpose, and
    ///      neither answer is a statement about where the domain ends: `quoteForValue` returns
    ///      the same zero it gives a budget that buys nothing. `maxSafeSupply` is the only
    ///      thing that tells a caller the edge.
    function test_PastTheTop_TheTwoFunctionsDisagreeByDesign() public {
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.SupplyOutOfDomain.selector, TOP + 1e18 + 1, TOP));
        curve.cost(TOP + 1e18, 1);

        assertEq(curve.quoteForValue(TOP + 1e18, 1e30), 0, "off the domain reads as zero");
        assertEq(curve.quoteForValue(TOP + 2e18, 1e30), 0, "even where the table still has a price");
        assertEq(curve.quoteForValue(0, 0), 0, "and so does an empty budget");
        assertEq(curve.maxSafeSupply(), TOP, "only this separates the two");
    }

    /// @dev `priceAt` is a helper for charts and the deployment checker, so an index past the
    ///      table is a caller's mistake rather than a state the vault can reach. It still
    ///      names the size it was measured against instead of leaving the array to panic.
    function test_PriceAt_RevertsPastTheTable() public {
        assertEq(curve.priceAt(COUNT - 1), P370, "the last bucket reads");

        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.BucketOutOfRange.selector, COUNT, COUNT));
        curve.priceAt(COUNT);

        vm.expectRevert(
            abi.encodeWithSelector(ExponentialMintCurve.BucketOutOfRange.selector, type(uint256).max, COUNT)
        );
        curve.priceAt(type(uint256).max);
    }

    // --- the inverse ---

    /// @dev Inside a flat bucket the inverse is exact integer division, so a quote is not just
    ///      affordable but *maximal*: one more wei of iAI would exceed the budget. The
    ///      round trip through `cost` is exact whenever every price exceeds 1e18 wei-0G,
    ///      because the single ceiling then loses less than one unit of iAI -- true of this
    ///      table by a factor of almost six hundred.
    function test_Quote_IsMaximalAndInvertsCostExactly() public view {
        uint256[] memory s = _supplies();
        uint256[] memory d = _amounts();

        for (uint256 i = 0; i < s.length; i++) {
            for (uint256 j = 0; j < d.length; j++) {
                if (s[i] + d[j] > TOP) continue;
                uint256 c = curve.cost(s[i], d[j]);
                assertEq(curve.quoteForValue(s[i], c), d[j], "quote inverts cost exactly");
            }
        }

        uint256[6] memory budgets = [uint256(594), 1e18, 600e18, 1_000_000e18, COST_PREMINT, 100_000_000e18];
        for (uint256 i = 0; i < s.length; i++) {
            for (uint256 j = 0; j < budgets.length; j++) {
                uint256 amount = curve.quoteForValue(s[i], budgets[j]);
                if (amount == 0) continue;
                assertLe(curve.cost(s[i], amount), budgets[j], "affordable");
                if (s[i] + amount < TOP) {
                    assertGt(curve.cost(s[i], amount + 1), budgets[j], "and maximal");
                }
            }
        }

        assertEq(curve.quoteForValue(0, COST_PREMINT), 2000e18, "the pre-mint budget buys exactly the pre-mint");
        assertEq(curve.quoteForValue(0, 593), 0, "a wei short of the first price buys nothing");
        assertEq(curve.quoteForValue(0, 594), 1, "the first price buys the first wei");
    }

    /// @dev The walk clips the last bucket to the ceiling. Without the clip a budget that
    ///      covers the whole last bucket would be answered with the whole bucket, 5 iAI past
    ///      what the vault will issue -- a quote `mint` then refuses.
    function test_Quote_ClipsTheLastBucketToTheCeiling() public view {
        uint256 lastStart = TABLE_END - W; // 9,250: the last bucket begins here

        assertEq(curve.quoteForValue(lastStart, 1e30), TOP - lastStart, "a huge budget buys to the ceiling, not the bucket's end");
        assertEq(curve.quoteForValue(lastStart, 25 * P370), 20e18, "the price of the whole bucket buys only its issuable 20 iAI");
        assertEq(curve.quoteForValue(lastStart, 20 * P370), 20e18, "exactly the issuable part's price buys exactly that");
        assertEq(curve.quoteForValue(lastStart, 20 * P370 - 1), 20e18 - 1, "a wei less, and the floor gives up a wei of iAI");
        assertEq(curve.quoteForValue(lastStart, P370), 1e18, "inside the clipped bucket the inverse is still exact division");

        // Starting below the last bucket and reaching into it: whole buckets are taken in
        // full, the last one only up to the ceiling.
        assertEq(curve.quoteForValue(lastStart - W, 1e30), TOP - lastStart + W, "two buckets, the second clipped");
        assertEq(curve.quoteForValue(lastStart - W, 25 * P369 + 20 * P370), TOP - lastStart + W);
        assertEq(curve.quoteForValue(lastStart - W, 25 * P369 + 25 * P370), TOP - lastStart + W, "and no more for a bigger budget");
        assertEq(curve.quoteForValue(0, type(uint128).max), TOP, "from the origin, the whole issuable supply");

        // Nothing quoted reaches past the ceiling, and everything quoted is priceable.
        uint256[] memory s = _supplies();
        for (uint256 i = 0; i < s.length; i++) {
            uint256 amount = curve.quoteForValue(s[i], type(uint128).max);
            assertLe(s[i] + amount, TOP, "never past the ceiling");
            if (s[i] < TOP) assertEq(s[i] + amount, TOP, "and a huge budget always reaches it");
            curve.cost(s[i], amount); // must not revert
        }
    }

    function test_Quote_SaturatesAtTheTop() public view {
        assertEq(curve.quoteForValue(0, type(uint128).max), TOP, "a huge budget buys the whole issuable supply");
        assertEq(curve.quoteForValue(0, type(uint256).max), TOP, "even one too large to scale");
        assertEq(curve.quoteForValue(0, COST_TO_TOP), TOP, "exactly the total buys the total");
        assertEq(curve.quoteForValue(TOP - 5e18, 1e30), 5e18, "near the top, only the last 5 iAI remain");
        assertEq(curve.quoteForValue(TOP, 1e30), 0, "nothing is for sale past the top");
        assertEq(curve.quoteForValue(TOP - 1, 1e30), 1);
    }

    // --- the constructor is the only chance to reject a malformed table ---

    function test_Constructor_RejectsMalformedTables() public {
        uint128[] memory empty = new uint128[](0);
        vm.expectRevert(ExponentialMintCurve.EmptyTable.selector);
        new ExponentialMintCurve(W, empty, TOP, BASE, EXPONENT, TARGET);

        uint128[] memory one = new uint128[](1);
        one[0] = uint128(P0);
        vm.expectRevert(ExponentialMintCurve.ZeroBucketWidth.selector);
        new ExponentialMintCurve(0, one, W, BASE, EXPONENT, 0);

        uint128[] memory free = new uint128[](2);
        free[1] = uint128(P0);
        vm.expectRevert(ExponentialMintCurve.CurveChargesNothing.selector);
        new ExponentialMintCurve(W, free, 2 * W, BASE, EXPONENT, 0);

        uint128[] memory falling = new uint128[](3);
        falling[0] = uint128(P1);
        falling[1] = uint128(P1);
        falling[2] = uint128(P0);
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.TableNotMonotonic.selector, 2));
        new ExponentialMintCurve(W, falling, 3 * W, BASE, EXPONENT, 0);

        uint128[] memory two = new uint128[](2);
        two[0] = uint128(P0);
        two[1] = uint128(P1);
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.BucketTooWide.selector, 2 ** 127 + 1));
        new ExponentialMintCurve(2 ** 127 + 1, two, 2 ** 127, BASE, EXPONENT, 0);
    }

    /// @dev The ceiling has to be a real number the table prices: non-zero, within the vault's
    ///      absolute bound, covered by the table, and not so far below the table's end that a
    ///      whole bucket could never be reached. And `target`, provenance though it is, may
    ///      not point past it.
    function test_Constructor_RejectsACeilingTheTableDoesNotFit() public {
        uint128[] memory two = new uint128[](2);
        two[0] = uint128(P0);
        two[1] = uint128(P1);

        vm.expectRevert(ExponentialMintCurve.ZeroCeiling.selector);
        new ExponentialMintCurve(W, two, 0, BASE, EXPONENT, 0);

        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.CeilingTooTall.selector, 2 ** 127 + 1));
        new ExponentialMintCurve(2 ** 127, two, 2 ** 127 + 1, BASE, EXPONENT, 0);

        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.CeilingBeyondTable.selector, 2 * W + 1, 2 * W));
        new ExponentialMintCurve(W, two, 2 * W + 1, BASE, EXPONENT, 0);

        // A ceiling of exactly one bucket leaves the second bucket unreachable in full.
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.TableLongerThanCeiling.selector, W, 2 * W));
        new ExponentialMintCurve(W, two, W, BASE, EXPONENT, 0);

        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.TargetBeyondCeiling.selector, W + 2, W + 1));
        new ExponentialMintCurve(W, two, W + 1, BASE, EXPONENT, W + 2);
    }

    /// @dev Every ceiling inside the last bucket is accepted -- the bucket's end included, and
    ///      a single wei past its start -- and it is the ceiling, not the table's end, that
    ///      every function answers to.
    function test_Constructor_AcceptsAnyCeilingInsideTheLastBucket() public {
        uint128[] memory two = new uint128[](2);
        two[0] = uint128(P0);
        two[1] = uint128(P1);

        uint256[3] memory tops = [W + 1, W + 7e18, 2 * W];
        for (uint256 i = 0; i < tops.length; i++) {
            ExponentialMintCurve c = new ExponentialMintCurve(W, two, tops[i], BASE, EXPONENT, tops[i]);
            assertEq(c.maxSafeSupply(), tops[i]);
            assertEq(c.bucketCount(), 2, "the table is unchanged by where the ceiling sits");
            assertEq(c.cost(0, tops[i]), _ceilDiv(P0 * W + P1 * (tops[i] - W), 1e18), "priced up to the ceiling");
            assertEq(c.quoteForValue(0, 1e40), tops[i], "and quoted up to it");
            assertEq(c.quoteForValue(W, 1e40), tops[i] - W);
            vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.SupplyOutOfDomain.selector, tops[i] + 1, tops[i]));
            c.cost(0, tops[i] + 1);
        }
    }

    /// @dev Equal neighbours are allowed: a flat run is a legitimate shape (and what the
    ///      simulation's random tables produce), only a fall is not. And the smallest table
    ///      that constructs still prices every wei of its domain.
    function test_Constructor_AcceptsAFlatTableAndTheSmallestOne() public {
        uint128[] memory flat = new uint128[](3);
        flat[0] = 1;
        flat[1] = 1;
        flat[2] = 1;
        ExponentialMintCurve tiny = new ExponentialMintCurve(1, flat, 3, 1, 0, 3);
        assertEq(tiny.maxSafeSupply(), 3);
        assertEq(tiny.cost(0, 3), 1, "3 wei at 1 wei-0G per iAI is 3e-18 0G, rounded up to a wei");
        assertEq(tiny.cost(2, 1), 1, "a single wei is never free");
        assertEq(tiny.quoteForValue(0, 1), 3, "and a wei of 0G buys the whole tiny table");
    }

    // --- views for tooling ---

    function test_Views_BucketRateAndLocked() public {
        assertEq(curve.bucketOf(0), 0);
        assertEq(curve.bucketOf(W - 1), 0);
        assertEq(curve.bucketOf(W), 1);
        assertEq(curve.bucketOf(2000e18), 80);
        assertEq(curve.bucketOf(TOP - 1), 370);
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.SupplyOutOfDomain.selector, TOP, TOP));
        curve.bucketOf(TOP);

        assertEq(curve.rateAt(2000e18), P80, "the marginal price the first public minter sees");
        assertEq(curve.rateAt(TOP - 1), P370);
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.SupplyOutOfDomain.selector, TOP, TOP));
        curve.rateAt(TOP);

        assertEq(curve.lockedAt(0), 0);
        assertEq(curve.lockedAt(W), P0 * 25, "a whole first bucket, exactly");
        assertEq(curve.lockedAt(TOP), COST_TO_TOP, "the whole issuable supply is an exact multiple of a wei here");
        // `lockedAt` floors and `cost` ceils; they may differ by one wei and never more.
        assertLe(curve.cost(0, 2000e18 + 1) - curve.lockedAt(2000e18 + 1), 1);
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.SupplyOutOfDomain.selector, TOP + 1, TOP));
        curve.lockedAt(TOP + 1);
    }

    /// @dev Not a pass/fail on a number that will drift with the compiler, but a ceiling that
    ///      says the design holds: a mint inside one bucket is one storage read, and the
    ///      worst case -- pricing the entire issuable supply in one call -- stays far inside
    ///      a block.
    function test_Gas_ScalesWithBucketsTouchedNotWithSupply() public view {
        uint256 g = gasleft();
        curve.cost(2000e18, 1e18);
        uint256 oneBucket = g - gasleft();

        g = gasleft();
        curve.cost(9_000e18, 1e18);
        uint256 oneBucketHighUp = g - gasleft();

        g = gasleft();
        curve.cost(0, TOP);
        uint256 wholeTable = g - gasleft();

        assertLt(oneBucket, 15_000, "one bucket: a couple of cold reads");
        assertLe(oneBucketHighUp, oneBucket + 100, "and no dearer higher up the table");
        assertLt(wholeTable, 700_000, "the whole table: ~186 packed slots");
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
