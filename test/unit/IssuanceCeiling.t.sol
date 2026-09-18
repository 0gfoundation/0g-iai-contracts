// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "../Base.t.sol";
import {IIAIVault} from "../../src/interfaces/IIAIVault.sol";
import {IMintCurve} from "../../src/interfaces/IMintCurve.sol";
import {LinearMintCurve} from "../../src/curves/LinearMintCurve.sol";
import {UpgradeChecker} from "../../script/deploy/UpgradeChecker.sol";
import {NarrowCurve, BreakableCurve} from "./mocks/StubCurves.sol";

/**
 * @title IssuanceCeilingTest
 * @notice The supply ceiling is the curve's, and it moves only when the curve does.
 *
 * @dev The vault keeps no cap of its own: `mint` refuses anything past the curve in force's
 *      `maxSafeSupply()`, clamped to the vault's hard bound. So the ceiling is raised by
 *      swapping in a wider curve and lowered by swapping in a narrower one -- including one
 *      whose top is below the supply that already exists. That state is **burn-only mode**,
 *      the supported way to close issuance without touching anything else. It falls out of
 *      the arithmetic rather than needing a mode flag -- the `supplyAfter > cap` check is
 *      simply always true once `cap < supply` -- so most of what is tested here is that
 *      nothing *else* trips over it.
 *
 *      The thing to guard against is the intuitive "fix": a `require(newCurve.maxSafeSupply()
 *      >= supply)` in `setCurve`. It looks like a safety check and would make issuance
 *      un-closable exactly when it most needs closing. `test_BurnOnly_ACurveBelowTheLiveSupply
 *      ClosesIssuance` and `test_BurnOnly_AZeroCeilingClosesIssuanceToEveryone` exist to fail
 *      loudly if anyone ever adds it.
 */
