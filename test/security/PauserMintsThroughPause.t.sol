// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {SecurityBase} from "./SecurityBase.t.sol";

/**
 * @title PauserMintsThroughPauseTest
 * @notice `PAUSER_ROLE` already contains the privilege `PAUSE_EXEMPT_MINTER_ROLE` was created to
 *         gate behind governance: a guardian can mint while the public is locked out.
 *
 * @dev The exempt role's own NatSpec explains why it exists: admitting one address while paused
 *      "otherwise means unpausing and re-pausing around the transaction, which opens the base of
 *      the curve to everyone for the width of a block". That is only true for an EOA sending
 *      three separate transactions. `pause()` and `unpause()` have no dwell time, and
 *      `whenIssuanceOpen` checks nothing but `paused()` for a caller without the role, so a
 *      guardian that is a contract wallet (or any bundler) executes
 *
 *          unpause() -> a0G.approve() -> mint() -> pause()
 *
 *      atomically. No other transaction can interleave; the public window is zero-width. The
 *      README calls `PAUSER_ROLE` a "lighter key" that "cannot move funds, reprice or grant"
 *      and says the exempt path "opens as an explicit act of governance" (`DEFAULT_ADMIN_ROLE`).
 *      Neither statement survives this test. The vault deploys paused, so this is precisely the
 *      launch-window position the exempt role was meant to control.
 *
 *      A related asymmetry: only `DEFAULT_ADMIN_ROLE` can revoke the exempt role
 *      (`getRoleAdmin` is never changed), so the documented incident response to an oracle
 *      move -- "pause() AND revoke PAUSE_EXEMPT_MINTER_ROLE" -- spans the fast key and the
 *      (timelocked) slow key.
 *
 *      **Fix.** Record the block of the last `unpause()` and have `whenIssuanceOpen` refuse
 *      non-exempt callers in that block; or `_setRoleAdmin(PAUSE_EXEMPT_MINTER_ROLE,
 *      PAUSER_ROLE)` so the incident-response key owns both halves of the response.
 */
contract PauserMintsThroughPauseTest is SecurityBase {
    uint256 internal constant D = 50e18;

    bytes32 internal EXEMPTION;

    function setUp() public override {
        super.setUp();
        EXEMPTION = vault.PAUSE_EXEMPT_MINTER_ROLE();
        // Back to the state the vault deploys in.
        vm.prank(guardian);
        vault.pause();
    }

    /// @notice The rule as documented: while paused, a caller without the exempt role is refused.
    function test_Control_ThePublicIsLockedOutWhilePaused() public {
        uint256 a0GIn = _fund(bob, D);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(bob);
        vault.mint(D, a0GIn, block.timestamp);
    }

    /**
     * @notice The guardian mints through its own pause in one atomic sequence, holding no
     *         exempt role, and leaves the vault paused behind it.
     */
    function test_PauserBundlesUnpauseMintPauseAndMintsWhileThePublicCannot() public {
        assertFalse(vault.hasRole(EXEMPTION, guardian), "guardian was never granted the exempt role");
        assertTrue(vault.paused(), "issuance is closed to the public");
        uint256 supplyBefore = iai.totalSupply();

        uint256 a0GIn = _fund(guardian, D);
        // One transaction from a Safe (MultiSend), or one bundle from a builder: nothing can
        // land between these four calls.
        vm.startPrank(guardian);
        vault.unpause();
        vault.mint(D, a0GIn, block.timestamp);
        vault.pause();
        vm.stopPrank();

        (uint256 locked, uint256 outstanding,) = vault.positionOf(guardian);
        assertEq(outstanding, D, "the guardian minted");
        assertGt(locked, 0, "at the same curve price as anyone else would have paid");
        assertEq(iai.totalSupply(), supplyBefore + D, "supply moved by the guardian's mint only");
        assertTrue(vault.paused(), "and the vault is paused again -- the public never saw it open");

        // The public is still locked out afterwards, exactly as before.
        uint256 bobIn = _fund(bob, D);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(bob);
        vault.mint(D, bobIn, block.timestamp);
    }

    /**
     * @notice The exempt role's stated reason ("opens the base of the curve to everyone for the
     *         width of a block") assumes the toggle cannot be atomic. The guardian's mint above
     *         happened at the very price the exempt role would have paid: same curve, same cap,
     *         same supply.
     */
    function test_TheGuardiansMintIsIndistinguishableFromAnExemptMint() public {
        uint256 s = iai.totalSupply();
        (uint256 quotedDelta0G, uint256 quotedA0GIn) = vault.quoteMint(D);
        assertEq(quotedDelta0G, exponential.cost(s, D), "priced by the shipped table");

        uint256 a0GIn = _fund(guardian, D);
        vm.startPrank(guardian);
        vault.unpause();
        vault.mint(D, a0GIn, block.timestamp);
        vault.pause();
        vm.stopPrank();

        (uint256 locked,,) = vault.positionOf(guardian);
        assertEq(locked, quotedDelta0G, "the guardian paid the exempt minter's price");
        assertEq(a0GIn, quotedA0GIn, "in a0G as well");
    }

    /// @notice Only admin can take the exempt role away; the guardian cannot complete the
    ///         documented two-part incident response on its own.
    function test_OnlyAdminCanRevokeTheExemptRole() public {
        vault.grantRole(EXEMPTION, carol); // admin (this test) grants, as the runbook does
        assertTrue(vault.hasRole(EXEMPTION, carol));

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, bytes32(0))
        );
        vm.prank(guardian);
        vault.revokeRole(EXEMPTION, carol);

        assertTrue(vault.hasRole(EXEMPTION, carol), "still able to mint through the guardian's pause");
        assertEq(vault.getRoleAdmin(EXEMPTION), vault.DEFAULT_ADMIN_ROLE(), "revocation sits with the slow key");
    }
}
