// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {CurveConformanceTest} from "./CurveConformance.t.sol";
import {IMintCurve} from "../../../src/interfaces/IMintCurve.sol";
import {LinearMintCurve} from "../../../src/curves/LinearMintCurve.sol";

/**
 * @title LinearMintCurveTest
 * @notice The production curve, as a deployed contract.
 *
 * @dev Two jobs, and they are different jobs.
 *
 *      Inheriting `CurveConformanceTest` runs the shared behavioural contract against it, the
 *      same way any future curve will have to. That proves it is a well-formed curve; it says
 *      nothing about it being the *right* curve.
 *
 *      The golden vectors below are the second job. They are the same numbers
 *      `LinearCurveMath.t.sol` pins on the library, re-asserted here through the external
 *      interface, so the wrapper is shown to forward to the maths that were actually checked
 *      rather than to something of its own. **None of these numbers may be edited.** They were
 *      computed outside this codebase; changing one to make a test pass converts an
 *      independent check into a copy of whatever the code now does.
 */
contract LinearMintCurveTest is CurveConformanceTest {
    uint256 internal constant WAD = 1e18;

    uint256 internal constant R0 = 4_330e18;
    uint256 internal constant CAP = 9_270e18;
    uint256 internal constant TARGET = 127_000_000e18;

    uint256 internal constant SLOPE = 2_021_598_247_004_348_741;
    /// @dev rate(cap) = R0 + slope*cap/WAD. The product docs quote 23,070.2157497303.
    uint256 internal constant R1 = 23_070_215_749_730_312_829_070;
    /// @dev `slope` is floored, so the closed form lands this many wei below TARGET.
    uint256 internal constant CAP_SHORTFALL = 37_260_550;

    LinearMintCurve internal curve;

    function setUp() public {
        curve = new LinearMintCurve(R0, CAP, TARGET);
    }

    // --- conformance hooks ---

    function _curve() internal view override returns (IMintCurve) {
        return curve;
    }

    function _supplies() internal pure override returns (uint256[] memory s) {
        s = new uint256[](6);
        s[0] = 0;
        s[1] = 1;
        s[2] = 1e18;
        s[3] = CAP / 2;
        s[4] = CAP - 1;
        s[5] = CAP;
    }

    function _amounts() internal pure override returns (uint256[] memory d) {
        d = new uint256[](5);
        d[0] = 1;
        d[1] = 1e12;
        d[2] = 1e18;
        d[3] = 100e18;
        d[4] = 1_000e18;
    }

    // --- the curve is the one the product promised ---

    function test_Constructor_DerivesTheSlopeAndKeepsItsProvenance() public view {
        assertEq(curve.slope(), SLOPE, "slope must be derived, never supplied");
        assertEq(curve.r0(), R0);
        assertEq(curve.anchorCap(), CAP, "the cap the slope was pinned against");
        assertEq(curve.target(), TARGET);
    }

    /// @dev The two published numbers: the marginal price at a full 9,270 iAI, and the total
    ///      0G the curve accounts for there.
    function test_TopOfTheCurveMatchesThePublishedFigures() public view {
        assertEq(R0 + (curve.slope() * CAP) / WAD, R1, "R1");
        assertEq(curve.lockedAt(CAP), TARGET - CAP_SHORTFALL, "127M 0G, less the flooring gap");
    }

    /// @dev The same vectors the library is pinned against, asked through the ABI.
    function test_Cost_GoldenVectorsThroughTheInterface() public view {
        assertEq(curve.cost(0, 1), 4_331, "1 wei");
        assertEq(curve.cost(0, 1e18), 4_331_010_799_123_502_174_371, "1 iAI");
        assertEq(curve.cost(0, 100e18), 443_107_991_235_021_743_705_000, "100 iAI");
        assertEq(curve.cost(0, 2_000e18), 12_703_196_494_008_697_482_000_000, "2000 iAI");
        assertEq(curve.cost(0, CAP), TARGET - 37_260_550, "the whole curve");
    }

    /// @dev The arithmetic domain, which is a property of the expression rather than of the
    ///      anchor cap. `cost` multiplies `d * (2s + d)` outside `mulDiv`; at `s = d = 2^127`
    ///      that is `3 * 2^254`, the last point that still fits.
    function test_MaxSafeSupply_IsTheArithmeticBoundNotThePolicyCap() public view {
        assertEq(curve.maxSafeSupply(), 2 ** 127);
        assertGt(curve.maxSafeSupply(), curve.anchorCap(), "the domain is wider than the anchor");
    }

    // --- the constructor is the only chance to reject a malformed curve ---

    /// @dev Being immutable, there is no later opportunity to notice a bad parameter, so
    ///      every property the vault and the conformance suite rely on is checked once, here.
    function test_Constructor_RejectsMalformedParameters() public {
        vm.expectRevert(); // cap of zero
        new LinearMintCurve(R0, 0, TARGET);

        vm.expectRevert(); // a cap past the arithmetic domain
        new LinearMintCurve(R0, 2 ** 127 + 1, TARGET);

        vm.expectRevert(); // the flat portion alone already exceeds the target
        new LinearMintCurve(R0, CAP, (R0 * CAP) / WAD);

        vm.expectRevert(); // a target so close to the flat portion that the slope floors away
        new LinearMintCurve(R0, CAP, (R0 * CAP) / WAD + 1);
    }

    /// @dev The production curve lands on its target bar the flooring step -- 37,260,550 wei
    ///      of 127,000,000 0G. Asserted against the quantum for this anchor rather than a round
    ///      number, because the quantum is what the constructor compares against.
    function test_ProductionCurveLandsOnItsTargetWithinTheFlooringQuantum() public view {
        uint256 shortfall = curve.target() - curve.lockedAt(curve.anchorCap());
        assertEq(shortfall, CAP_SHORTFALL);
        assertLe(shortfall, (CAP * CAP) / (WAD * WAD) / 2 + 1, "within one flooring step");
    }

    /**
     * @dev The whole observable effect of computing the tolerance instead of fixing it at
     *      1e12: a curve anchored far above production now constructs.
     *
     *      This one is production's exact price shape -- `r0` of 4,330 0G and a slope in the
     *      same 2.02e18 band -- anchored at 100,000,000 iAI. Its flooring shortfall is
     *      2.5e15 wei-0G, which sounds enormous and is 2.5e-19 of the target: the quantum
     *      grows with `cap^2` while the target grows with it too, so the *relative* error is
     *      unchanged from production's 2.9e-19. A fixed 1e12 rejected it anyway.
     *
     *      Nothing today needs an anchor this large. It is here because the failure it
     *      replaces was silent in the worst way -- a well-formed curve refused at construction
     *      with an error saying it missed a target it in fact hits.
     */
    function test_Constructor_AcceptsAWellFormedCurveAtAFarLargerAnchor() public {
        uint256 largeCap = 100_000_000e18;
        uint256 largeTarget = 10_108_424_235_021_743_707_500_000_000_000_000;

        LinearMintCurve big = new LinearMintCurve(R0, largeCap, largeTarget);

        assertEq(big.slope(), SLOPE, "the same slope as production, at 10,787x the anchor");
        uint256 shortfall = big.target() - big.lockedAt(big.anchorCap());
        assertEq(shortfall, 2_500_000_000_000_000, "far above the old fixed 1e12 tolerance");
        assertLe(shortfall, (largeCap * largeCap) / (WAD * WAD) / 2 + 1, "within its own quantum");
    }

    /**
     * @dev The flattest curve this family admits still charges for a single wei, so
     *      `CurveChargesNothing` is unreachable here and no parameter triple demonstrates it.
     *      Both of `cost`'s terms round up and `deriveSlope` refuses a slope of zero, so the
     *      quadratic term alone is at least 1 wei however shallow the curve is -- shown below
     *      at the extreme: `r0 = 0`, and a slope of 2 -- one step above the floor.
     *
     *      The constructor keeps the check anyway. It costs one evaluation, once, on a
     *      contract that can never be fixed afterwards, and what it guards against is not a
     *      bad parameter but a future change to the rounding in `LinearCurveMath.cost` -- the
     *      one place where free iAI could appear without anything else noticing.
     */
    function test_TheFlattestAdmissibleCurveStillChargesForAWei() public {
        LinearMintCurve flattest = new LinearMintCurve(0, 1e30, 1e24);
        assertEq(flattest.r0(), 0, "no flat portion at all");
        assertEq(flattest.slope(), 2, "one step above the floor");
        assertGt(flattest.cost(0, 1), 0, "a wei is never free, however shallow the curve");

        // And a slope that floors to zero is refused outright, which is what leaves no gap.
        vm.expectRevert();
        new LinearMintCurve(0, 1e30, 1);
    }

    /// @dev A much steeper curve is still a well-formed one — the conformance suite runs
    ///      against the production shape, so this checks the constructor accepts the range a
    ///      governance swap would realistically move through.
    function test_Constructor_AcceptsTheRangeAGovernanceSwapWouldUse() public {
        LinearMintCurve dearer = new LinearMintCurve(R0 * 2, CAP, TARGET * 2);
        LinearMintCurve cheaper = new LinearMintCurve(R0 / 2, CAP, TARGET / 2);

        assertGt(dearer.cost(0, 1e18), curve.cost(0, 1e18), "the dearer curve charges more");
        assertLt(cheaper.cost(0, 1e18), curve.cost(0, 1e18), "the cheaper curve charges less");
    }
}
