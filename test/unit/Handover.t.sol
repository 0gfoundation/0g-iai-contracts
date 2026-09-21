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
        g = Governance({admin: multisig, guardian: ops, beaconOwner: timelock});

        PAUSER = vault.PAUSER_ROLE();
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
        assertEq(iaiBeacon.owner(), timelock, "iAI beacon");
        assertEq(vaultBeacon.owner(), timelock, "vault beacon");
        assertEq(registryBeacon.owner(), timelock, "registry beacon");
    }

    /// @dev The deployer keeps its *roles* through step 1, and that overlap is what makes it
    ///      possible to check the multisig responds before the last key that could put one
    ///      back is given up. Its beacons are a different matter -- `Ownable` has one owner,
    ///      so step 1 is where the upgrade key goes, and it does not come back.
    function test_Grant_LeavesTheDeployersRolesInPlaceButTakesItsBeacons() public {
        _grantGovernance(c, g);

        assertTrue(vault.hasRole(0x00, admin), "deployer still admin");
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), admin), "deployer still pauser");

        vault.setFoundation(makeAddr("elsewhere"));
        assertEq(vault.foundation(), makeAddr("elsewhere"), "and can still act");

        assertEq(iaiBeacon.owner(), timelock, "but the iAI beacon has gone");
        assertEq(vaultBeacon.owner(), timelock, "and the vault's");
        assertEq(registryBeacon.owner(), timelock, "and the registry's");

        address newImpl = address(new IAIVault());
        vm.expectRevert(); // Ownable: the deployer is not the owner any more
        vaultBeacon.upgradeTo(newImpl);
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
        _renounceDeployer(c, g, admin, _nothing());

        _assertHandoverComplete(c, g, admin, _nothing());

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
        this.renounceExternal(c, g, admin, _nothing());

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
        this.renounceExternal(c, g, admin, _nothing());

        assertTrue(vault.hasRole(0x00, admin), "the deployer is still in control");
    }

    function test_Renounce_RefusesIfTheGuardianCannotPause() public {
        _grantGovernance(c, g);
        vm.prank(multisig);
        registry.revokeRole(registry.PAUSER_ROLE(), ops);

        vm.expectRevert(bytes("guardian cannot pause the registry"));
        this.renounceExternal(c, g, admin, _nothing());
    }

    /// @dev Reading governance from the chain rather than trusting that step 1 ran is what
    ///      makes the refusals above possible; a flag set in step 1 would not have caught it.
    function test_Renounce_RefusesWhenTargetsWereChangedBetweenTheSteps() public {
        _grantGovernance(c, g);

        Governance memory different = g;
        different.admin = makeAddr("someone else");

        vm.expectRevert(bytes("admin does not hold iAI admin"));
        this.renounceExternal(c, different, admin, _nothing());
    }

    // --- step 2, keeping named roles ---

    /**
     * @dev The retention this deployment is aimed at: governance on the multisig, and the
     *      deploying key left able to close the entrance and nothing else. Closing has to be
     *      fast and a multisig is not, and what the hot key gives up is everything
     *      irreversible -- it can no longer grant, reprice or move a beacon.
     */
    function test_Renounce_KeepsTheRolesItWasToldToKeep() public {
        _grantGovernance(c, g);
        _renounceDeployer(c, g, admin, _pausers());
        _assertHandoverComplete(c, g, admin, _pausers());

        assertFalse(iai.hasRole(0x00, admin), "iAI admin gone");
        assertFalse(vault.hasRole(0x00, admin), "vault admin gone");
        assertFalse(registry.hasRole(0x00, admin), "registry admin gone");

        vault.pause();
        assertTrue(vault.paused(), "the deployer can still close issuance");
        vault.unpause();
        registry.pause();
        assertTrue(registry.paused(), "...and staking");
        registry.unpause();
    }

    /// @dev A kept pauser is not a way back in. It cannot grant, so it cannot restore the
    ///      admin that was just given up, which is what makes keeping it a small decision.
    function test_Renounce_AKeptPauserCannotClawAnythingBack() public {
        _grantGovernance(c, g);
        _renounceDeployer(c, g, admin, _pausers());

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, bytes32(0)
            )
        );
        vault.grantRole(PAUSER, admin);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, bytes32(0)
            )
        );
        vault.setFoundation(makeAddr("nope"));
    }

    /// @dev `Retained` has no field for the exemption and this is why: a key that can still
    ///      mint through the pause it just applied is the one thing a handover has to rule
    ///      out, whatever else it leaves behind.
    function test_Renounce_GivesUpTheExemptionEvenWhileKeepingThePausers() public {
        vault.grantRole(EXEMPTION, admin);

        _grantGovernance(c, g);
        _renounceDeployer(c, g, admin, _pausers());

        assertFalse(vault.hasRole(EXEMPTION, admin), "the exemption is never retained");
        _assertHandoverComplete(c, g, admin, _pausers());
    }

    /// @dev Renouncing only what is held is what makes a staged handover work: keep a role
    ///      now, give it up in a later run without disturbing anything else.
    function test_Renounce_CanBeRunAgainLaterToGiveUpWhatItKept() public {
        _grantGovernance(c, g);
        _renounceDeployer(c, g, admin, _pausers());

        _renounceDeployer(c, g, admin, _nothing());
        _assertHandoverComplete(c, g, admin, _nothing());
    }

    /// @dev Keeping something the deployer does not have is a typo or a misread `status`.
    ///      Caught before anything is given up, rather than reported afterwards as a role
    ///      that went missing.
    function test_Renounce_RefusesToKeepARoleTheDeployerDoesNotHold() public {
        _grantGovernance(c, g);
        vault.renounceRole(PAUSER, admin); // already gone, by hand

        vm.expectRevert(bytes("deployer does not hold vault-pauser"));
        this.renounceExternal(c, g, admin, _pausers());

        assertTrue(vault.hasRole(0x00, admin), "and nothing else was given up");
    }

    /// @dev Naming the deployer as the guardian and then not keeping its pausers would leave
    ///      nobody able to close. `_assertGovernanceHeld` would catch it at the end while
    ///      blaming the guardian; this stops first and names the list, which is what is wrong.
    function test_Renounce_RefusesWhenTheDeployerIsTheGuardianAndKeepsNoPauser() public {
        Governance memory selfGuarded = g;
        selfGuarded.guardian = admin;
        _grantGovernance(c, selfGuarded);

        vm.expectRevert(bytes("guardian is the deployer: keep vault-pauser"));
        this.renounceExternal(c, selfGuarded, admin, _nothing());

        assertTrue(vault.hasRole(PAUSER, admin), "nothing moved");
    }

    /// @dev ...and with the pausers kept, that same configuration is the intended end state:
    ///      the deploying key stays on as the guardian and gives up everything else.
    function test_Renounce_TheDeployerCanStayOnAsTheGuardian() public {
        Governance memory selfGuarded = g;
        selfGuarded.guardian = admin;
        _grantGovernance(c, selfGuarded);

        _renounceDeployer(c, selfGuarded, admin, _pausers());
        _assertHandoverComplete(c, selfGuarded, admin, _pausers());

        vault.pause();
        assertTrue(vault.paused(), "the guardian is the deployer, and it works");
    }

    /// @dev The same refusal for the admin target. Without it the run renounces admin and
    ///      then fails on `_assertGovernanceHeld`, blaming the address in `Admin` rather than
    ///      the list that failed to name it -- nothing is broadcast either way, since a script
    ///      simulates before it sends, but the operator is told the wrong thing.
    function test_Renounce_RefusesWhenTheDeployerIsAlsoTheAdminTarget() public {
        Governance memory selfAdmin = g;
        selfAdmin.admin = admin;
        _grantGovernance(c, selfAdmin);

        vm.expectRevert(bytes("admin is the deployer: keep iai-admin"));
        this.renounceExternal(c, selfAdmin, admin, _nothing());

        assertTrue(vault.hasRole(0x00, admin), "nothing moved");
    }

    /// @dev The third target that can be the deployer, and the one `--keep` has no name for.
    ///      Refused up front like the other two, rather than after everything is renounced --
    ///      where it reads as "grant did not land the beacons" and sends the operator back to
    ///      `grant`, which transfers a beacon to its current owner and does nothing.
    function test_Renounce_RefusesWhenTheDeployerIsAlsoTheBeaconOwner() public {
        Governance memory selfOwned = g;
        selfOwned.beaconOwner = admin; // the beacons never move
        _grantGovernance(c, selfOwned);

        vm.expectRevert(
            bytes("beaconOwner is the deployer: the upgrade key has no name in --keep")
        );
        this.renounceExternal(c, selfOwned, admin, _nothing());

        assertTrue(vault.hasRole(0x00, admin), "nothing moved");
    }

    /// @dev And the completion check says the same thing independently, because that is where
    ///      "the deployer holds nothing beyond what it kept" is actually claimed -- a claim
    ///      about the upgrade key as much as about the roles. Reached here by standing the
    ///      deployer down by hand, since the precondition above stops the script from getting
    ///      into this state at all.
    function test_HandoverComplete_RefusesWhileTheDeployerStillOwnsABeacon() public {
        Governance memory selfOwned = g;
        selfOwned.beaconOwner = admin; // the beacons never move
        _grantGovernance(c, selfOwned);

        iai.renounceRole(0x00, admin);
        vault.renounceRole(0x00, admin);
        registry.renounceRole(0x00, admin);
        vault.renounceRole(PAUSER, admin);
        registry.renounceRole(registry.PAUSER_ROLE(), admin);

        vm.expectRevert(bytes("deployer still owns the iAI beacon"));
        this.assertCompleteExternal(c, selfOwned, admin, _nothing());
    }

    /// @dev The completion check reads both ways. Renouncing cannot be undone, so a retention
    ///      that silently did not happen has to fail as loudly as one that was not wanted.
    function test_HandoverComplete_CatchesARetainedRoleThatWentAnyway() public {
        _grantGovernance(c, g);
        _renounceDeployer(c, g, admin, _nothing());

        vm.expectRevert(bytes("deployer lost a role it was told to keep: vault-pauser"));
        this.assertCompleteExternal(c, g, admin, _pausers());
    }

    function test_HandoverComplete_CatchesARoleThatWasNotGivenUp() public {
        _grantGovernance(c, g);
        _renounceDeployer(c, g, admin, _pausers());

        vm.expectRevert(bytes("deployer still holds: vault-pauser"));
        this.assertCompleteExternal(c, g, admin, _nothing());
    }

    // --- the system after the handover ---

    function test_TheNewHoldersCanActuallyOperate() public {
        _grantGovernance(c, g);
        _renounceDeployer(c, g, admin, _nothing());

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

    /// @dev The paused-mint exemption is **not** part of the handover: it is granted for one
    ///      operation and revoked afterwards, so it has no target holder to move. Step 1 must
    ///      therefore leave it shut, and only an explicit grant opens it.
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
        _renounceDeployer(c, g, admin, _nothing());

        assertFalse(vault.hasRole(EXEMPTION, admin), "the deployer stood down from it too");
        _assertHandoverComplete(c, g, admin, _nothing());
    }

    /// @dev Nothing in the handover touches the vault's minter role, but losing it would stop
    ///      the system dead, so the completion check asserts it and so does this.
    function test_UsersAreUnaffected() public {
        _grantGovernance(c, g);
        _renounceDeployer(c, g, admin, _nothing());

        _mintFor(bob, 2e18);
        assertEq(iai.balanceOf(bob), 2e18, "minting still works");

        _burn(alice, 1e18);
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
        _renounceDeployer(c, g, admin, _nothing());

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

    function assertCompleteExternal(
        Contracts memory c_,
        Governance memory g_,
        address deployer,
        Retained memory keep
    ) external view {
        _assertHandoverComplete(c_, g_, deployer, keep);
    }

    function renounceExternal(
        Contracts memory c_,
        Governance memory g_,
        address deployer,
        Retained memory keep
    ) external {
        _renounceDeployer(c_, g_, deployer, keep);
    }

    /// @dev The complete handover: every field false. Named so the call sites read as intent.
    function _nothing() internal pure returns (Retained memory keep) {}

    /// @dev The one retention this deployment actually plans on: a hot key that can still close.
    function _pausers() internal pure returns (Retained memory keep) {
        keep.vaultPauser = true;
        keep.registryPauser = true;
    }
}
