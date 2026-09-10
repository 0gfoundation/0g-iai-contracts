// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {BaseTest} from "../Base.t.sol";
import {RoleHandover} from "../../script/deploy/RoleHandover.sol";
import {IAIVault} from "../../src/IAIVault.sol";

/**
 * @title HandoverTest
 * @notice Moving governance off the deploying account.
 *
 * @dev This is the one operation with no second chance: renouncing the last admin, or handing
 *      a beacon to an address nobody controls, cannot be undone by any transaction afterwards.
 *      So the tests are written around what must be impossible, not only around the happy path
 *      — every way of arriving at a system nobody governs has a test that says it stops.
 */
contract HandoverTest is BaseTest, RoleHandover {
    address internal multisig = makeAddr("multisig");
    address internal ops = makeAddr("ops");
    address internal timelock = makeAddr("timelock");

    Contracts internal c;
    Governance internal g;

    /// @dev Cached because `vault.PAUSER_ROLE()` is an external call: written inline as an
    ///      argument it is evaluated *before* the surrounding call, so it silently consumes
    ///      the `vm.prank` or `vm.expectRevert` meant for that call.
    bytes32 internal PAUSER;
    bytes32 internal RESCUE;
    bytes32 internal EXEMPTION;

    function setUp() public override {
        super.setUp();

        c = Contracts({
            iai: address(iai),
            vault: address(vault),
            registry: address(registry),
            iaiBeacon: address(iaiBeacon),
            vaultBeacon: address(vaultBeacon),
            registryBeacon: address(registryBeacon)
        });
        g = Governance({admin: multisig, guardian: ops, rescuer: timelock, beaconOwner: timelock});

        PAUSER = vault.PAUSER_ROLE();
        RESCUE = vault.RESCUE_ROLE();
        EXEMPTION = vault.PAUSE_EXEMPT_MINTER_ROLE();

        // Something to lose: an occupied system makes "still works afterwards" meaningful.
        _mintFor(alice, 3e18);
    }

    // --- step 1 ---

    function test_Grant_PutsEveryRoleOnItsTarget() public {
        _grantGovernance(c, g);

        assertTrue(iai.hasRole(0x00, multisig), "iAI admin");
        assertTrue(vault.hasRole(0x00, multisig), "vault admin");
        assertTrue(registry.hasRole(0x00, multisig), "registry admin");
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), ops), "vault pauser");
        assertTrue(registry.hasRole(registry.PAUSER_ROLE(), ops), "registry pauser");
        assertTrue(vault.hasRole(vault.RESCUE_ROLE(), timelock), "rescuer");
        assertEq(iaiBeacon.owner(), timelock, "iAI beacon");
        assertEq(vaultBeacon.owner(), timelock, "vault beacon");
        assertEq(registryBeacon.owner(), timelock, "registry beacon");
    }

    /// @dev The deployer keeps its keys through step 1. That overlap is what makes it possible
    ///      to check the multisig actually responds before the only working key is given up.
    function test_Grant_LeavesTheDeployerInPlace() public {
        _grantGovernance(c, g);

        assertTrue(vault.hasRole(0x00, admin), "deployer still admin");
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), admin), "deployer still pauser");

        vault.setFoundation(makeAddr("elsewhere"));
        assertEq(vault.foundation(), makeAddr("elsewhere"), "and can still act");
    }

    function test_Grant_IsRepeatableAfterAPartialRun() public {
        _grantGovernance(c, g);
        // A second run must not revert on the already-transferred beacons.
        _grantGovernance(c, g);
        _assertGovernanceHeld(c, g);
    }

    function test_Grant_RejectsAZeroTarget() public {
        Governance memory broken = g;
        broken.beaconOwner = address(0);
        vm.expectRevert(bytes("beaconOwner is the zero address"));
        this.grantExternal(c, broken);
    }

    // --- step 2, and the ways it must refuse ---

    function test_Renounce_LeavesTheDeployerWithNothing() public {
        _grantGovernance(c, g);
        _renounceDeployer(c, g, admin);

        _assertHandoverComplete(c, g, admin);

        assertFalse(vault.hasRole(0x00, admin));
        assertFalse(vault.hasRole(vault.PAUSER_ROLE(), admin));
        assertFalse(registry.hasRole(0x00, admin));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, bytes32(0)
            )
        );
        vault.setFoundation(makeAddr("nope"));
    }

    /// @dev The precondition that stops a mistyped address from stranding the system.
    function test_Renounce_RefusesBeforeTheRolesHaveMoved() public {
        vm.expectRevert(bytes("admin does not hold iAI admin"));
        this.renounceExternal(c, g, admin);

        // ...and the deployer is untouched, so there is a way back.
        assertTrue(vault.hasRole(0x00, admin));
    }

    /// @dev Beacon ownership is one-step `Ownable` with no acceptance step, so this check is
    ///      the only thing standing between a typo and permanently unupgradeable contracts.
    function test_Renounce_RefusesIfABeaconWasNotTransferred() public {
        _grantGovernance(c, g);
        // Simulate a step 1 that failed on the last beacon.
        vm.prank(timelock);
        registryBeacon.transferOwnership(admin);

        vm.expectRevert(bytes("registry beacon not transferred"));
        this.renounceExternal(c, g, admin);

        assertTrue(vault.hasRole(0x00, admin), "the deployer is still in control");
    }

    function test_Renounce_RefusesIfTheGuardianCannotPause() public {
        _grantGovernance(c, g);
        vm.prank(multisig);
        registry.revokeRole(registry.PAUSER_ROLE(), ops);

        vm.expectRevert(bytes("guardian cannot pause the registry"));
        this.renounceExternal(c, g, admin);
    }

    /// @dev Reading governance from the chain rather than trusting that step 1 ran is what
    ///      makes the refusals above possible; a flag set in step 1 would not have caught it.
    function test_Renounce_RefusesWhenTargetsWereChangedBetweenTheSteps() public {
        _grantGovernance(c, g);

        Governance memory different = g;
        different.admin = makeAddr("someone else");

        vm.expectRevert(bytes("admin does not hold iAI admin"));
        this.renounceExternal(c, different, admin);
    }

    // --- the system after the handover ---

    function test_TheNewHoldersCanActuallyOperate() public {
        _grantGovernance(c, g);
        _renounceDeployer(c, g, admin);

        vm.prank(ops);
        vault.pause();
        assertTrue(vault.paused(), "guardian can close issuance");
        vm.prank(ops);
        vault.unpause();

        vm.prank(multisig);
        vault.setFoundation(makeAddr("treasury"));
        assertEq(vault.foundation(), makeAddr("treasury"), "admin can set the foundation");

        address secondGuardian = makeAddr("second guardian");
        vm.prank(multisig);
        vault.grantRole(PAUSER, secondGuardian);
        assertTrue(vault.hasRole(PAUSER, secondGuardian), "admin can grant");

        address newImpl = address(new IAIVault());
        vm.prank(timelock);
        vaultBeacon.upgradeTo(newImpl);
    }

    /// @dev `burnFor` is unreachable after a deployment because nobody holds `RESCUE_ROLE`.
    ///      The handover is what opens it, so this is the first moment it can be exercised.
    function test_TheRescuePathOpensOnlyAtHandover() public {
        vm.prank(alice);
        iai.transfer(timelock, 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, timelock, vault.RESCUE_ROLE()
            )
        );
        vm.prank(timelock);
        vault.burnFor(alice, 1e18, block.timestamp);

        _grantGovernance(c, g);

        uint256 before = a0g.balanceOf(alice);
        vm.prank(timelock);
        vault.burnFor(alice, 1e18, block.timestamp);
        assertGt(a0g.balanceOf(alice), before, "collateral went to the position owner");
    }

    /// @dev Unlike `RESCUE_ROLE`, the paused-mint exemption is **not** part of the handover:
    ///      it is granted for one operation and revoked afterwards, so it has no target holder
    ///      to move. Step 1 must therefore leave it shut, and only an explicit grant opens it.
    function test_ThePausedMintExemptionOpensOnlyByAnExplicitGrant() public {
        vm.prank(guardian);
        vault.pause();
        _fund(carol, 1e18);

        _grantGovernance(c, g);
        assertFalse(vault.hasRole(EXEMPTION, timelock), "the handover grants it to nobody");
        assertFalse(vault.hasRole(EXEMPTION, multisig));
        assertFalse(vault.hasRole(EXEMPTION, ops));

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(carol);
        vault.mint(1e18, type(uint256).max, block.timestamp);

        // Admin has moved to the multisig by now, so the grant comes from there.
        vm.prank(multisig);
        vault.grantRole(EXEMPTION, carol);
        vm.prank(carol);
        vault.mint(1e18, type(uint256).max, block.timestamp);
        assertEq(iai.balanceOf(carol), 1e18, "open only once someone said so");
    }

    /// @dev Nothing grants the exemption at deployment, so this is normally vacuous -- but a
    ///      deployer that ever opened it to itself must not keep a key that mints through a
    ///      pause after standing down.
    function test_Renounce_GivesUpThePausedMintExemptionIfTheDeployerEverHeldIt() public {
        vault.grantRole(EXEMPTION, admin);

        _grantGovernance(c, g);
        _renounceDeployer(c, g, admin);

        assertFalse(vault.hasRole(EXEMPTION, admin), "the deployer stood down from it too");
        _assertHandoverComplete(c, g, admin);
    }

    /// @dev Nothing in the handover touches the vault's minter role, but losing it would stop
    ///      the system dead, so the completion check asserts it and so does this.
    function test_UsersAreUnaffected() public {
        _grantGovernance(c, g);
        _renounceDeployer(c, g, admin);

        _mintFor(bob, 2e18);
        assertEq(iai.balanceOf(bob), 2e18, "minting still works");

        _burnFor(alice, 1e18);
        vault.harvest();

        vm.prank(bob);
        iai.approve(address(registry), 1e18);
        vm.prank(bob);
        registry.stake(1e18);
        assertEq(registry.stakedOf(bob), 1e18, "staking still works");
    }

    /// @dev The old key must not be able to undo any of it.
    function test_TheDeployerCannotClawAnythingBack() public {
        _grantGovernance(c, g);
        _renounceDeployer(c, g, admin);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, bytes32(0)
            )
        );
        vault.grantRole(PAUSER, admin);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, PAUSER
            )
        );
        vault.pause();

        address newImpl = address(new IAIVault());
        vm.expectRevert();
        vaultBeacon.upgradeTo(newImpl);
    }

    // --- `vm.expectRevert` needs a call frame ---

    function grantExternal(Contracts memory c_, Governance memory g_) external {
        _grantGovernance(c_, g_);
    }

    function renounceExternal(Contracts memory c_, Governance memory g_, address deployer) external {
        _renounceDeployer(c_, g_, deployer);
    }
}
