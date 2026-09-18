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
 *      on every one of the 587 entries. Changing one to make a test pass converts an
 *      independent check into a copy of whatever the code now does.
 *
 *      The table itself comes from `ExponentialTable.sol`, generated from the deployment
 *      record; `test/script/Deploy.t.sol` asserts the two are identical.
 */
contract ExponentialMintCurveTest is CurveConformanceTest {
    uint256 internal constant W = 25e18;
    /// @dev The supply the exponent is normalised against: a scale in the formula, not a
    ///      ceiling of anything.
    uint256 internal constant TARGET = 9270e18;
    /// @dev The table's top, and so the vault's supply ceiling: the smallest whole number of
    ///      buckets whose total reaches the 2,000,000,000 0G budget.
    uint256 internal constant TOP = 14_675e18;
    uint256 internal constant COUNT = 587;

    uint256 internal constant BASE = 586e18;
    uint256 internal constant EXPONENT = 4.711e18;
    uint256 internal constant BUDGET = 2_000_000_000e18;

    // --- golden vectors, computed with mpmath outside this codebase ---
    uint256 internal constant P0 = 593_492_603_713_227_388_873;
    uint256 internal constant P1 = 601_081_007_956_153_530_058;
    /// @dev Bucket [2000, 2025): the first public mint after the 2,000 iAI pre-mint.
    uint256 internal constant P80 = 1_639_951_145_958_071_970_563;
    uint256 internal constant P185 = 6_225_709_974_284_080_163_438;
    /// @dev The last bucket, [14650, 14675).
    uint256 internal constant P586 = 1_015_744_731_151_825_140_869_680;

    uint256 internal constant COST_PREMINT = 2_046_100_158_323_122_128_597_800;
    uint256 internal constant COST_LAST_20 = 20_314_894_623_036_502_817_393_600;
    uint256 internal constant COST_TO_TARGET = 127_838_782_672_610_268_612_331_555;
    uint256 internal constant COST_WHOLE_TABLE = 2_010_279_809_240_020_231_619_935_500;
    /// @dev [24, 26): one iAI in bucket 0 and one in bucket 1.
    uint256 internal constant COST_ACROSS_FIRST_BOUNDARY = 1_194_573_611_669_380_918_931;

    ExponentialMintCurve internal curve;

    function setUp() public {
        curve = new ExponentialMintCurve(W, ExponentialTable.prices(), BASE, EXPONENT, TARGET);
    }

    // --- conformance hooks ---

    function _curve() internal view override returns (IMintCurve) {
        return curve;
    }

    /// @dev Both sides of the first boundary, the pre-mint edge, the normalising supply and
    ///      the top: the places a step function can go wrong. Kept short because the split
    ///      test is quadratic in it.
    function _supplies() internal pure override returns (uint256[] memory s) {
        s = new uint256[](11);
        s[0] = 0;
        s[1] = 1;
        s[2] = W - 1;
        s[3] = W;
        s[4] = W + 1;
        s[5] = 2000e18;
        s[6] = TARGET / 2;
        s[7] = TARGET - 1;
        s[8] = TARGET;
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
        assertEq(curve.top(), TOP, "587 buckets of 25 iAI");
        assertEq(curve.maxSafeSupply(), TOP, "the ceiling is the table's top");
        assertEq(curve.base(), BASE);
        assertEq(curve.exponent(), EXPONENT);
        assertEq(curve.target(), TARGET);
        assertGt(curve.top(), TARGET, "the table reaches well past the normalising supply");
    }

    /// @dev The table is exactly as long as the budget needs: one bucket fewer and the total
    ///      falls short of 2,000,000,000 0G, and the whole table clears it. This is the rule
    ///      the generator applies; here it is checked against numbers computed elsewhere.
    function test_Table_IsSizedByTheBudget() public view {
        assertGe(curve.cost(0, TOP), BUDGET, "the whole table absorbs the budget");
        assertLt(curve.cost(0, TOP - W), BUDGET, "and no shorter table does");
        assertEq(ExponentialTable.BUDGET, BUDGET, "the mirror records the budget it was sized to");
    }

    function test_Table_GoldenVectors() public view {
        assertEq(curve.priceAt(0), P0, "586 0G at the origin, times e^(4.711 * 25/9270)");
        assertEq(curve.priceAt(1), P1);
        assertEq(curve.priceAt(80), P80, "the first public mint after the 2,000 pre-mint");
        assertEq(curve.priceAt(185), P185, "halfway to the normalising supply");
        assertEq(curve.priceAt(586), P586, "the last bucket: ~1,015,745 0G, 1,711x the first");

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
        assertEq(curve.cost(TOP - 25e18, 20e18), COST_LAST_20, "20 iAI in the last bucket");
        assertEq(curve.cost(0, TARGET), COST_TO_TARGET, "the curve to 9,270 iAI, ~127.84M 0G");
        assertEq(curve.cost(0, TOP), COST_WHOLE_TABLE, "the whole table, ~2.01B 0G");
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

    /// @dev The table has a real edge, and it is the curve's job to say so rather than to
    ///      price a supply nobody has decided a price for. The vault never reaches it: the
    ///      table's top is the vault's ceiling, and `mint` checks it before pricing.
    function test_Cost_RevertsPastTheTable() public {
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.SupplyOutOfDomain.selector, TOP + 1e18, TOP));
        curve.cost(TOP - 25e18, 26e18);

        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.SupplyOutOfDomain.selector, TOP + 1, TOP));
        curve.cost(TOP, 1);

        assertEq(curve.cost(TOP, 0), 0, "nothing costs nothing, even at the edge");
        assertEq(curve.cost(TOP - 1, 1), 1_015_745, "the last wei of the table is priceable");
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

    function test_Quote_SaturatesAtTheTop() public view {
        assertEq(curve.quoteForValue(0, type(uint128).max), TOP, "a huge budget buys the whole table");
        assertEq(curve.quoteForValue(0, type(uint256).max), TOP, "even one too large to scale");
        assertEq(curve.quoteForValue(0, COST_WHOLE_TABLE), TOP, "exactly the table's total buys the table");
        uint256 forTheBudget = curve.quoteForValue(0, BUDGET);
        assertGt(forTheBudget, TOP - W, "the budget itself runs out inside the last bucket");
        assertLt(forTheBudget, TOP, "and does not quite buy all of it");
        assertEq(curve.quoteForValue(TOP - 5e18, 1e30), 5e18, "near the top, only the table's last 5 iAI remain");
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
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.BucketTooWide.selector, 2 ** 127 + 1));
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
        assertEq(curve.bucketOf(TOP - 1), 586);
        vm.expectRevert(abi.encodeWithSelector(ExponentialMintCurve.SupplyOutOfDomain.selector, TOP, TOP));
        curve.bucketOf(TOP);

        assertEq(curve.rateAt(2000e18), P80, "the marginal price the first public minter sees");
        assertEq(curve.rateAt(TOP - 1), P586);
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
        curve.cost(14_000e18, 1e18);
        uint256 oneBucketHighUp = g - gasleft();

        g = gasleft();
        curve.cost(0, TOP);
        uint256 wholeTable = g - gasleft();

        assertLt(oneBucket, 15_000, "one bucket: a couple of cold reads");
        assertLe(oneBucketHighUp, oneBucket + 100, "and no dearer higher up the table");
        assertLt(wholeTable, 1_100_000, "the whole table: ~294 packed slots");
    }
}
