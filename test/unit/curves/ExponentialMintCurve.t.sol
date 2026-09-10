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
 *      on every one of the 371 entries. Changing one to make a test pass converts an
 *      independent check into a copy of whatever the code now does.
 *
 *      The table itself comes from `ExponentialTable.sol`, generated from the deployment
 *      record; `test/script/Deploy.t.sol` asserts the two are identical.
 */
contract ExponentialMintCurveTest is CurveConformanceTest {
    uint256 internal constant WAD = 1e18;

    uint256 internal constant W = 25e18;
    uint256 internal constant CAP = 9270e18;
    uint256 internal constant TOP = 9275e18;
    uint256 internal constant COUNT = 371;

    uint256 internal constant BASE = 3237.4e18;
    uint256 internal constant EXPONENT = 3.419e18;
    uint256 internal constant TARGET = 9270e18;

    // --- golden vectors, computed with mpmath outside this codebase ---
    uint256 internal constant P0 = 3_237_400_217_108_237_297_865;
    uint256 internal constant P1 = 3_237_401_736_866_306_058_154;
    /// @dev Bucket [2000, 2025): the first public mint after the 2,000 iAI pre-mint.
    uint256 internal constant P80 = 3_354_860_922_511_919_601_349;
    uint256 internal constant P185 = 4_984_376_163_786_596_996_127;
    /// @dev The last bucket, [9250, 9275).
    uint256 internal constant P370 = 99_415_286_098_687_872_720_911;

    uint256 internal constant COST_PREMINT = 6_532_351_967_907_283_100_620_550;
    uint256 internal constant COST_LAST_20 = 1_988_305_721_973_757_454_418_220;
    uint256 internal constant COST_TO_CAP = 128_170_725_509_982_551_114_746_970;
    uint256 internal constant COST_WHOLE_TABLE = 128_667_801_940_475_990_478_351_525;
    /// @dev [24, 26): one iAI in bucket 0 and one in bucket 1.
    uint256 internal constant COST_ACROSS_FIRST_BOUNDARY = 6_474_801_953_974_543_356_019;

    ExponentialMintCurve internal curve;

    function setUp() public {
        curve = new ExponentialMintCurve(W, ExponentialTable.prices(), BASE, EXPONENT, TARGET);
    }

    // --- conformance hooks ---

    function _curve() internal view override returns (IMintCurve) {
        return curve;
    }

    /// @dev Both sides of the first boundary, the pre-mint edge, and the top: the places a
    ///      step function can go wrong. Kept short because the split test is quadratic in it.
    function _supplies() internal pure override returns (uint256[] memory s) {
        s = new uint256[](11);
        s[0] = 0;
        s[1] = 1;
        s[2] = W - 1;
        s[3] = W;
        s[4] = W + 1;
        s[5] = 2000e18;
        s[6] = CAP / 2;
        s[7] = CAP - 1;
        s[8] = CAP;
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
        assertEq(curve.top(), TOP, "371 buckets of 25 iAI");
        assertEq(curve.maxSafeSupply(), TOP, "the domain is the table, not an arithmetic bound");
        assertEq(curve.base(), BASE);
        assertEq(curve.exponent(), EXPONENT);
        assertEq(curve.target(), TARGET);
        assertGe(curve.top(), CAP, "the table covers the vault's cap");
        assertLt(curve.top() - CAP, W, "and overshoots it by less than one bucket");
    }

    function test_Table_GoldenVectors() public view {
        assertEq(curve.priceAt(0), P0, "3,237.4 0G at the origin, plus e^(3.419 * (25/9270)^3)");
        assertEq(curve.priceAt(1), P1);
        assertEq(curve.priceAt(80), P80, "the first public mint after the 2,000 pre-mint");
        assertEq(curve.priceAt(185), P185, "the middle of the table");
        assertEq(curve.priceAt(370), P370, "the last bucket: ~99,415 0G, 30.7x the base");

        uint128[] memory table = curve.prices();
        assertEq(table.length, COUNT);
        assertEq(uint256(table[80]), P80, "the whole-table view agrees with priceAt");
    }

    function test_Cost_GoldenVectors() public view {
        assertEq(curve.cost(0, 1), 3238, "1 wei: the smallest charge on the curve");
        assertEq(curve.cost(0, 1e18), P0, "one whole iAI in the first bucket is the bucket price");
        assertEq(curve.cost(0, 2000e18), COST_PREMINT, "the foundation's pre-mint, ~6.53M 0G");
        assertEq(curve.cost(2000e18, 1e18), P80, "the first public mint");
        assertEq(curve.cost(24e18, 2e18), COST_ACROSS_FIRST_BOUNDARY, "one iAI on each side of a boundary");
        assertEq(curve.cost(9250e18, 20e18), COST_LAST_20, "the last 20 iAI under the cap");
        assertEq(curve.cost(0, CAP), COST_TO_CAP, "the whole curve to the cap, ~128.17M 0G");
        assertEq(curve.cost(0, TOP), COST_WHOLE_TABLE, "the whole table, ~128.67M 0G");
    }

    /// @dev What a step function is: flat inside a bucket, a jump at its edge. The jump on
    ///      the production table never exceeds 2.81%, which is what makes a race for the last
    ///      few units of a cheaper bucket not worth running.
    function test_Cost_IsFlatWithinABucketAndStepsAtItsEdge() public view {
        assertEq(curve.cost(0, 1e18), curve.cost(24e18, 1e18), "flat within bucket 0");
        assertEq(curve.cost(25e18, 1e18), P1, "bucket 1 prices at its own upper bound");
        assertGt(P1, P0, "and it is dearer");

        uint128[] memory table = ExponentialTable.prices();
        for (uint256 i = 1; i < table.length; i++) {
            assertLe(uint256(table[i]) * 10_000, uint256(table[i - 1]) * 10_281, "adjacent buckets differ by <= 2.81%");
        }
    }

    /// @dev The table has a real edge, and it is the curve's job to say so rather than to
    ///      price a supply nobody has decided a price for. The vault never reaches it: its cap
    ///      is refused above `maxSafeSupply()`, and `mint` checks the cap before pricing.
    function test_Cost_RevertsPastTheTable() public {
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.SupplyOutOfDomain.selector, TOP + 1e18, TOP));
        curve.cost(9250e18, 26e18);

        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.SupplyOutOfDomain.selector, TOP + 1, TOP));
        curve.cost(TOP, 1);

        assertEq(curve.cost(TOP, 0), 0, "nothing costs nothing, even at the edge");
        assertEq(curve.cost(TOP - 1, 1), 99_416, "the last wei of the table is priceable");
    }

    // --- the inverse ---

    /// @dev Inside a flat bucket the inverse is exact integer division, so a quote is not just
    ///      affordable but *maximal*: one more wei of iAI would exceed the budget. The
    ///      round trip through `cost` is exact whenever every price exceeds 1e18 wei-0G,
    ///      because the single ceiling then loses less than one unit of iAI -- true of this
    ///      table by a factor of three thousand.
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

        uint256[6] memory budgets = [uint256(3238), 1e18, 3300e18, 1_000_000e18, COST_PREMINT, 100_000_000e18];
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
        assertEq(curve.quoteForValue(0, 3237), 0, "a wei short of the first price buys nothing");
        assertEq(curve.quoteForValue(0, 3238), 1, "the first price buys the first wei");
    }

    function test_Quote_SaturatesAtTheTop() public view {
        assertEq(curve.quoteForValue(0, type(uint128).max), TOP, "a huge budget buys the whole table");
        assertEq(curve.quoteForValue(0, type(uint256).max), TOP, "even one too large to scale");
        assertEq(curve.quoteForValue(0, COST_WHOLE_TABLE), TOP, "exactly the table's total buys the table");
        assertEq(curve.quoteForValue(CAP, 1e30), TOP - CAP, "past the cap, only the table's last 5 iAI remain");
        assertEq(curve.quoteForValue(TOP, 1e30), 0, "nothing is for sale past the top");
        assertEq(curve.quoteForValue(TOP - 1, 1e30), 1);
    }

    // --- the constructor is the only chance to reject a malformed table ---

    function test_Constructor_RejectsMalformedTables() public {
        uint128[] memory empty = new uint128[](0);
        vm.expectRevert(ExponentialMintCurve.EmptyTable.selector);
        new ExponentialMintCurve(W, empty, BASE, EXPONENT, TARGET);

        uint128[] memory one = new uint128[](1);
        one[0] = uint128(P0);
        vm.expectRevert(ExponentialMintCurve.ZeroBucketWidth.selector);
        new ExponentialMintCurve(0, one, BASE, EXPONENT, 0);

        uint128[] memory free = new uint128[](2);
        free[1] = uint128(P0);
        vm.expectRevert(ExponentialMintCurve.CurveChargesNothing.selector);
        new ExponentialMintCurve(W, free, BASE, EXPONENT, 0);

        uint128[] memory falling = new uint128[](3);
        falling[0] = uint128(P1);
        falling[1] = uint128(P1);
        falling[2] = uint128(P0);
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.TableNotMonotonic.selector, 2));
        new ExponentialMintCurve(W, falling, BASE, EXPONENT, 0);

        uint128[] memory two = new uint128[](2);
        two[0] = uint128(P0);
        two[1] = uint128(P1);
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.TableTooTall.selector, 2 ** 128));
        new ExponentialMintCurve(2 ** 127, two, BASE, EXPONENT, 0);
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.TableTooTall.selector, 2 ** 127 + 1));
        new ExponentialMintCurve(2 ** 127 + 1, two, BASE, EXPONENT, 0);

        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.TargetBeyondTable.selector, 2 * W + 1, 2 * W));
        new ExponentialMintCurve(W, two, BASE, EXPONENT, 2 * W + 1);
    }

    /// @dev Equal neighbours are allowed: a flat run is a legitimate shape (and what the
    ///      simulation's random tables produce), only a fall is not. And the smallest table
    ///      that constructs still prices every wei of its domain.
    function test_Constructor_AcceptsAFlatTableAndTheSmallestOne() public {
        uint128[] memory flat = new uint128[](3);
        flat[0] = 1;
        flat[1] = 1;
        flat[2] = 1;
        ExponentialMintCurve tiny = new ExponentialMintCurve(1, flat, 1, 0, 3);
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
        assertEq(curve.lockedAt(TOP), COST_WHOLE_TABLE, "the whole table is an exact multiple of a wei here");
        // `lockedAt` floors and `cost` ceils; they may differ by one wei and never more.
        assertLe(curve.cost(0, 2000e18 + 1) - curve.lockedAt(2000e18 + 1), 1);
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.SupplyOutOfDomain.selector, TOP + 1, TOP));
        curve.lockedAt(TOP + 1);
    }

    /// @dev Not a pass/fail on a number that will drift with the compiler, but a ceiling that
    ///      says the design holds: a mint inside one bucket is one storage read, and the
    ///      worst case -- pricing the entire table in one call -- stays far inside a block.
    function test_Gas_ScalesWithBucketsTouchedNotWithSupply() public view {
        uint256 g = gasleft();
        curve.cost(2000e18, 1e18);
        uint256 oneBucket = g - gasleft();

        g = gasleft();
        curve.cost(9000e18, 1e18);
        uint256 oneBucketHighUp = g - gasleft();

        g = gasleft();
        curve.cost(0, TOP);
        uint256 wholeTable = g - gasleft();

        assertLt(oneBucket, 15_000, "one bucket: a couple of cold reads");
        assertLe(oneBucketHighUp, oneBucket + 100, "and no dearer higher up the table");
        assertLt(wholeTable, 700_000, "the whole table: ~186 packed slots");
    }
}
