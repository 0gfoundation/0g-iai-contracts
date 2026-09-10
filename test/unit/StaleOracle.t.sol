// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "../Base.t.sol";

/**
 * @title StaleOracleTest
 * @notice What the system does when the a0G price feed stops being updated.
 *
 * @dev This is an accepted risk, not a bug: if the upstream oracle goes 21 days without a
 *      write, minting, redemption, harvesting and every quote revert together. It is pinned
 *      here so the behaviour is a known quantity — and so that a later change which quietly
 *      "fixes" it by falling back to a stale rate has to argue with a failing test first.
 *
 *      Redemption is the uncomfortable one. `burn` is deliberately never pausable, but it
 *      still depends on the oracle to convert 0G value into a0G tokens, so an unmaintained
 *      feed closes the exit anyway. That is a real limit on the redemption promise and it is
 *      asserted rather than described.
 */
contract StaleOracleTest is BaseTest {
    bytes internal constant STALE = bytes("Oracle: stale value");

    uint256 internal freshUntil;

    function setUp() public override {
        super.setUp();

        // Positions have to exist before the feed dies, or there is nothing to redeem.
        _mintFor(alice, 5e18);
        _mintFor(bob, 2e18);

        // Auto-accrual keeps `lastUpdated` pinned to the current block, so it can never go
        // stale. Freezing it is what a real oracle looks like when its keeper stops writing.
        oracle.setAutoAccrue(false);
        freshUntil = block.timestamp + ORACLE_MAX_AGE;
    }

    /// @dev Exactly at `maxAge` is still valid: the boundary belongs to the fresh side.
    function test_TheLastFreshSecondStillWorks() public {
        vm.warp(freshUntil);

        assertGt(vault.exchangeRate(), 0);
        (, uint256 a0GIn) = vault.quoteMint(1e18);
        assertGt(a0GIn, 0);

        _mintFor(carol, 1e18);
        _burn(alice, 1e18);
    }

    function test_OneSecondLater_EveryPricedPathReverts() public {
        vm.warp(freshUntil + 1);

        vm.expectRevert(STALE);
        vault.exchangeRate();

        vm.expectRevert(STALE);
        vault.quoteMint(1e18);

        vm.expectRevert(STALE);
        vault.quoteBurn(alice, 1e18);

        vm.expectRevert(STALE);
        vault.quoteMintForA0G(1e18);

        vm.expectRevert(STALE);
        vault.pendingSurplus();
    }

    function test_MintReverts() public {
        // Funded and approved while the feed was still fresh, so the failure is the oracle.
        _fund(carol, 1e18);
        vm.warp(freshUntil + 1);

        vm.expectRevert(STALE);
        vm.prank(carol);
        vault.mint(1e18, type(uint256).max, block.timestamp);
    }

    /// @dev The exit closes too. `burn` carries no pause, but it cannot price without a rate.
    function test_BurnReverts_WhichIsTheRealLimitOnTheRedemptionPromise() public {
        vm.warp(freshUntil + 1);

        vm.expectRevert(STALE);
        vm.prank(alice);
        vault.burn(1e18, block.timestamp);
    }

    function test_HarvestReverts() public {
        vm.warp(freshUntil + 1);

        vm.expectRevert(STALE);
        vault.harvest();
    }

    /// @dev Pausing does not help and is not supposed to: the feed is upstream of everything.
    function test_PausingChangesNothingAboutStaleness() public {
        vm.warp(freshUntil + 1);
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert(STALE);
        vm.prank(alice);
        vault.burn(1e18, block.timestamp);
    }

    /// @dev A single write revives everything, with no intervention on our side.
    function test_ASingleOracleWriteRestoresEverything() public {
        vm.warp(freshUntil + 1);
        vm.expectRevert(STALE);
        vault.exchangeRate();

        oracle.setValue(ER0 * 2);

        assertEq(vault.exchangeRate(), ER0 * 2, "one upstream write is enough");
        _mintFor(carol, 1e18);
        _burn(alice, 1e18);
        vault.harvest();
    }
}
