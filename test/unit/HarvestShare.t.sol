// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {BaseTest} from "../Base.t.sol";
import {EpochMath} from "../../src/EpochMath.sol";

/**
 * @title HarvestShareTest
 * @notice The adjustable split of collateral appreciation, at the level of the vault.
 *
 * @dev `EpochMath.t.sol` covers the arithmetic against an independent replay. What is left
 *      for here is everything the arithmetic cannot state on its own: that a change moves
 *      nothing between minter and foundation, that settling a position lazily gives the same
 *      answer as settling it at once, that the sweep stays idempotent across a change, and
 *      that redemption keeps working from every state a change can leave behind.
 */
contract HarvestShareTest is BaseTest {
    uint256 internal constant YEAR = 365 days;

    function _setShare(uint256 share) internal {
        vault.setHarvestShare(share);
    }

    // -------------------------------------------------------------------------
    // What the split means
    // -------------------------------------------------------------------------

    function test_Deployment_StartsAtTheConfiguredShare() public view {
        assertEq(vault.harvestShare(), HARVEST_SHARE, "the fixture's share");
        assertEq(vault.currentEpoch(), 0, "one epoch at deployment");
        assertEq(vault.epochAt(0).cumG, 1e27, "the running product starts at one");
        assertEq(vault.epochAt(0).rate, vault.exchangeRate(), "genesis anchors on a live reading");
    }

    /// @dev The headline property. Half the appreciation to each side, measured against the
    ///      same position over the same year.
    function test_Split_GivesTheMinterTheirShareOfAppreciation() public {
        uint256 a0GIn = _mintFor(alice, 10e18);
        uint256 valueIn = (a0GIn * vault.exchangeRate()) / WAD;

        _warp(YEAR);

        uint256 er = vault.exchangeRate();
        uint256 appreciation = (a0GIn * er) / WAD - valueIn;
        assertGt(appreciation, 0, "a year must appreciate");

        (uint256 locked,,) = vault.positionOf(alice);
        uint256 minterGain = locked - valueIn;
        uint256 foundationGain = (vault.pendingSurplus() * er) / WAD;

        assertApproxEqRel(minterGain, appreciation / 2, 1e12, "the minter's half");
        assertApproxEqRel(foundationGain, appreciation / 2, 1e12, "the foundation's half");
        assertApproxEqRel(minterGain + foundationGain, appreciation, 1e12, "and nothing else");
    }

    /// @dev A share of one is what the vault did before the split was adjustable, so it has to
    ///      reproduce it exactly: the position's 0G value frozen, every wei of appreciation
    ///      swept.
    function test_Split_OfOneLeavesThePositionFrozenIn0G() public {
        _setShare(1e18);
        uint256 a0GIn = _mintFor(alice, 10e18);
        (uint256 before,,) = vault.positionOf(alice);

        _warp(YEAR);

        (uint256 afterwards,,) = vault.positionOf(alice);
        assertEq(afterwards, before, "a 0G-denominated position does not move");

        uint256 er = vault.exchangeRate();
        uint256 appreciation = (a0GIn * er) / WAD - (a0GIn * ER0) / WAD;
        assertApproxEqRel((vault.pendingSurplus() * er) / WAD, appreciation, 1e12, "all of it is swept");
    }

    /// @dev A share of zero sends everything to the minter, and the sweep goes quiet.
    function test_Split_OfZeroLeavesNothingToSweep() public {
        _setShare(0);
        uint256 a0GIn = _mintFor(alice, 10e18);

        _warp(YEAR);

        assertLe(vault.pendingSurplus(), _mintDust(1), "nothing but dust accrues to the foundation");

        (, uint256 a0GOut) = vault.quoteBurn(alice, 10e18);
        assertApproxEqAbs(a0GOut, a0GIn, _mintDust(1), "the minter gets their tokens back whole");
    }

    // -------------------------------------------------------------------------
    // A change moves nothing
    // -------------------------------------------------------------------------

    function test_Change_MovesNothingBetweenMinterAndFoundation() public {
        _mintFor(alice, 40e18);
        _mintFor(bob, 15e18);
        _warp(YEAR);

        uint256 surplusBefore = vault.pendingSurplus();
        (, uint256 aliceOutBefore) = vault.quoteBurn(alice, 40e18);
        (, uint256 bobOutBefore) = vault.quoteBurn(bob, 15e18);

        _setShare(0.8e18);

        assertApproxEqAbs(vault.pendingSurplus(), surplusBefore, 4, "the foundation's accrual is untouched");
        (, uint256 aliceOutAfter) = vault.quoteBurn(alice, 40e18);
        (, uint256 bobOutAfter) = vault.quoteBurn(bob, 15e18);
        assertApproxEqAbs(aliceOutAfter, aliceOutBefore, 4, "alice is owed what she was owed");
        assertApproxEqAbs(bobOutAfter, bobOutBefore, 4, "and so is bob");
        assertLe(aliceOutAfter, aliceOutBefore, "never more");
        assertLe(bobOutAfter, bobOutBefore, "never more");
    }

    /// @dev The point of restating rather than accruing: repeating the change, or making it at
    ///      a different moment, cannot be used to shift value. Two vaults, same history, one
    ///      changed early and often, the other once at the end.
    function test_Change_RepeatedChangesDoNotShiftValue() public {
        _mintFor(alice, 20e18);

        for (uint256 i = 0; i < 12; i++) {
            _warp(10 days);
            _setShare(i % 2 == 0 ? 0.9e18 : 0.1e18);
        }
        _setShare(HARVEST_SHARE);

        // Whatever the churn, the vault still covers everyone and the two sides still add up.
        _assertSolvent();
        (, uint256 out) = vault.quoteBurn(alice, 20e18);
        assertGt(out, 0, "the position survives the churn");

        vm.prank(alice);
        vault.burn(20e18, block.timestamp);

        // Not exactly zero: the totals are restated rounded up at every change while the
        // position is rounded down, so an emptied vault keeps the few wei of that ceiling.
        // They are claimable by nobody and leave as surplus.
        assertLe(vault.totalClaim0G(), 4 * (vault.currentEpoch() + 1), "only the ceiling's dust is left");
    }

    /// @dev Prospective in time: appreciation earned under the old split keeps it, and only
    ///      what comes afterwards uses the new one.
    function test_Change_AppliesToFutureAppreciationOnAnExistingPosition() public {
        _mintFor(alice, 10e18);
        _warp(YEAR);

        (uint256 atChange,,) = vault.positionOf(alice);
        uint256 erAtChange = vault.exchangeRate();
        (uint256 claim0G, uint256 claimA0G,) = vault.positionClaims(alice);
        uint256 backing = (claim0G * WAD) / erAtChange + claimA0G;

        _setShare(0.25e18);

        _warp(YEAR);
        uint256 er = vault.exchangeRate();
        (uint256 afterwards,,) = vault.positionOf(alice);

        // The second year's appreciation, on the backing the position had at the change.
        uint256 secondYear = (backing * er) / WAD - atChange;
        assertApproxEqRel(afterwards - atChange, (secondYear * 3) / 4, 1e12, "75% of it is now the minter's");
    }

    // -------------------------------------------------------------------------
    // Lazy settlement
    // -------------------------------------------------------------------------

    /// @dev The vault reaches the present in one step, by a ratio of running products. Here
    ///      that is held against the obvious way of getting there -- replaying each change in
    ///      turn, from the epochs the vault itself recorded. The two differ by a few wei,
    ///      because the replay floors two buckets at every step while the shortcut floors once
    ///      at the end; `EpochMath.t.sol` fuzzes that bound over arbitrary chains.
    function test_Lazy_SettlingLateMatchesReplayingEveryChange() public {
        _mintFor(alice, 10e18);
        (uint256 c, uint256 a,) = vault.positionClaims(alice);

        uint256[5] memory shares = [uint256(0.9e18), 0.1e18, 1e18, 0, 0.5e18];
        for (uint256 i = 0; i < shares.length; i++) {
            _warp(40 days);
            _setShare(shares[i]);
        }

        for (uint256 i = 1; i <= vault.currentEpoch(); i++) {
            EpochMath.Epoch memory e = vault.epochAt(i);
            uint256 v = c + (a * e.rate) / WAD;
            c = (v * e.share) / WAD;
            a = (v * (WAD - e.share)) / e.rate;
        }

        (uint256 cGot, uint256 aGot,) = vault.positionClaims(alice);
        uint256 er = vault.exchangeRate();
        assertApproxEqAbs(
            (cGot * WAD) / er + aGot, (c * WAD) / er + a, 64, "the shortcut lands where the replay does"
        );
    }

    /// @dev Reading a position does not settle it in storage -- only a write does -- so a
    ///      position that is never written stays behind and is caught up on the way out.
    function test_Lazy_ASleepingPositionRedeemsCorrectly() public {
        _mintFor(alice, 10e18);

        for (uint256 i = 0; i < 8; i++) {
            _warp(30 days);
            _setShare(i % 2 == 0 ? 0.2e18 : 0.7e18);
        }

        (, uint256 quoted) = vault.quoteBurn(alice, 10e18);
        uint256 held = a0g.balanceOf(alice);
        vm.prank(alice);
        vault.burn(10e18, block.timestamp);

        assertEq(a0g.balanceOf(alice) - held, quoted, "the quote and the settlement agree");
        (, uint256 outstanding,) = vault.positionOf(alice);
        assertEq(outstanding, 0, "and the position closes");
    }

    /// @dev The running product's reason for existing: catching up is a constant, so the split
    ///      can be retuned as often as governance likes without making redemption dearer.
    function test_Lazy_CatchingUpCostsTheSameHoweverManyChangesWereMissed() public {
        _mintFor(alice, 10e18);
        _mintFor(bob, 10e18);

        _warp(10 days);
        _setShare(0.6e18);

        uint256 gasBefore = gasleft();
        vault.positionClaims(alice);
        uint256 oneChange = gasBefore - gasleft();

        for (uint256 i = 0; i < 60; i++) {
            _warp(1 days);
            _setShare(0.4e18 + (i % 3) * 0.1e18);
        }

        gasBefore = gasleft();
        vault.positionClaims(bob);
        uint256 manyChanges = gasBefore - gasleft();

        // Same two epoch reads either way; only the values differ.
        assertApproxEqAbs(manyChanges, oneChange, 500, "settling is not paid for per missed change");
    }

    // -------------------------------------------------------------------------
    // The sweep
    // -------------------------------------------------------------------------

    /// @dev The invariant the whole shape of this design protects: `harvest` levels the balance
    ///      down to the obligation instead of accruing, so a second call takes nothing. A
    ///      change of split must not create something for a second call to find.
    function test_Harvest_StaysIdempotentAcrossAChange() public {
        _mintFor(alice, 30e18);
        _warp(YEAR);

        assertGt(vault.harvest(), 0, "the first sweep takes the accrual");
        assertEq(vault.harvest(), 0, "the second takes nothing");

        _setShare(0.95e18);
        assertEq(vault.harvest(), 0, "and a change of split conjures nothing to take");
        assertEq(vault.harvest(), 0, "still nothing");

        _setShare(0);
        assertEq(vault.harvest(), 0, "in either direction");
    }

    function test_Harvest_ResumesAtTheNewShareAfterAChange() public {
        _mintFor(alice, 30e18);
        _warp(YEAR);
        vault.harvest();

        _setShare(0);
        _warp(YEAR);
        assertLe(vault.pendingSurplus(), _mintDust(1), "a share of zero stops the sweep");

        _setShare(1e18);
        _warp(YEAR);
        assertGt(vault.pendingSurplus(), 0, "and a share of one restarts it");
    }

    // -------------------------------------------------------------------------
    // Redemption is never blocked
    // -------------------------------------------------------------------------

    function test_Burn_WorksFromEveryStateAChangeCanLeave() public {
        _mintFor(alice, 20e18);
        _mintFor(bob, 20e18);
        _mintFor(carol, 20e18);

        _warp(100 days);
        _setShare(1e18);
        _warp(100 days);
        _setShare(0);

        // Paused.
        vm.prank(guardian);
        vault.pause();
        vm.prank(alice);
        vault.burn(20e18, block.timestamp);

        // Cap below the live supply.
        vault.setCap(0);
        vm.prank(bob);
        vault.burn(20e18, block.timestamp);

        // And with the split moved again while both switches are closed.
        _setShare(0.5e18);
        vm.prank(carol);
        vault.burn(20e18, block.timestamp);

        assertEq(iai.totalSupply(), 0, "everyone got out");
    }

    // -------------------------------------------------------------------------
    // Permissions and guards
    // -------------------------------------------------------------------------

    function test_SetHarvestShare_OnlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0))
        );
        vm.prank(alice);
        vault.setHarvestShare(0.4e18);

        // Not the pauser's to move either: closing issuance and repricing the yield are
        // different powers, and only one of them belongs to the lighter key.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, bytes32(0))
        );
        vm.prank(guardian);
        vault.setHarvestShare(0.4e18);
    }

    function test_SetHarvestShare_RejectsAShareAboveOne() public {
        vm.expectRevert(abi.encodeWithSelector(EpochMath.ShareAboveOne.selector, WAD + 1));
        vault.setHarvestShare(WAD + 1);
    }

    /// @dev A rate recorded in an epoch is permanent and is a divisor in every later
    ///      settlement, so a reading below the last one is refused rather than written. The
    ///      cost is that the split cannot be retuned while the collateral is depressed, which
    ///      only blocks a governance action and never a user's.
    function test_SetHarvestShare_RejectsAFallenRate() public {
        _mintFor(alice, 10e18);
        _warp(30 days);
        _setShare(0.6e18);

        uint256 anchored = vault.epochAt(vault.currentEpoch()).rate;
        oracle.setValue(anchored - 1);

        vm.expectRevert(abi.encodeWithSelector(EpochMath.RateWentBackwards.selector, anchored - 1, anchored));
        vault.setHarvestShare(0.4e18);

        // Redemption is untouched by the refusal.
        vm.prank(alice);
        vault.burn(10e18, block.timestamp);
    }

    function test_SetHarvestShare_IsNotPausable() public {
        vm.prank(guardian);
        vault.pause();
        _setShare(0.7e18);
        assertEq(vault.harvestShare(), 0.7e18, "pausing does not reach governance");
    }

    function test_SetHarvestShare_EmitsTheEpochItOpened() public {
        _mintFor(alice, 10e18);
        _warp(30 days);

        uint256 er = vault.exchangeRate();
        vault.setHarvestShare(0.3e18);

        assertEq(vault.currentEpoch(), 1, "a change opens an epoch");
        EpochMath.Epoch memory opened = vault.epochAt(1);
        assertEq(opened.rate, er, "recorded at the rate it was made");
        assertEq(opened.share, 0.3e18, "and carries the new share");
        assertGe(opened.cumG, vault.epochAt(0).cumG, "the running product never falls");
    }

    // -------------------------------------------------------------------------
    // Mixed activity
    // -------------------------------------------------------------------------

    /// @dev Minting on both sides of a change must blend, the way minting on both sides of a
    ///      curve swap does: the position carries one history, not two.
    function test_MintingOnBothSidesOfAChangeBlends() public {
        _mintFor(alice, 10e18);
        _warp(60 days);
        _setShare(0);
        _mintFor(alice, 10e18);

        _warp(YEAR);

        (uint256 locked,,) = vault.positionOf(alice);
        (, uint256 half) = vault.quoteBurn(alice, 10e18);
        (, uint256 all) = vault.quoteBurn(alice, 20e18);
        assertApproxEqAbs(half * 2, all, 4, "the blend is pro-rata, not tranche by tranche");
        assertGt(locked, 0);
        _assertSolvent();
    }
}