contract IssuanceCeilingTest is BaseTest, UpgradeChecker {
    function setUp() public override {
        super.setUp();
        _mintFor(alice, 100e18);
        _mintFor(bob, 250e18);
    }

    // -------------------------------------------------------------------------
    // Where the ceiling comes from
    // -------------------------------------------------------------------------

    function test_Ceiling_IsTheCurves() public view {
        assertEq(vault.cap(), mintCurve.maxSafeSupply(), "the vault reads its ceiling off the curve");
        assertEq(vault.cap(), CAP, "which for the linear curve is its anchor");
        assertEq(vault.remainingCap(), CAP - vault.supply(), "headroom follows it");
    }

    /// @dev A curve reporting more than the vault's own arithmetic is proven at does not widen
    ///      the domain: the `uint128` narrowing of a position and the linear curve's squared
    ///      supply are both safe only up to 2^127, so that is where the vault stops listening.
    function test_Ceiling_IsClampedToTheVaultsHardBound() public {
        vault.setCurve(IMintCurve(address(new NarrowCurve(type(uint256).max))));
        assertEq(vault.cap(), 2 ** 127, "clamped");
        assertEq(vault.remainingCap(), 2 ** 127 - vault.supply());
    }

    // -------------------------------------------------------------------------
    // Raising and lowering while there is still headroom
    // -------------------------------------------------------------------------

    function test_Swap_ToAWiderCurveOpensHeadroomUpToItsCeiling() public {
        uint256 raised = CAP * 2;
        vault.setCurve(IMintCurve(address(new LinearMintCurve(R0, raised, TARGET * 2))));

        assertEq(vault.cap(), raised);
        assertEq(vault.remainingCap(), raised - vault.supply(), "headroom follows the new ceiling");

        // Mint right up to the new ceiling, then one wei past it.
        uint256 headroom = vault.remainingCap();
        _mintFor(carol, headroom);
        assertEq(vault.supply(), raised, "minted to the new ceiling exactly");

        _expectCapExceeded(raised + 1, raised);
        vm.prank(carol);
        vault.mint(1, type(uint256).max, block.timestamp);
    }

    function test_Swap_ToANarrowerCurveAboveTheSupplyJustNarrowsTheHeadroom() public {
        uint256 supply = vault.supply();
        uint256 lowered = supply + 10e18;
        vault.setCurve(IMintCurve(address(new NarrowCurve(lowered))));

        assertEq(vault.remainingCap(), 10e18);
        _mintFor(carol, 10e18);

        _expectCapExceeded(lowered + 1, lowered);
        vm.prank(carol);
        vault.mint(1, type(uint256).max, block.timestamp);
    }

    // -------------------------------------------------------------------------
    // Burn-only mode
    // -------------------------------------------------------------------------

    /// @dev The supported state a `require(maxSafeSupply() >= supply)` guard would forbid.
    function test_BurnOnly_ACurveBelowTheLiveSupplyClosesIssuance() public {
        uint256 supply = vault.supply();
        vault.setCurve(IMintCurve(address(new NarrowCurve(supply / 2))));

        assertEq(vault.cap(), supply / 2);
        assertEq(vault.remainingCap(), 0, "headroom saturates at zero, it does not go negative");
        assertGt(vault.supply(), vault.cap(), "the supply is legitimately above the ceiling");
    }

    /// @dev A zero ceiling is the one switch that closes issuance to everyone: the check sits
    ///      inside `mint`'s body, below the pause gate, so it binds a `PAUSE_EXEMPT_MINTER_ROLE`
    ///      holder as well.
    function test_BurnOnly_AZeroCeilingClosesIssuanceToEveryone() public {
        bytes32 exemption = vault.PAUSE_EXEMPT_MINTER_ROLE();
        vault.grantRole(exemption, carol);
        _fund(carol, 1e18);

        vault.setCurve(IMintCurve(address(new NarrowCurve(0))));
        assertEq(vault.cap(), 0);
        assertEq(vault.remainingCap(), 0);

        vm.prank(guardian);
        vault.pause();
        _expectCapExceeded(vault.supply() + 1e18, 0);
        vm.prank(carol);
        vault.mint(1e18, type(uint256).max, block.timestamp);
    }

    /// @dev Issuance is shut: minting reverts, and so does the quote that would precede it.
    ///      `quoteMintForA0G` is the exception -- it promises a clamp rather than a revert,
    ///      so it answers zero.
    function test_BurnOnly_IssuanceIsClosedAndTheQuotesAgreeWithIt() public {
        uint256 supply = vault.supply();
        vault.setCurve(IMintCurve(address(new NarrowCurve(supply / 2))));

        _expectCapExceeded(supply + 1e18, supply / 2);
        vm.prank(carol);
        vault.mint(1e18, type(uint256).max, block.timestamp);

        // A quote must fail where the action fails, or a frontend shows a price for something
        // that cannot be bought.
        _expectCapExceeded(supply + 1e18, supply / 2);
        vault.quoteMint(1e18);

        assertEq(vault.quoteMintForA0G(1000e18), 0, "the clamping quote clamps to nothing");
    }

    /**
     * @dev And everything that is not issuance carries on. Redemption especially: the ceiling
     *      is an issuance ceiling, and it must not become a second, accidental way to gate the
     *      one path that has to always work.
     */
    function test_BurnOnly_RedemptionStakingAndHarvestAllCarryOn() public {
        vm.prank(alice);
        iai.approve(address(registry), type(uint256).max);
        vm.prank(alice);
        registry.stake(40e18);

        vault.setCurve(IMintCurve(address(new NarrowCurve(0))));

        // Redemption, quoted and executed.
        (uint256 unlocked, uint256 out) = vault.quoteBurn(alice, 20e18);
        assertGt(out, 0);
        uint256 held = a0g.balanceOf(alice);
        _burn(alice, 20e18);
        assertEq(a0g.balanceOf(alice) - held, out, "burn paid what it quoted");
        assertGt(unlocked, 0);

        // Bob's own redemption, from the same closed state.
        _burn(bob, 10e18);

        // Staking, cooldown and withdrawal.
        vm.prank(alice);
        registry.stake(10e18);
        vm.prank(alice);
        registry.initiateUnstake(15e18);
        _warp(COOLDOWN + 1);
        vm.prank(alice);
        registry.unstake();

        // And the sweep, which is gated by `pause`, not by the ceiling.
        _warp(30 days);
        assertGt(vault.harvest(), 0, "the sweep still runs with issuance closed");
        _assertSolvent();
    }

    /// @dev A consequence worth knowing operationally: a zero ceiling closes issuance but
    ///      leaves the sweep running, so it is not a wind-down switch. `pause()` stops both --
    ///      and redemption still works through it, which is the whole point of the pause design.
    function test_BurnOnly_IsNotAWindDownSwitchOnItsOwn() public {
        vault.setCurve(IMintCurve(address(new NarrowCurve(0))));
        _warp(30 days);
        assertGt(vault.harvest(), 0, "the ceiling does not reach the sweep");

        vault.pause();
        _warp(30 days);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.harvest();

        _burn(alice, 10e18); // redemption is never gated, by either switch
    }

    function test_Swap_BackToAWiderCurveReopensIssuance() public {
        vault.setCurve(IMintCurve(address(new NarrowCurve(0))));
        vault.setCurve(IMintCurve(address(mintCurve)));

        assertEq(vault.remainingCap(), CAP - vault.supply());
        _mintFor(carol, 50e18);
        assertEq(vault.supply(), 400e18);
    }

    /**
     * @dev Closing issuance must not depend on the curve in force answering a call. One of
     *      the emergencies is a curve that reverts on every call -- and with the ceiling read
     *      from the curve, every priced path and `cap()` itself revert with it. What has to
     *      keep working is redemption, which never consults a curve; and what has to stay
     *      reachable is the exit, which is `setCurve`, which never reads the outgoing curve.
     */
    function test_ABrokenCurveTakesTheCeilingDownWithItButNotRedemptionOrTheExit() public {
        BreakableCurve curve = new BreakableCurve();
        vault.setCurve(IMintCurve(address(curve)));
        curve.breakIt();

        vm.expectRevert(bytes("broken"));
        vault.cap();
        vm.expectRevert(bytes("broken"));
        vault.remainingCap();
        vm.expectRevert(bytes("broken"));
        vault.quoteMint(1e18);

        _burn(alice, 100e18); // redemption carried on throughout

        vault.setCurve(IMintCurve(address(new NarrowCurve(0))));
        assertEq(vault.cap(), 0, "issuance closed without the broken curve's cooperation");
    }

    // -------------------------------------------------------------------------
    // Operational tooling has to survive the mode it exists to be used in
    // -------------------------------------------------------------------------

    /**
     * @dev The rehearsal and the deployment check probe live pricing, and every one of those
     *      probes reverts once the ceiling is under the supply. Unguarded, `./run.sh check`
     *      and `./upgrade.sh rehearse` would break precisely after an emergency close -- the
     *      moment an operator most needs to read the system's state.
     */
    function test_BurnOnly_TheUpgradeRehearsalAndWiringCheckStillRun() public {
        address[] memory watched = new address[](2);
        watched[0] = alice;
        watched[1] = bob;

        Snapshot memory before_ = _capture(vault, iai, registry, watched);
        assertTrue(before_.quotesAvailable, "quotes work while there is headroom");

        vault.setCurve(IMintCurve(address(new NarrowCurve(0))));

        Snapshot memory closed = _capture(vault, iai, registry, watched);
        assertFalse(closed.quotesAvailable, "and are correctly reported as unavailable");
        _assertPricingMatchesCurve(vault); // must not revert

        // An upgrade rehearsed from inside burn-only compares cleanly against itself.
        _assertUnchanged(closed, _capture(vault, iai, registry, watched));
    }

    /// @dev Even at an absurd input the clamping quote must clamp rather than revert: the
    ///      root solver squares an intermediate that grows with the budget, so a "spend
    ///      everything" quote from a large balance is exactly where it would overflow.
    function test_QuoteMintForA0G_ClampsRatherThanRevertingAtAnyInput() public {
        assertGt(vault.quoteMintForA0G(type(uint128).max), 0, "clamped to the headroom");
        assertGt(vault.quoteMintForA0G(type(uint256).max / 2), 0, "still clamps, does not revert");

        vault.setCurve(IMintCurve(address(new NarrowCurve(0))));
        assertEq(vault.quoteMintForA0G(type(uint256).max / 2), 0, "zero headroom, zero quote");
    }

    function _expectCapExceeded(uint256 requested, uint256 cap) private {
        vm.expectRevert(abi.encodeWithSelector(IIAIVault.CapExceeded.selector, requested, cap));
    }
}
