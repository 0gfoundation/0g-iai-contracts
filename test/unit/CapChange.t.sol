// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "../Base.t.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {IIAIVault} from "../../src/interfaces/IIAIVault.sol";
import {IMintCurve} from "../../src/interfaces/IMintCurve.sol";
import {UpgradeChecker} from "../../script/deploy/UpgradeChecker.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @dev A curve that answers normally until it is broken, standing in for one that stops
 *      working after it is already in service.
 *
 *      It has to break *after* installation rather than before, because `setCurve` validates
 *      the curve coming in -- a curve that reverts from the start simply cannot be installed.
 *      That is not a contrived shape either: a curve behind a proxy can be upgraded into this
 *      state, and the vault cannot tell a plain curve from a proxied one.
 */
contract BreakableCurve is IMintCurve {
    bool public broken;

    function breakIt() external {
        broken = true;
    }

    function cost(uint256, uint256 amount) external view returns (uint256) {
        require(!broken, "broken");
        return amount;
    }

    function quoteForValue(uint256, uint256 delta0G) external view returns (uint256) {
        require(!broken, "broken");
        return delta0G;
    }

    function maxSafeSupply() external view returns (uint256) {
        require(!broken, "broken");
        return 2 ** 127;
    }
}

/**
 * @title CapChangeTest
 * @notice Moving the supply ceiling, in both directions, including below the live supply.
 *
 * @dev Lowering the cap under the supply that already exists is a supported state, not an
 *      error: it is **burn-only mode**, the way issuance is closed without touching anything
 *      else. It falls out of the arithmetic rather than needing a mode flag -- `mint`'s
 *      `supplyAfter > cap` check is simply always true once `cap < supply` -- so most of what
 *      is tested here is that nothing *else* trips over it.
 *
 *      The thing to guard against is the intuitive "fix": a `require(newCap >= supply)` in
 *      `setCap`. It looks like a safety check and would make the ceiling un-lowerable exactly
 *      when it most needs lowering. `test_SetCap_MayGoBelowTheLiveSupply` and
 *      `test_SetCap_MayBeZero` exist to fail loudly if anyone ever adds it.
 */
