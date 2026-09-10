// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {JsonUtils} from "./deploy/Utils.s.sol";
import {Constants} from "./deploy/Constants.s.sol";
import {RoleHandover} from "./deploy/RoleHandover.sol";
import {IAI} from "../src/IAI.sol";
import {IAIVault} from "../src/IAIVault.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";

/**
 * @title HandoverScript
 * @notice Moves governance off the deploying account, in two deliberate transactions.
 *
 *         ./handover.sh status     read who holds what right now
 *         ./handover.sh grant      put every role and beacon on its target
 *         ./handover.sh status     confirm, and check the multisig actually responds
 *         ./handover.sh renounce   give up the deployer's own keys
 *
 * @dev Targets come from `deployments/iai-<chainId>.json`: `Admin`, `Guardian`, `Rescuer`,
 *      `BeaconOwner`. They are not written by the deployment and have to be filled in by hand,
 *      which is the intended friction — these are the addresses that own the system.
 *
 *      `renounce` re-reads governance from the chain and refuses unless the targets already
 *      hold everything, so the two steps cannot be collapsed by accident into a mistake.
 */
contract HandoverScript is Script, JsonUtils, Constants, RoleHandover {
    /// @notice Step 1: grant every role and transfer every beacon. Deployer keeps its own.
    function grant() public {
        (string memory json,) = loadOrInitJson("iai");
        Contracts memory c = _contracts(json);
        Governance memory g = _governance(json);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        _grantGovernance(c, g);
        vm.stopBroadcast();

        _assertGovernanceHeld(c, g);

        console.log("granted. governance now held by:");
        _report(c, g);
        console.log("");
        console.log("The deployer still holds its own roles. Verify the targets respond -- a");
        console.log("Safe transaction that executes -- before running renounce.");
    }

    /// @notice Step 2: stand the deployer down. Refuses unless step 1 is fully in place.
    function renounce() public {
        (string memory json,) = loadOrInitJson("iai");
        Contracts memory c = _contracts(json);
        Governance memory g = _governance(json);
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        _renounceDeployer(c, g, deployer);
        vm.stopBroadcast();

        _assertHandoverComplete(c, g, deployer);

        console.log("handover complete. the deployer holds nothing.");
        _report(c, g);
    }

    /// @notice Read-only. Run without `--broadcast`, before and after each step.
    function status() public view {
        (string memory json,) = _read("iai");
        Contracts memory c = _contracts(json);
        Governance memory g = _governance(json);
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        IAI iai = IAI(c.iai);
        IAIVault vault = IAIVault(c.vault);
        CreditRegistry registry = CreditRegistry(c.registry);

        console.log("network        ", networkName());
        console.log("deployer       ", deployer);
        console.log("");
        console.log("target admin       ", g.admin);
        console.log("  holds iAI admin  ", iai.hasRole(0x00, g.admin));
        console.log("  holds vault admin", vault.hasRole(0x00, g.admin));
        console.log("  holds reg admin  ", registry.hasRole(0x00, g.admin));
        console.log("target guardian    ", g.guardian);
        console.log("  can pause vault  ", vault.hasRole(vault.PAUSER_ROLE(), g.guardian));
        console.log("  can pause reg    ", registry.hasRole(registry.PAUSER_ROLE(), g.guardian));
        console.log("target rescuer     ", g.rescuer);
        console.log("  can rescue       ", vault.hasRole(vault.RESCUE_ROLE(), g.rescuer));
        console.log("target beaconOwner ", g.beaconOwner);
        console.log("  owns iAI beacon  ", UpgradeableBeacon(c.iaiBeacon).owner() == g.beaconOwner);
        console.log("  owns vault beacon", UpgradeableBeacon(c.vaultBeacon).owner() == g.beaconOwner);
        console.log("  owns reg beacon  ", UpgradeableBeacon(c.registryBeacon).owner() == g.beaconOwner);
        console.log("");
        console.log("deployer still holds:");
        console.log("  iAI admin        ", iai.hasRole(0x00, deployer));
        console.log("  vault admin      ", vault.hasRole(0x00, deployer));
        console.log("  registry admin   ", registry.hasRole(0x00, deployer));
        console.log("  vault pauser     ", vault.hasRole(vault.PAUSER_ROLE(), deployer));
        console.log("  registry pauser  ", registry.hasRole(registry.PAUSER_ROLE(), deployer));
        console.log("  rescue           ", vault.hasRole(vault.RESCUE_ROLE(), deployer));
        console.log("  paused-mint      ", vault.hasRole(vault.PAUSE_EXEMPT_MINTER_ROLE(), deployer));
        console.log("");
        console.log("vault keeps minter ", iai.hasRole(iai.MINTER_BURNER_ROLE(), c.vault));
    }

    // --- internals ---

    /**
     * @param json The deployment record.
     * @return c The deployed addresses it names.
     */
    function _contracts(string memory json) private pure returns (Contracts memory c) {
        c.iai = vm.parseJsonAddress(json, ".IAI");
        c.vault = vm.parseJsonAddress(json, ".IAIVault");
        c.registry = vm.parseJsonAddress(json, ".CreditRegistry");
        c.iaiBeacon = vm.parseJsonAddress(json, ".IAIBeacon");
        c.vaultBeacon = vm.parseJsonAddress(json, ".IAIVaultBeacon");
        c.registryBeacon = vm.parseJsonAddress(json, ".CreditRegistryBeacon");
    }

    /**
     * @param json The deployment record.
     * @return g The intended holders it names.
     */
    function _governance(string memory json) private pure returns (Governance memory g) {
        g.admin = vm.parseJsonAddress(json, ".Admin");
        g.guardian = vm.parseJsonAddress(json, ".Guardian");
        g.rescuer = vm.parseJsonAddress(json, ".Rescuer");
        g.beaconOwner = vm.parseJsonAddress(json, ".BeaconOwner");
    }

    /// @param c Deployed addresses. @param g Intended holders.
    function _report(Contracts memory c, Governance memory g) private pure {
        console.log("  admin       ", g.admin);
        console.log("  guardian    ", g.guardian);
        console.log("  rescuer     ", g.rescuer);
        console.log("  beaconOwner ", g.beaconOwner);
        c; // silences the unused-parameter warning while keeping the call sites symmetric
    }

    /**
     * @param task Artifact name to read.
     * @return The file's contents and its path.
     * @dev `status` is `view`, so it cannot use the file-creating loader.
     */
    function _read(string memory task) private view returns (string memory, string memory) {
        string memory path = deploymentPath(task);
        return (vm.readFile(path), path);
    }
}
