// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IAI} from "../../src/IAI.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {CreditRegistry} from "../../src/CreditRegistry.sol";

/**
 * @title RoleHandover
 * @notice Moving governance off the deploying account and onto its intended holders.
 *
 * @dev Deployment leaves `DEFAULT_ADMIN_ROLE`, `PAUSER_ROLE` and all three beacons on one EOA,
 *      which is the right thing during a deployment and the wrong thing afterwards. This moves
 *      them in **two separate transactions**:
 *
 *        1. `_grantGovernance` puts every role and every beacon on its target. The roles are
 *           additive -- the deployer keeps its own, so each is briefly held by both -- but a
 *           beacon has exactly one owner, so the upgrade key moves here and not in step 2.
 *        2. `_renounceDeployer` gives up the deployer's own roles — all of them by default,
 *           or all but a named few — and refuses to run unless the targets already hold
 *           everything, so a mistyped address cannot strand the system with nobody in
 *           control.
 *
 *      The gap between the two is the point for the roles: they can be read back, and a Safe
 *      can be confirmed to actually respond, before the last key that could put one back is
 *      given up. Doing both in one transaction would make a typo unrecoverable.
 *
 *      The gap does not cover the beacons. `Ownable` is one-step, with no acceptance and no
 *      admin override, so a wrong `beaconOwner` is already beyond recovery when step 1
 *      returns, and step 2's precondition can only report it. The target has to be confirmed
 *      to respond *before* step 1, not only between the two.
 */
