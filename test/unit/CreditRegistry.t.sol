// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "../Base.t.sol";
import {ICreditRegistry} from "../../src/interfaces/ICreditRegistry.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract CreditRegistryTest is BaseTest {
    uint256 internal constant STAKE = 40e18;

    function setUp() public override {
        super.setUp();
        _mintFor(alice, 100e18);
        _mintFor(bob, 100e18);
        vm.prank(alice);
        iai.approve(address(registry), type(uint256).max);
        vm.prank(bob);
        iai.approve(address(registry), type(uint256).max);
    }

    /// @dev totalStaked must equal the contract's actual token balance and the sum of both
    ///      per-user buckets. Tokens in cooldown are still held, just no longer earning.
    function _assertRegistryAccounting(address[2] memory who) internal view {
        uint256 sum;
        for (uint256 i = 0; i < who.length; i++) {
            ICreditRegistry.StakedInfo memory info = registry.stakedInfoOf(who[i]);
            sum += info.amountStaked + info.coolDownAmount;
        }
        assertEq(sum, registry.totalStaked(), "buckets must sum to totalStaked");
        assertEq(registry.totalStaked(), iai.balanceOf(address(registry)), "totalStaked must equal holdings");
    }

    // -------------------------------------------------------------------------
    // Stake
    // -------------------------------------------------------------------------

    function test_Stake_EscrowsAndStartsEarning() public {
        vm.prank(alice);
        registry.stake(STAKE);

        assertEq(registry.stakedOf(alice), STAKE, "earning immediately");
        assertEq(registry.totalStaked(), STAKE);
        assertEq(iai.balanceOf(address(registry)), STAKE, "tokens genuinely escrowed");
        assertEq(iai.balanceOf(alice), 100e18 - STAKE);
        _assertRegistryAccounting([alice, bob]);
    }

    function test_Stake_RequiresApproval() public {
        vm.prank(carol);
        iai.approve(address(registry), 0);
        _mintFor(carol, 10e18);
        vm.expectRevert();
        vm.prank(carol);
        registry.stake(1e18);
    }

    function test_Stake_RevertsOnZero() public {
        vm.expectRevert(ICreditRegistry.ZeroAmount.selector);
        vm.prank(alice);
        registry.stake(0);
    }

    function test_Stake_EventCarriesPostState() public {
        vm.prank(alice);
        registry.stake(STAKE);

        vm.expectEmit(true, false, false, true, address(registry));
        emit ICreditRegistry.Staked(alice, 10e18, STAKE + 10e18, STAKE + 10e18);
        vm.prank(alice);
        registry.stake(10e18);
    }

    // -------------------------------------------------------------------------
    // Initiate unstake
    // -------------------------------------------------------------------------

    /// @dev Earning has to stop the moment a withdrawal starts. If it kept accruing until
    ///      the cooldown elapsed, a holder could stake just before an off-chain snapshot,
    ///      unstake just after, and collect a full period while staying liquid.
    function test_InitiateUnstake_StopsEarningImmediately() public {
        vm.prank(alice);
        registry.stake(STAKE);

        vm.prank(alice);
        registry.initiateUnstake(STAKE);

        assertEq(registry.stakedOf(alice), 0, "no longer earning");
        ICreditRegistry.StakedInfo memory info = registry.stakedInfoOf(alice);
        assertEq(info.coolDownAmount, STAKE);
        assertEq(info.coolDownEnd, block.timestamp + COOLDOWN);
        assertEq(registry.totalStaked(), STAKE, "still held, so the total is unchanged");
        _assertRegistryAccounting([alice, bob]);
    }

    function test_InitiateUnstake_RevertsBeyondStake() public {
        vm.prank(alice);
        registry.stake(STAKE);
        vm.expectRevert(abi.encodeWithSelector(ICreditRegistry.InsufficientStake.selector, STAKE + 1, STAKE));
        vm.prank(alice);
        registry.initiateUnstake(STAKE + 1);
    }

    /// @dev Adding to a withdrawal already in flight restarts the clock on the whole amount.
    ///      One storage slot instead of an unbounded queue; the cost is a UX detail that has
    ///      to be surfaced, so it is pinned here.
    function test_InitiateUnstake_SecondCallRestartsTheWholeClock() public {
        vm.prank(alice);
        registry.stake(STAKE);

        vm.prank(alice);
        registry.initiateUnstake(10e18);
        uint256 firstEnd = registry.stakedInfoOf(alice).coolDownEnd;

        vm.warp(block.timestamp + COOLDOWN - 1);
        vm.prank(alice);
        registry.initiateUnstake(10e18);

        ICreditRegistry.StakedInfo memory info = registry.stakedInfoOf(alice);
        assertEq(info.coolDownAmount, 20e18, "amounts accumulate");
        assertGt(info.coolDownEnd, firstEnd, "and the whole amount waits again");

        // The first tranche would have matured by now, but the restart holds it back.
        vm.warp(firstEnd + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICreditRegistry.CooldownNotOver.selector, info.coolDownEnd, block.timestamp
            )
        );
        vm.prank(alice);
        registry.unstake();
    }

    // -------------------------------------------------------------------------
    // Unstake
    // -------------------------------------------------------------------------

    function test_Unstake_RevertsBeforeCooldownElapses() public {
        vm.prank(alice);
        registry.stake(STAKE);
        vm.prank(alice);
        registry.initiateUnstake(STAKE);

        uint256 end = registry.stakedInfoOf(alice).coolDownEnd;
        vm.warp(end - 1);
        vm.expectRevert(abi.encodeWithSelector(ICreditRegistry.CooldownNotOver.selector, end, end - 1));
        vm.prank(alice);
        registry.unstake();
    }

    function test_Unstake_ReturnsEverythingMaturedAndClearsTheSlot() public {
        vm.prank(alice);
        registry.stake(STAKE);
        vm.prank(alice);
        registry.initiateUnstake(STAKE);

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(alice);
        registry.unstake();

        ICreditRegistry.StakedInfo memory info = registry.stakedInfoOf(alice);
        assertEq(info.coolDownAmount, 0, "must be cleared or it could be withdrawn twice");
        assertEq(info.coolDownEnd, 0);
        assertEq(registry.totalStaked(), 0);
        assertEq(iai.balanceOf(alice), 100e18, "whole stake returned");
        _assertRegistryAccounting([alice, bob]);
    }

    function test_Unstake_CannotBeReplayed() public {
        vm.prank(alice);
        registry.stake(STAKE);
        vm.prank(alice);
        registry.initiateUnstake(STAKE);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(alice);
        registry.unstake();

        vm.expectRevert(ICreditRegistry.NothingInCooldown.selector);
        vm.prank(alice);
        registry.unstake();
    }

    function test_Unstake_RevertsWithNothingPending() public {
        vm.expectRevert(ICreditRegistry.NothingInCooldown.selector);
        vm.prank(alice);
        registry.unstake();
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    /// @dev Same rule as the vault: the switch stops entry, never exit.
    function test_Pause_StopsStakingButNeverWithdrawal() public {
        vm.prank(alice);
        registry.stake(STAKE);

        vm.prank(guardian);
        registry.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(alice);
        registry.stake(1e18);

        vm.prank(alice);
        registry.initiateUnstake(STAKE);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(alice);
        registry.unstake();

        assertEq(iai.balanceOf(alice), 100e18, "exit worked throughout the pause");
    }

    // -------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------

    function test_SetCooldownDuration_OnlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0)
            )
        );
        vm.prank(alice);
        registry.setCooldownDuration(1 hours);

        registry.setCooldownDuration(1 hours);
        assertEq(registry.cooldownDuration(), 1 hours);
    }

    /// @dev A withdrawal already in flight keeps the end time it was given, so a governance
    ///      change cannot retroactively extend someone's wait.
    function test_SetCooldownDuration_DoesNotAffectInFlightWithdrawals() public {
        vm.prank(alice);
        registry.stake(STAKE);
        vm.prank(alice);
        registry.initiateUnstake(STAKE);
        uint256 end = registry.stakedInfoOf(alice).coolDownEnd;

        registry.setCooldownDuration(30 days);

        assertEq(registry.stakedInfoOf(alice).coolDownEnd, end, "in-flight end time is fixed");
        vm.warp(end);
        vm.prank(alice);
        registry.unstake();
        assertEq(iai.balanceOf(alice), 100e18);
    }

    // -------------------------------------------------------------------------
    // Interaction with redemption
    // -------------------------------------------------------------------------

    /// @dev Staked tokens are not in the holder's wallet, so redeeming collateral requires
    ///      withdrawing them first. The promise that redemption is always available comes
    ///      with that caveat, and it is a consequence of the holder's own prior choice.
    function test_StakedTokensMustBeWithdrawnBeforeRedeeming() public {
        vm.prank(alice);
        registry.stake(100e18);

        vm.expectRevert(); // ERC20InsufficientBalance inside iAI.burn
        vm.prank(alice);
        vault.burn(100e18, 0, block.timestamp);

        vm.prank(alice);
        registry.initiateUnstake(100e18);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(alice);
        registry.unstake();

        _burnFor(alice, 100e18);
        (, uint256 outstanding,) = vault.positionOf(alice);
        assertEq(outstanding, 0, "redemption works once the tokens are back");
    }

    function test_Accounting_HoldsAcrossMixedActivity() public {
        vm.prank(alice);
        registry.stake(60e18);
        vm.prank(bob);
        registry.stake(25e18);
        vm.prank(alice);
        registry.initiateUnstake(20e18);
        _assertRegistryAccounting([alice, bob]);

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(alice);
        registry.unstake();
        vm.prank(bob);
        registry.initiateUnstake(25e18);
        _assertRegistryAccounting([alice, bob]);

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(bob);
        registry.unstake();
        _assertRegistryAccounting([alice, bob]);
        assertEq(registry.totalStaked(), 40e18, "only alice's remaining stake is left");
    }
}