contract CapChangeTest is BaseTest, UpgradeChecker {
    function setUp() public override {
        super.setUp();
        _mintFor(alice, 100e18);
        _mintFor(bob, 250e18);
    }

    // -------------------------------------------------------------------------
    // Raising and lowering while there is still headroom
    // -------------------------------------------------------------------------

    function test_SetCap_RaisingOpensHeadroomUpToTheNewCeiling() public {
        uint256 raised = CAP * 2;
        vault.setCap(raised);

        assertEq(vault.cap(), raised);
        assertEq(vault.remainingCap(), raised - vault.supply(), "headroom follows the new cap");

        // Mint right up to the new ceiling, then one wei past it.
        uint256 headroom = vault.remainingCap();
        _mintFor(carol, headroom);
        assertEq(vault.supply(), raised, "minted to the new ceiling exactly");

        _expectCapExceeded(raised + 1, raised);
        vm.prank(carol);
        vault.mint(1, type(uint256).max, block.timestamp);
    }

    function test_SetCap_LoweringAboveTheSupplyJustNarrowsTheHeadroom() public {
        uint256 supply = vault.supply();
        uint256 lowered = supply + 10e18;
        vault.setCap(lowered);

        assertEq(vault.remainingCap(), 10e18);
        _mintFor(carol, 10e18);

        _expectCapExceeded(lowered + 1, lowered);
        vm.prank(carol);
        vault.mint(1, type(uint256).max, block.timestamp);
    }

    // -------------------------------------------------------------------------
    // Burn-only mode
    // -------------------------------------------------------------------------

    /// @dev The supported state a `require(newCap >= supply)` guard would forbid.
    function test_SetCap_MayGoBelowTheLiveSupply() public {
        uint256 supply = vault.supply();
        vault.setCap(supply / 2);

        assertEq(vault.cap(), supply / 2);
        assertEq(vault.remainingCap(), 0, "headroom saturates at zero, it does not go negative");
        assertGt(vault.supply(), vault.cap(), "the supply is legitimately above the cap");
    }

    function test_SetCap_MayBeZero() public {
        vault.setCap(0);
        assertEq(vault.cap(), 0);
        assertEq(vault.remainingCap(), 0);
    }

    /// @dev Issuance is shut: minting reverts, and so does the quote that would precede it.
    ///      `quoteMintForA0G` is the exception -- it promises a clamp rather than a revert,
    ///      so it answers zero.
    function test_BurnOnly_IssuanceIsClosedAndTheQuotesAgreeWithIt() public {
        uint256 supply = vault.supply();
        vault.setCap(supply / 2);

        _expectCapExceeded(supply + 1e18, supply / 2);
        vm.prank(carol);
        vault.mint(1e18, type(uint256).max, block.timestamp);

        // A quote must fail where the action fails, or a frontend shows a price for something
        // that cannot be bought.
        _expectCapExceeded(supply + 1e18, supply / 2);
        vault.quoteMint(1e18);

        assertEq(vault.quoteMintForA0G(1_000e18), 0, "the clamping quote clamps to nothing");
    }

    /**
     * @dev And everything that is not issuance carries on. Redemption especially: the cap is
     *      an issuance ceiling, and it must not become a second, accidental way to gate the
     *      one path that has to always work.
     */
    function test_BurnOnly_RedemptionStakingAndHarvestAllCarryOn() public {
        vm.prank(alice);
        iai.approve(address(registry), type(uint256).max);
        vm.prank(alice);
        registry.stake(40e18);

        vault.setCap(0);

        // Redemption, quoted and executed.
        (uint256 unlocked, uint256 out) = vault.quoteBurn(alice, 20e18);
        assertGt(out, 0);
        uint256 held = a0g.balanceOf(alice);
        _burnFor(alice, 20e18);
        assertEq(a0g.balanceOf(alice) - held, out, "burn paid what it quoted");
        assertGt(unlocked, 0);

        // The rescue path.
        vm.prank(bob);
        iai.transfer(rescuer, 10e18);
        vault.grantRole(vault.RESCUE_ROLE(), rescuer);
        vm.prank(rescuer);
        vault.burnFor(bob, 10e18, block.timestamp);

        // Staking, cooldown and withdrawal.
        vm.prank(alice);
        registry.stake(10e18);
        vm.prank(alice);
        registry.initiateUnstake(15e18);
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(alice);
        registry.unstake();

        // And the sweep, which is gated by `pause`, not by the cap.
        vm.warp(block.timestamp + 30 days);
        assertGt(vault.harvest(), 0, "the sweep still runs with issuance closed");
        _assertSolvent();
    }

    /// @dev A consequence worth knowing operationally: `setCap(0)` closes issuance but leaves
    ///      the sweep running, so it is not a wind-down switch. `pause()` stops both -- and
    ///      redemption still works through it, which is the whole point of the pause design.
    function test_BurnOnly_IsNotAWindDownSwitchOnItsOwn() public {
        vault.setCap(0);
        vm.warp(block.timestamp + 30 days);
        assertGt(vault.harvest(), 0, "the cap does not reach the sweep");

        vault.pause();
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.harvest();

        _burnFor(alice, 10e18); // redemption is never gated, by either switch
    }

    function test_SetCap_RaisingBackReopensIssuance() public {
        vault.setCap(0);
        vault.setCap(CAP);

        assertEq(vault.remainingCap(), CAP - vault.supply());
        _mintFor(carol, 50e18);
        assertEq(vault.supply(), 400e18);
    }

    // -------------------------------------------------------------------------
    // The setter itself
    // -------------------------------------------------------------------------

    function test_SetCap_IsAdminOnly() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0)
            )
        );
        vm.prank(alice);
        vault.setCap(1);
    }

    /// @dev The cap may not be raised past the domain the curve says it can be evaluated in,
    ///      or a mint near the top would revert inside the curve's arithmetic instead.
    function test_SetCap_RejectsACapOutsideTheCurvesDomain() public {
        uint256 domain = vault.curve().maxSafeSupply();
        vm.expectRevert(
            abi.encodeWithSelector(IIAIVault.CapAboveCurveDomain.selector, domain + 1, domain)
        );
        vault.setCap(domain + 1);
    }

    /**
     * @dev Lowering the cap must not depend on the curve in force answering a call. The domain
     *      check exists to stop a *raise* leaving the range the curve can be evaluated in, and
     *      the cap is already inside that range, so lowering cannot leave it.
     *
     *      What makes this load-bearing rather than tidy: closing issuance is the emergency
     *      lever, and one of the emergencies is a curve that reverts on every call. If
     *      `setCap` consulted the curve unconditionally, `setCap(0)` would be unreachable in
     *      exactly that situation -- governance would have to install a working curve first,
     *      briefly reopening issuance on a system it is trying to close.
     */
    function test_SetCap_CanBeLoweredWhileTheCurveIsBroken() public {
        BreakableCurve curve = new BreakableCurve();
        vault.setCurve(IMintCurve(address(curve)));
        curve.breakIt();

        vault.setCap(0);
        assertEq(vault.cap(), 0, "issuance closed without the curve's cooperation");

        // Raising still consults the curve, so a broken one blocks it -- which is the right
        // way round: the check is there to keep a raise inside the curve's domain.
        vm.expectRevert(bytes("broken"));
        vault.setCap(CAP);

        // Redemption carried on throughout.
        _burnFor(alice, 100e18);
    }

    // -------------------------------------------------------------------------
    // Operational tooling has to survive the mode it exists to be used in
    // -------------------------------------------------------------------------

    /**
     * @dev The rehearsal and the deployment check probe live pricing, and every one of those
     *      probes reverts once the cap is under the supply. Unguarded, `./run.sh check` and
     *      `./upgrade.sh rehearse` would break precisely after an emergency cap reduction --
     *      the moment an operator most needs to read the system's state.
     */
    function test_BurnOnly_TheUpgradeRehearsalAndWiringCheckStillRun() public {
        address[] memory watched = new address[](2);
        watched[0] = alice;
        watched[1] = bob;

        Snapshot memory before_ = _capture(vault, iai, registry, watched);
        assertTrue(before_.quotesAvailable, "quotes work while there is headroom");

        vault.setCap(0);

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

        vault.setCap(0);
        assertEq(vault.quoteMintForA0G(type(uint256).max / 2), 0, "zero headroom, zero quote");
    }

    function _expectCapExceeded(uint256 requested, uint256 cap) private {
        vm.expectRevert(abi.encodeWithSelector(IIAIVault.CapExceeded.selector, requested, cap));
    }
}