abstract contract RoleHandover {
    /// @param admin       Holds `DEFAULT_ADMIN_ROLE` on all three contracts: grants and revokes
    ///                    roles, and sets the foundation. Intended to be the multisig.
    /// @param guardian    Holds `PAUSER_ROLE` on the vault and the registry: it closes issuance
    ///                    and staking, and reopens them -- not a one-way switch. `harvest` is
    ///                    `pause`-gated too, so it can also withhold the foundation's sweep for
    ///                    as long as it keeps the vault closed. What it cannot do is move funds,
    ///                    reprice or grant anything, which is what lets it be a lighter key than
    ///                    the others -- the point being that closing has to be fast.
    /// @param beaconOwner Owns all three beacons, and therefore the upgrade key. Intended to be
    ///                    the multisig behind a timelock.
    ///                    There is deliberately no field for `PAUSE_EXEMPT_MINTER_ROLE`: it is
    ///                    not a governance seat but a permission granted for one operation and
    ///                    revoked afterwards, so nominating a permanent holder here would force
    ///                    the exemption open as a precondition of moving governance off the
    ///                    deployer. The handover only checks the deployer does not keep it.
    struct Governance {
        address admin;
        address guardian;
        address beaconOwner;
    }

    /// The deployed system: the three proxies, and the beacon behind each of them.
    struct Contracts {
        address iai;
        address vault;
        address registry;
        address iaiBeacon;
        address vaultBeacon;
        address registryBeacon;
    }

    /**
     * @notice What the deploying account keeps when it stands down.
     *
     * @dev Every field defaults to false, so the zero-valued struct is the complete handover
     *      that a deployment is aimed at. A field set to true is a deliberate, named
     *      exception -- typically the two pausers, left on a hot key because closing the
     *      entrance has to be fast and a multisig cannot be. What that costs is that the old
     *      key can still close issuance and withhold the sweep; what it does not cost is
     *      anything irreversible, since a pauser can neither move funds nor grant.
     *
     *      There is deliberately no field for `PAUSE_EXEMPT_MINTER_ROLE`. It is not a seat
     *      but a permission granted for one operation and revoked after it, and one of the
     *      things a handover establishes is that the old key cannot mint through a pause. A
     *      retained one would be exactly the key nobody thinks to look for later, so it is
     *      given up unconditionally and there is no spelling of this struct that keeps it.
     */
    struct Retained {
        /// `DEFAULT_ADMIN_ROLE` on `IAI`: grants `MINTER_BURNER_ROLE`, and so mints without limit.
        bool iaiAdmin;
        /// `DEFAULT_ADMIN_ROLE` on `IAIVault`: reprices issuance, moves the ceiling, redirects yield.
        bool vaultAdmin;
        /// `DEFAULT_ADMIN_ROLE` on `CreditRegistry`: sets the unstaking cooldown.
        bool registryAdmin;
        /// `PAUSER_ROLE` on `IAIVault`: closes and reopens issuance, and withholds `harvest`.
        bool vaultPauser;
        /// `PAUSER_ROLE` on `CreditRegistry`: closes and reopens staking.
        bool registryPauser;
    }

    /**
     * @notice Step 1. Grants every role and transfers every beacon to its target holder.
     * @param c Deployed addresses.
     * @param g Intended holders.
     *
     * @dev Deliberately does not touch the deployer's own roles, so each is held by both
     *      until step 2 -- which is what makes the result verifiable before any of them is
     *      given up. The beacons are not like that: `Ownable` has a single owner, so this is
     *      where the upgrade key leaves the deployer, and nothing here or later hands it
     *      back.
     *
     *      Safe to re-run: granting a role twice is a no-op, and the beacon transfers are
     *      skipped once ownership has already moved, so a run that failed partway can simply
     *      be repeated.
     */
    function _grantGovernance(Contracts memory c, Governance memory g) internal {
        require(g.admin != address(0), "admin is the zero address");
        require(g.guardian != address(0), "guardian is the zero address");
        require(g.beaconOwner != address(0), "beaconOwner is the zero address");

        IAI iai = IAI(c.iai);
        IAIVault vault = IAIVault(c.vault);
        CreditRegistry registry = CreditRegistry(c.registry);

        iai.grantRole(0x00, g.admin);
        vault.grantRole(0x00, g.admin);
        registry.grantRole(0x00, g.admin);

        vault.grantRole(vault.PAUSER_ROLE(), g.guardian);
        registry.grantRole(registry.PAUSER_ROLE(), g.guardian);

        _transferBeacon(c.iaiBeacon, g.beaconOwner);
        _transferBeacon(c.vaultBeacon, g.beaconOwner);
        _transferBeacon(c.registryBeacon, g.beaconOwner);
    }

    /**
     * @notice Step 2. Gives up the deployer's own roles, once the targets hold everything.
     * @param c        Deployed addresses.
     * @param g        Intended holders.
     * @param deployer The account being stood down. Must be the caller: `renounceRole` only
     *                 accepts an account renouncing itself.
     * @param keep     Roles the deployer is meant to come out of this still holding. The
     *                 zero-valued struct stands it down completely.
     *
     * @dev The precondition is the whole safety story. It re-reads governance from the chain
     *      rather than trusting that step 1 ran, so a wrong address, a half-finished step 1, or
     *      a beacon transfer that never landed all stop here with the deployer still in
     *      control — rather than after, with nobody in control.
     *
     *      Renouncing only what is held keeps this re-runnable, which is also what makes a
     *      staged handover work: run it keeping a role, and run it again later without.
     */
    function _renounceDeployer(
        Contracts memory c,
        Governance memory g,
        address deployer,
        Retained memory keep
    ) internal {
        _assertGovernanceHeld(c, g);
        _assertRetainable(c, g, deployer, keep);

        IAI iai = IAI(c.iai);
        IAIVault vault = IAIVault(c.vault);
        CreditRegistry registry = CreditRegistry(c.registry);

        if (!keep.vaultPauser && vault.hasRole(vault.PAUSER_ROLE(), deployer)) {
            vault.renounceRole(vault.PAUSER_ROLE(), deployer);
        }
        if (!keep.registryPauser && registry.hasRole(registry.PAUSER_ROLE(), deployer)) {
            registry.renounceRole(registry.PAUSER_ROLE(), deployer);
        }
        // Nothing grants this at deployment, so normally a no-op, and `keep` has no field for
        // it on purpose. If the deployer ever opened the exemption to itself, standing down
        // has to close it, or the handover leaves behind a key able to mint through a pause
        // that no check would mention.
        bytes32 exemption = vault.PAUSE_EXEMPT_MINTER_ROLE();
        if (vault.hasRole(exemption, deployer)) {
            vault.renounceRole(exemption, deployer);
        }

        // Admin last: it is the role that could put the others back.
        if (!keep.iaiAdmin && iai.hasRole(0x00, deployer)) iai.renounceRole(0x00, deployer);
        if (!keep.vaultAdmin && vault.hasRole(0x00, deployer)) vault.renounceRole(0x00, deployer);
        if (!keep.registryAdmin && registry.hasRole(0x00, deployer)) {
            registry.renounceRole(0x00, deployer);
        }
    }

    /**
     * @notice The retention list describes a state the deployer can actually be left in.
     * @param c        Deployed addresses.
     * @param g        Intended holders.
     * @param deployer The account being stood down.
     * @param keep     Roles it is meant to keep.
     *
     * @dev Both of these would otherwise surface as a confusing failure after the renouncing
     *      is done rather than a clear one before it starts:
     *
     *      - Keeping a role the deployer does not hold is a typo or a misreading of `status`,
     *        and the completion check would report it as a role that went missing.
     *      - Naming the deployer as a target and then not keeping the matching roles leaves
     *        nobody holding them, which `_assertGovernanceHeld` would catch at the end while
     *        blaming the target address rather than the list. The deployer being its own
     *        `Admin` or `Guardian` is a staging record or a copy-paste, not a handover, but it
     *        should be said in those words rather than as "admin does not hold iAI admin".
     */
    function _assertRetainable(
        Contracts memory c,
        Governance memory g,
        address deployer,
        Retained memory keep
    ) internal view {
        IAI iai = IAI(c.iai);
        IAIVault vault = IAIVault(c.vault);
        CreditRegistry registry = CreditRegistry(c.registry);

        if (keep.iaiAdmin) {
            require(iai.hasRole(0x00, deployer), "deployer does not hold iai-admin");
        }
        if (keep.vaultAdmin) {
            require(vault.hasRole(0x00, deployer), "deployer does not hold vault-admin");
        }
        if (keep.registryAdmin) {
            require(registry.hasRole(0x00, deployer), "deployer does not hold registry-admin");
        }
        if (keep.vaultPauser) {
            require(vault.hasRole(vault.PAUSER_ROLE(), deployer), "deployer does not hold vault-pauser");
        }
        if (keep.registryPauser) {
            require(
                registry.hasRole(registry.PAUSER_ROLE(), deployer),
                "deployer does not hold registry-pauser"
            );
        }

        if (g.guardian == deployer) {
            require(keep.vaultPauser, "guardian is the deployer: keep vault-pauser");
            require(keep.registryPauser, "guardian is the deployer: keep registry-pauser");
        }
        if (g.admin == deployer) {
            require(keep.iaiAdmin, "admin is the deployer: keep iai-admin");
            require(keep.vaultAdmin, "admin is the deployer: keep vault-admin");
            require(keep.registryAdmin, "admin is the deployer: keep registry-admin");
        }
        // The third of the same shape, and the one with no way to say yes: `Retained` has no
        // name for the upgrade key. Without this the run renounces everything, fails at the
        // end on a beacon the deployer still owns, and reads as "grant did not land" -- which
        // sends the operator back to `grant`, where transferring a beacon to its current owner
        // is a no-op, and round the loop again.
        require(
            g.beaconOwner != deployer, "beaconOwner is the deployer: the upgrade key has no name in --keep"
        );
    }

    /**
     * @notice Every role and beacon is on its target. Says nothing about the deployer.
     * @param c Deployed addresses.
     * @param g Intended holders.
     */
    function _assertGovernanceHeld(Contracts memory c, Governance memory g) internal view {
        IAI iai = IAI(c.iai);
        IAIVault vault = IAIVault(c.vault);
        CreditRegistry registry = CreditRegistry(c.registry);

        require(iai.hasRole(0x00, g.admin), "admin does not hold iAI admin");
        require(vault.hasRole(0x00, g.admin), "admin does not hold vault admin");
        require(registry.hasRole(0x00, g.admin), "admin does not hold registry admin");
        require(vault.hasRole(vault.PAUSER_ROLE(), g.guardian), "guardian cannot pause the vault");
        require(
            registry.hasRole(registry.PAUSER_ROLE(), g.guardian), "guardian cannot pause the registry"
        );

        require(UpgradeableBeacon(c.iaiBeacon).owner() == g.beaconOwner, "iAI beacon not transferred");
        require(UpgradeableBeacon(c.vaultBeacon).owner() == g.beaconOwner, "vault beacon not transferred");
        require(
            UpgradeableBeacon(c.registryBeacon).owner() == g.beaconOwner, "registry beacon not transferred"
        );
    }

    /**
     * @notice The handover is complete: targets hold everything, and the deployer holds
     *         exactly what it was told to keep and nothing else.
     * @param c        Deployed addresses.
     * @param g        Intended holders.
     * @param deployer The account that has just stood down.
     * @param keep     Roles it was meant to come out still holding.
     *
     * @dev Every role is checked in both directions rather than only for absence, so a
     *      retention that silently did not take is caught here as loudly as one that was
     *      supposed to be given up and was not.
     *
     *      Beacon ownership is checked too, although nothing here moves it. `Retained` has no
     *      field for it, so "the deployer holds nothing beyond `keep`" is a claim about the
     *      upgrade key as much as about the roles -- and a record naming the deployer as its
     *      own `BeaconOwner` satisfies every other check here while leaving that key exactly
     *      where the handover was run to move it from.
     *
     *      Also checks that the vault kept `MINTER_BURNER_ROLE` on iAI. Nothing here touches
     *      it, but it is the one role whose loss would stop the system dead, so it is worth a
     *      line in the check that says the handover is finished.
     */
    function _assertHandoverComplete(
        Contracts memory c,
        Governance memory g,
        address deployer,
        Retained memory keep
    ) internal view {
        _assertGovernanceHeld(c, g);

        IAI iai = IAI(c.iai);
        IAIVault vault = IAIVault(c.vault);
        CreditRegistry registry = CreditRegistry(c.registry);

        _assertMatchesIntent(iai.hasRole(0x00, deployer), keep.iaiAdmin, "iai-admin");
        _assertMatchesIntent(vault.hasRole(0x00, deployer), keep.vaultAdmin, "vault-admin");
        _assertMatchesIntent(registry.hasRole(0x00, deployer), keep.registryAdmin, "registry-admin");
        _assertMatchesIntent(
            vault.hasRole(vault.PAUSER_ROLE(), deployer), keep.vaultPauser, "vault-pauser"
        );
        _assertMatchesIntent(
            registry.hasRole(registry.PAUSER_ROLE(), deployer), keep.registryPauser, "registry-pauser"
        );

        require(
            !vault.hasRole(vault.PAUSE_EXEMPT_MINTER_ROLE(), deployer),
            "deployer can still mint while paused"
        );

        require(UpgradeableBeacon(c.iaiBeacon).owner() != deployer, "deployer still owns the iAI beacon");
        require(
            UpgradeableBeacon(c.vaultBeacon).owner() != deployer, "deployer still owns the vault beacon"
        );
        require(
            UpgradeableBeacon(c.registryBeacon).owner() != deployer,
            "deployer still owns the registry beacon"
        );

        require(iai.hasRole(iai.MINTER_BURNER_ROLE(), c.vault), "the vault lost its minter role");
    }

    /**
     * @notice One role landed where the retention list said it would.
     * @param held Whether the deployer still holds it.
     * @param kept Whether it was meant to.
     * @param name The role's name in the retention list, so the error names what to fix.
     *
     * @dev Checked in both directions. A role that was supposed to be given up and was not is
     *      the obvious failure; a role that was supposed to stay and is gone is the one worth
     *      spelling out, because renouncing cannot be undone -- if `vault-pauser` was meant to
     *      stay on a hot key and went instead, nothing short of the multisig puts it back.
     */
    function _assertMatchesIntent(bool held, bool kept, string memory name) private pure {
        if (kept) {
            require(held, string.concat("deployer lost a role it was told to keep: ", name));
        } else {
            require(!held, string.concat("deployer still holds: ", name));
        }
    }

    /**
     * @param beacon   Beacon to transfer.
     * @param newOwner Account to transfer it to.
     * @dev Skipped when ownership has already moved, so step 1 can be repeated.
     */
    function _transferBeacon(address beacon, address newOwner) private {
        if (UpgradeableBeacon(beacon).owner() != newOwner) {
            UpgradeableBeacon(beacon).transferOwnership(newOwner);
        }
    }
}
