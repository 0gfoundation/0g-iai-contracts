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
 *        1. `_grantGovernance` puts every role and every beacon on its target. The deployer
 *           keeps everything it had, so the system is briefly held by both.
 *        2. `_renounceDeployer` gives up the deployer's own roles — and refuses to run unless
 *           the targets already hold everything, so a mistyped address cannot strand the
 *           system with nobody in control.
 *
 *      The gap between the two is the point: governance can be read back, and a Safe can be
 *      confirmed to actually respond, before the only key that still works is given up. Doing
 *      both in one transaction would make a typo unrecoverable.
 *
 *      Beacon ownership is one-step `Ownable`, so there is no pending-acceptance safety net
 *      there at all; that is exactly what step 2's precondition substitutes for.
 */
abstract contract RoleHandover {
    /// @param admin       Holds `DEFAULT_ADMIN_ROLE` on all three contracts: grants and revokes
    ///                    roles, and sets the foundation. Intended to be the multisig.
    /// @param guardian    Holds `PAUSER_ROLE` on the vault and the registry. It can only close
    ///                    issuance, never open a way to move funds, so it can be a lighter key
    ///                    than the others — the point is that it can act quickly.
    /// @param rescuer     Holds `RESCUE_ROLE` on the vault, the only caller of `burnFor`.
    ///                    Intended to be the multisig behind a timelock.
    /// @param beaconOwner Owns all three beacons, and therefore the upgrade key. Intended to be
    ///                    the multisig behind a timelock.
    struct Governance {
        address admin;
        address guardian;
        address rescuer;
        address beaconOwner;
    }

    /// @param d Addresses of the deployed system.
    struct Contracts {
        address iai;
        address vault;
        address registry;
        address iaiBeacon;
        address vaultBeacon;
        address registryBeacon;
    }

    /**
     * @notice Step 1. Grants every role and transfers every beacon to its target holder.
     * @param c Deployed addresses.
     * @param g Intended holders.
     *
     * @dev Deliberately does not touch the deployer's own roles. Both hold the system after
     *      this, which is what makes the result verifiable before step 2.
     *
     *      Safe to re-run: granting a role twice is a no-op, and the beacon transfers are
     *      skipped once ownership has already moved, so a run that failed partway can simply
     *      be repeated.
     */
    function _grantGovernance(Contracts memory c, Governance memory g) internal {
        require(g.admin != address(0), "admin is the zero address");
        require(g.guardian != address(0), "guardian is the zero address");
        require(g.rescuer != address(0), "rescuer is the zero address");
        require(g.beaconOwner != address(0), "beaconOwner is the zero address");

        IAI iai = IAI(c.iai);
        IAIVault vault = IAIVault(c.vault);
        CreditRegistry registry = CreditRegistry(c.registry);

        iai.grantRole(0x00, g.admin);
        vault.grantRole(0x00, g.admin);
        registry.grantRole(0x00, g.admin);

        vault.grantRole(vault.PAUSER_ROLE(), g.guardian);
        registry.grantRole(registry.PAUSER_ROLE(), g.guardian);

        // Nobody holds this after a deployment, so `burnFor` is unreachable until now. That is
        // intentional -- the rescue path opens as an explicit act of governance.
        vault.grantRole(vault.RESCUE_ROLE(), g.rescuer);

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
     *
     * @dev The precondition is the whole safety story. It re-reads governance from the chain
     *      rather than trusting that step 1 ran, so a wrong address, a half-finished step 1, or
     *      a beacon transfer that never landed all stop here with the deployer still in
     *      control — rather than after, with nobody in control.
     */
    function _renounceDeployer(Contracts memory c, Governance memory g, address deployer) internal {
        _assertGovernanceHeld(c, g);

        IAI iai = IAI(c.iai);
        IAIVault vault = IAIVault(c.vault);
        CreditRegistry registry = CreditRegistry(c.registry);

        if (vault.hasRole(vault.PAUSER_ROLE(), deployer)) {
            vault.renounceRole(vault.PAUSER_ROLE(), deployer);
        }
        if (registry.hasRole(registry.PAUSER_ROLE(), deployer)) {
            registry.renounceRole(registry.PAUSER_ROLE(), deployer);
        }
        if (vault.hasRole(vault.RESCUE_ROLE(), deployer)) {
            vault.renounceRole(vault.RESCUE_ROLE(), deployer);
        }

        // Admin last: it is the role that could put the others back.
        if (iai.hasRole(0x00, deployer)) iai.renounceRole(0x00, deployer);
        if (vault.hasRole(0x00, deployer)) vault.renounceRole(0x00, deployer);
        if (registry.hasRole(0x00, deployer)) registry.renounceRole(0x00, deployer);
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
        require(vault.hasRole(vault.RESCUE_ROLE(), g.rescuer), "rescuer cannot rescue");

        require(UpgradeableBeacon(c.iaiBeacon).owner() == g.beaconOwner, "iAI beacon not transferred");
        require(UpgradeableBeacon(c.vaultBeacon).owner() == g.beaconOwner, "vault beacon not transferred");
        require(
            UpgradeableBeacon(c.registryBeacon).owner() == g.beaconOwner, "registry beacon not transferred"
        );
    }

    /**
     * @notice The handover is complete: targets hold everything and the deployer holds nothing.
     * @param c        Deployed addresses.
     * @param g        Intended holders.
     * @param deployer The account that should now hold nothing.
     *
     * @dev Also checks that the vault kept `MINTER_BURNER_ROLE` on iAI. Nothing here touches
     *      it, but it is the one role whose loss would stop the system dead, so it is worth a
     *      line in the check that says the handover is finished.
     */
    function _assertHandoverComplete(Contracts memory c, Governance memory g, address deployer)
        internal
        view
    {
        _assertGovernanceHeld(c, g);

        IAI iai = IAI(c.iai);
        IAIVault vault = IAIVault(c.vault);
        CreditRegistry registry = CreditRegistry(c.registry);

        require(!iai.hasRole(0x00, deployer), "deployer still admins iAI");
        require(!vault.hasRole(0x00, deployer), "deployer still admins the vault");
        require(!registry.hasRole(0x00, deployer), "deployer still admins the registry");
        require(!vault.hasRole(vault.PAUSER_ROLE(), deployer), "deployer can still pause the vault");
        require(
            !registry.hasRole(registry.PAUSER_ROLE(), deployer), "deployer can still pause the registry"
        );
        require(!vault.hasRole(vault.RESCUE_ROLE(), deployer), "deployer can still rescue");

        require(iai.hasRole(iai.MINTER_BURNER_ROLE(), c.vault), "the vault lost its minter role");
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
