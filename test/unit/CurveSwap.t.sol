// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "../Base.t.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {IIAIVault} from "../../src/interfaces/IIAIVault.sol";
import {IMintCurve} from "../../src/interfaces/IMintCurve.sol";
import {LinearMintCurve} from "../../src/curves/LinearMintCurve.sol";
import {ExponentialMintCurve} from "../../src/curves/ExponentialMintCurve.sol";
import {ExponentialTable} from "./curves/ExponentialTable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev A curve that reverts on every call, for the recovery test. The point of `setCurve`
///      never reading the outgoing curve is that a curve like this can still be replaced.
contract BrokenCurve is IMintCurve {
    function cost(uint256, uint256) external pure returns (uint256) {
        revert("broken");
    }

    function quoteForValue(uint256, uint256) external pure returns (uint256) {
        revert("broken");
    }

    function maxSafeSupply() external pure returns (uint256) {
        return 2 ** 127;
    }
}

/// @dev A curve that sells iAI for nothing. The vault has to refuse it at `mint`, because a
///      curve is an external contract and its return value is not something to be trusted.
contract FreeCurve is IMintCurve {
    function cost(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function quoteForValue(uint256, uint256) external pure returns (uint256) {
        return type(uint128).max;
    }

    function maxSafeSupply() external pure returns (uint256) {
        return 2 ** 127;
    }
}

/**
 * @title CurveSwapTest
 * @notice Replacing the pricing surface under a system that already holds collateral.
 *
 * @dev The property being tested is the reason the vault records an absolute 0G amount per
 *      position instead of the curve parameters that produced it: **a swap reprices nothing
 *      that has already been minted.** Redemption never consults a curve, so a holder who
 *      minted before the swap is settled at exactly what they locked, whichever curve is in
 *      force when they leave.
 *
 *      Every test here mints first. Swapping a curve on an empty vault proves nothing —
 *      there are no prior positions to leave alone — so the fixture opens two of them before
 *      any swap happens, and the replacement curve is a very different shape from the
 *      production one so that a wrongly-repriced position would be off by a wide margin
 *      rather than by rounding.
 */
contract CurveSwapTest is BaseTest {
    /// @dev Twice the entry price and twice the target: unmistakably dearer at every supply.
    LinearMintCurve internal dearer;
    /// @dev Half the entry price: unmistakably cheaper, which is the direction that lets an
    ///      existing holder round-trip at a profit. That is an accepted risk, not a bug.
    LinearMintCurve internal cheaper;
    /// @dev The production table: a different *shape*, not just a different slope, so the
    ///      swap the testnet and mainnet will actually perform is the one rehearsed here.
    ExponentialMintCurve internal exponential;

    uint256 internal aliceLocked;
    uint256 internal bobLocked;

    function setUp() public override {
        super.setUp();
        dearer = new LinearMintCurve(R0 * 2, CAP, TARGET * 2);
        cheaper = new LinearMintCurve(R0 / 2, CAP, TARGET / 2);
        exponential = new ExponentialMintCurve(
            ExponentialTable.BUCKET_WIDTH,
            ExponentialTable.prices(),
            ExponentialTable.BASE,
            ExponentialTable.EXPONENT,
            ExponentialTable.TARGET
        );

        _mintFor(alice, 100e18);
        _mintFor(bob, 250e18);
        (aliceLocked,,) = vault.positionOf(alice);
        (bobLocked,,) = vault.positionOf(bob);
    }

    // -------------------------------------------------------------------------
    // Requirement 1: a swap does not reach anything already minted
    // -------------------------------------------------------------------------

    /// @dev The central assertion. Quote the redemption before and after the swap and compare
    ///      wei for wei: not "close", not "within rounding" -- identical.
    function test_Swap_LeavesAnExistingRedemptionQuoteUntouched() public {
        (uint256 unlockedBefore, uint256 outBefore) = vault.quoteBurn(alice, 100e18);

        vault.setCurve(IMintCurve(address(dearer)));

        (uint256 unlockedAfter, uint256 outAfter) = vault.quoteBurn(alice, 100e18);
        assertEq(unlockedAfter, unlockedBefore, "the 0G released did not move");
        assertEq(outAfter, outBefore, "the a0G paid out did not move");
    }

    /// @dev And the quote is not merely stable, it is honoured: the burn actually pays it.
    function test_Swap_APreSwapPositionRedeemsForExactlyWhatItLocked() public {
        vault.setCurve(IMintCurve(address(dearer)));

        uint256 held = a0g.balanceOf(alice);
        _burnFor(alice, 100e18);

        uint256 expected = (aliceLocked * WAD) / vault.exchangeRate();
        assertEq(a0g.balanceOf(alice) - held, expected, "settled at the position's own average");

        (uint256 locked, uint256 outstanding,) = vault.positionOf(alice);
        assertEq(locked, 0, "the position closed out completely");
        assertEq(outstanding, 0);
    }

    /// @dev The other half of requirement 1: new mints do use the new curve. Checked against
    ///      the replacement curve computed independently, not against the vault's own quote.
    function test_Swap_NewMintsArePricedByTheNewCurve() public {
        vault.setCurve(IMintCurve(address(dearer)));

        uint256 supply = vault.supply();
        (uint256 quoted,) = vault.quoteMint(50e18);
        assertEq(quoted, dearer.cost(supply, 50e18), "priced by the curve now in force");
        assertGt(quoted, mintCurve.cost(supply, 50e18), "and the new curve really is dearer");

        (uint256 lockedBefore,,) = vault.positionOf(carol);
        _mintFor(carol, 50e18);
        (uint256 lockedAfter,,) = vault.positionOf(carol);
        assertEq(lockedAfter - lockedBefore, quoted, "the mint charged what it quoted");
    }

    /**
     * @dev A holder who minted on both sides of a swap gets a blended average, not per-coin
     *      pricing. The position is a single pair of accumulators, so redemption returns the
     *      same rate for every unit in it.
     *
     *      This is a deliberate limitation and worth stating: the guarantee is "nobody's
     *      existing collateral is repriced", which holds because the total is preserved. It
     *      is *not* "every coin redeems at the price it was minted at" -- that would need
     *      per-batch accounting, with storage and gas growing per mint.
     */
    function test_Swap_AHolderWhoMintsOnBothSidesGetsABlendedAverage() public {
        uint256 cheapLeg = aliceLocked;

        vault.setCurve(IMintCurve(address(dearer)));
        uint256 dearLeg = dearer.cost(vault.supply(), 100e18);
        _mintFor(alice, 100e18);

        (uint256 locked, uint256 outstanding, uint256 avgRate) = vault.positionOf(alice);
        assertEq(locked, cheapLeg + dearLeg, "the position holds the sum of what was paid");
        assertEq(outstanding, 200e18);
        assertEq(avgRate, (locked * WAD) / outstanding, "one blended rate for the whole position");

        // Redeeming half returns half the position, at the blend -- not the cheap leg first.
        (uint256 unlocked,) = vault.quoteBurn(alice, 100e18);
        assertEq(unlocked, locked / 2, "half the position, at the blended rate");
        assertGt(unlocked, cheapLeg, "more than the cheap leg alone");
        assertLt(unlocked, dearLeg, "less than the dear leg alone");
    }

    /**
     * @dev Raising the curve puts it ahead of the collateral actually held -- the curve now
     *      says the live supply is worth more than was ever collected for it. That is fine,
     *      and this is the test that says why: everyone who minted before the swap can still
     *      walk out with exactly what they put in, and the vault stays solvent throughout.
     *
     *      This is what replaces the old "the total covers the curve" invariant, which was
     *      never an accounting identity -- it asserted that every wei in the total had been
     *      priced by the curve in force, and a swap makes that false with nobody having done
     *      anything.
     */
    function test_Swap_UpwardsStillLetsEveryPriorHolderExitInFull() public {
        vault.setCurve(IMintCurve(address(dearer)));

        // The curve is now ahead of the collateral: proof the retired invariant would fail.
        assertGt(
            dearer.lockedAt(vault.supply()),
            vault.totalLocked0G(),
            "the new curve values the supply above what was collected"
        );

        uint256 aliceHeld = a0g.balanceOf(alice);
        uint256 bobHeld = a0g.balanceOf(bob);
        uint256 er = vault.exchangeRate();

        _burnFor(alice, 100e18);
        _assertSolvent();
        _burnFor(bob, 250e18);
        _assertSolvent();

        assertEq(a0g.balanceOf(alice) - aliceHeld, (aliceLocked * WAD) / er, "alice got hers back");
        assertEq(a0g.balanceOf(bob) - bobHeld, (bobLocked * WAD) / er, "bob got his back");
        assertEq(vault.totalLocked0G(), 0, "nothing left owing");
        assertEq(vault.supply(), 0);
    }

    /**
     * @dev Lowering the curve lets an existing holder burn and re-mint for a profit: they
     *      release 0G at their own average and buy the same supply back cheaper. Recorded
     *      here as a measured, accepted consequence rather than left to be rediscovered.
     *
     *      It does not break solvency -- the vault only ever pays out what a position holds --
     *      but the same supply now sits on less collateral, so the foundation's future
     *      harvest is smaller. Whoever lowers a curve is choosing that.
     */
    function test_Swap_DownwardsIsArbitrageableByExistingHolders() public {
        uint256 before_ = a0g.balanceOf(alice);

        vault.setCurve(IMintCurve(address(cheaper)));

        _burnFor(alice, 100e18);
        uint256 buyBack = cheaper.cost(vault.supply(), 100e18);
        _mintFor(alice, 100e18);

        assertLt(buyBack, aliceLocked, "the same 100 iAI cost less to reacquire");
        assertGt(a0g.balanceOf(alice), before_, "the round trip left the holder ahead");
        _assertSolvent();
    }

    // -------------------------------------------------------------------------
    // The setter itself
    // -------------------------------------------------------------------------

    function test_SetCurve_IsAdminOnly() public {
        address target = address(dearer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0)
            )
        );
        vm.prank(alice);
        vault.setCurve(IMintCurve(target));
    }

    function test_SetCurve_RejectsTheZeroAddressAndAnEmptyAccount() public {
        vm.expectRevert(IIAIVault.ZeroAddress.selector);
        vault.setCurve(IMintCurve(address(0)));

        address empty = makeAddr("no code here");
        vm.expectRevert(abi.encodeWithSelector(IIAIVault.NotAContract.selector, empty));
        vault.setCurve(IMintCurve(empty));
    }

    /// @dev The vault's cap has to stay inside whatever domain the incoming curve declares,
    ///      or the very next mint would evaluate the curve outside its safe range.
    function test_SetCurve_RejectsACurveWhoseDomainIsNarrowerThanTheCap() public {
        NarrowCurve narrow = new NarrowCurve(CAP - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IIAIVault.CapAboveCurveDomain.selector, CAP, CAP - 1)
        );
        vault.setCurve(IMintCurve(address(narrow)));

        // Lower the cap into its domain and the same curve is accepted.
        vault.setCap(CAP - 1);
        vault.setCurve(IMintCurve(address(narrow)));
        assertEq(address(vault.curve()), address(narrow));
    }

    /**
     * @dev The recovery path, and the reason `setCurve` never calls the outgoing curve. If it
     *      validated by comparing against the curve being replaced, a curve that reverts would
     *      be unreplaceable and issuance would be dead permanently -- with the collateral of
     *      everyone already in still redeemable, but nobody ever able to mint again.
     */
    function test_SetCurve_CanReplaceACurveThatIsCompletelyBroken() public {
        vault.setCurve(IMintCurve(address(new BrokenCurve())));

        vm.expectRevert(bytes("broken"));
        vault.quoteMint(1e18);

        // Redemption is untouched by a broken curve: it never consults one.
        (uint256 unlocked,) = vault.quoteBurn(alice, 100e18);
        assertEq(unlocked, aliceLocked);
        _burnFor(alice, 100e18);

        // And issuance comes back.
        vault.setCurve(IMintCurve(address(mintCurve)));
        (uint256 quoted,) = vault.quoteMint(1e18);
        assertEq(quoted, mintCurve.cost(vault.supply(), 1e18), "issuance restored");
    }

    /**
     * @dev A curve that sells for nothing would hand out iAI free: the recipient could claim
     *      compute for it, and the supply every later mint is priced against would be inflated
     *      permanently. The vault refuses a zero price itself rather than trusting the curve,
     *      so this is a property of the vault and not a promise from an external contract.
     */
    function test_Mint_RefusesACurveThatChargesNothing() public {
        vault.setCurve(IMintCurve(address(new FreeCurve())));

        vm.expectRevert(IIAIVault.ZeroAmount.selector);
        vm.prank(alice);
        vault.mint(1e18, type(uint256).max, block.timestamp);
    }

    /// @dev The harvest sweep works off collateral actually held against `totalLocked0G`,
    ///      neither of which a swap touches, so the surplus is the same on both sides of one.
    function test_Swap_DoesNotDisturbTheHarvestSweep() public {
        vm.warp(block.timestamp + 30 days);

        uint256 held = a0g.balanceOf(address(vault));
        uint256 owed = Math_ceilDiv(vault.totalLocked0G() * WAD, vault.exchangeRate());
        uint256 expected = held - owed;

        vault.setCurve(IMintCurve(address(dearer)));

        assertEq(vault.harvest(), expected, "the sweep is measured against collateral, not the curve");
        _assertSolvent();
    }

    // -------------------------------------------------------------------------
    // Linear -> exponential: the swap the live networks will make
    // -------------------------------------------------------------------------

    /// @dev Requirement 1 across a change of *shape*. Alice minted on the linear curve; the
    ///      step table now in force says nothing about her, and her redemption is wei-for-wei
    ///      what it was. Carol's mint afterwards is priced by the table -- and it is placed so
    ///      that it crosses a bucket boundary (350 -> 380 iAI straddles 375), so the charge is
    ///      two bucket prices summed under one ceiling, checked against the table directly.
    function test_Swap_ToTheExponentialCurve_LeavesPriorPositionsAloneAndPricesNewOnesByTheTable() public {
        (uint256 unlockedBefore, uint256 outBefore) = vault.quoteBurn(alice, 100e18);

        vault.setCurve(IMintCurve(address(exponential)));

        (uint256 unlockedAfter, uint256 outAfter) = vault.quoteBurn(alice, 100e18);
        assertEq(unlockedAfter, unlockedBefore, "the 0G released did not move");
        assertEq(outAfter, outBefore, "the a0G paid out did not move");

        uint256 supply = vault.supply();
        assertEq(supply, 350e18, "alice's 100 and bob's 250");
        (uint256 quoted,) = vault.quoteMint(30e18);
        uint256 twoBuckets = exponential.priceAt(14) * 25 + exponential.priceAt(15) * 5;
        assertEq(quoted, twoBuckets, "25 iAI at bucket 14's price and 5 at bucket 15's, exact to the wei");
        assertEq(quoted, exponential.cost(supply, 30e18), "and it is what the curve itself says");
        assertLt(quoted, mintCurve.cost(supply, 30e18), "the table is cheaper than the linear curve here");

        (uint256 lockedBefore,,) = vault.positionOf(carol);
        _mintFor(carol, 30e18);
        (uint256 lockedAfter,,) = vault.positionOf(carol);
        assertEq(lockedAfter - lockedBefore, quoted, "the mint charged what it quoted");

        // Alice leaves at her own average, unaffected by any of it.
        uint256 held = a0g.balanceOf(alice);
        _burnFor(alice, 100e18);
        assertEq(a0g.balanceOf(alice) - held, outBefore, "settled at the pre-swap quote");
        _assertSolvent();
    }

    /// @dev The table has a top, and the vault's cap must stay under it while the table is in
    ///      force. Five iAI of slack (9,275 against 9,270) is what the last partial bucket
    ///      leaves; one wei more is refused. Raising the cap further means a taller table.
    function test_Swap_ToTheExponentialCurve_BoundsTheCapByItsTable() public {
        vault.setCurve(IMintCurve(address(exponential)));

        vault.setCap(9275e18);
        assertEq(vault.cap(), 9275e18, "up to the table's top is fine");

        vm.expectRevert(abi.encodeWithSelector(IIAIVault.CapAboveCurveDomain.selector, 9275e18 + 1, 9275e18));
        vault.setCap(9275e18 + 1);

        // Lowering never consults the curve, so burn-only stays reachable under this curve too.
        vault.setCap(0);
        assertEq(vault.cap(), 0);
        vault.setCap(CAP);

        // And the linear curve, whose domain is wide, can take the cap anywhere again.
        vault.setCurve(IMintCurve(address(mintCurve)));
        vault.setCap(CAP * 2);
        vm.expectRevert(abi.encodeWithSelector(IIAIVault.CapAboveCurveDomain.selector, CAP * 2, 9275e18));
        vault.setCurve(IMintCurve(address(exponential)));
    }

    /// @dev A position opened on the table survives a swap back to the linear curve exactly as
    ///      one opened on the linear curve survived the swap forward: the curve is consulted at
    ///      mint and never again.
    function test_Swap_BackFromTheExponentialCurve_KeepsATablePricedPositionWhole() public {
        vault.setCurve(IMintCurve(address(exponential)));
        uint256 paid = _mintFor(carol, 40e18);
        (uint256 locked,,) = vault.positionOf(carol);
        assertEq(locked, exponential.cost(350e18, 40e18), "priced by the table");

        vault.setCurve(IMintCurve(address(mintCurve)));

        (uint256 unlocked, uint256 out) = vault.quoteBurn(carol, 40e18);
        assertEq(unlocked, locked, "the whole position, at its own price");
        uint256 held = a0g.balanceOf(carol);
        _burnFor(carol, 40e18);
        assertEq(a0g.balanceOf(carol) - held, out);
        assertLe(paid - out, 1, "a round trip costs at most the rounding wei");
        _assertSolvent();
    }
}

/// @dev A curve that declares a domain narrower than the vault's cap.
contract NarrowCurve is IMintCurve {
    uint256 private immutable top;

    constructor(uint256 top_) {
        top = top_;
    }

    function cost(uint256, uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function quoteForValue(uint256, uint256 delta0G) external pure returns (uint256) {
        return delta0G;
    }

    function maxSafeSupply() external view returns (uint256) {
        return top;
    }
}
