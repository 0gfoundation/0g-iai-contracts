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
 *         ./handover.sh status     read who holds what right now, and confirm the Safe
 *                                  responds -- `grant` is where beacon ownership becomes
 *                                  unrecoverable, not `renounce`
 *         ./handover.sh grant      put every role and beacon on its target
 *         ./handover.sh status     confirm, and check the multisig actually responds
 *         ./handover.sh renounce   give up the deployer's own keys
 *         ./handover.sh renounce --keep vault-pauser,registry-pauser
 *                                  ...all but the named ones
 *
 * @dev Targets come from `deployments/iai-<chainId>.json`: `Admin`, `Guardian` and
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
        console.log("The deployer still holds its own roles, so a wrong Admin is recoverable");
        console.log("from here. Beacon ownership is not: the upgrade key is now the beacon");
        console.log("owner's alone. Verify the targets respond -- a Safe transaction that");
        console.log("executes -- before running renounce.");
    }

    /// @notice Step 2: stand the deployer down completely. Refuses unless step 1 is in place.
    function renounce() public {
        _renounce(Retained(false, false, false, false, false));
    }

    /**
     * @notice Step 2, leaving named roles behind on the deployer.
     * @param keep Comma-separated, from `iai-admin`, `vault-admin`, `registry-admin`,
     *             `vault-pauser`, `registry-pauser`. Empty stands the deployer down fully.
     *
     * @dev The usual reason to pass anything here is `vault-pauser,registry-pauser`: closing
     *      the entrance has to be fast, and a multisig is not. Everything else in the list
     *      exists so that a handover can be staged rather than because keeping it is advisable
     *      -- an admin left on the deployer is the upgrade-grade key the handover is for.
     */
    function renounce(string memory keep) public {
        _renounce(_parseRetained(keep));
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
        console.log("  paused-mint      ", vault.hasRole(vault.PAUSE_EXEMPT_MINTER_ROLE(), deployer));
        console.log("");
        console.log("vault keeps minter ", iai.hasRole(iai.MINTER_BURNER_ROLE(), c.vault));
    }

    // --- internals ---

    /// @param keep Roles the deployer is meant to come out of this still holding.
    function _renounce(Retained memory keep) private {
        (string memory json,) = loadOrInitJson("iai");
        Contracts memory c = _contracts(json);
        Governance memory g = _governance(json);
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        _renounceDeployer(c, g, deployer, keep);
        vm.stopBroadcast();

        _assertHandoverComplete(c, g, deployer, keep);

        console.log("handover complete. governance now held by:");
        _report(c, g);
        console.log("");
        _reportRetained(deployer, keep);
    }

    /**
     * @param keep The list as typed on the command line.
     * @return r   The same thing as flags.
     *
     * @dev An unrecognised name is an error rather than something to skip. The list is typed
     *      once, by hand, to drive a transaction that cannot be undone: `--keep vault-pausers`
     *      quietly renouncing the pausers it was written to save is not a failure mode this
     *      gets to have.
     *
     *      An empty list is refused for the same reason, and refused *here* rather than only
     *      in `handover.sh`. "Keep nothing" is the most destructive reading available and it is
     *      what an unset variable expands to, so the guard has to sit in the half that the
     *      irreversible transaction actually goes through -- a wrapper, a CI step or an
     *      operator adding a flag by hand all reach `renounce(string)` without the shell.
     *      A complete stand-down has its own entry point and says so in the error.
     */
    function _parseRetained(string memory keep) private pure returns (Retained memory r) {
        require(bytes(keep).length != 0, "--keep is empty; call renounce() for a complete stand-down");

        string[] memory names = vm.split(keep, ",");
        for (uint256 i = 0; i < names.length; i++) {
            bytes32 name = keccak256(bytes(names[i]));
            if (name == keccak256(bytes("iai-admin"))) r.iaiAdmin = true;
            else if (name == keccak256(bytes("vault-admin"))) r.vaultAdmin = true;
            else if (name == keccak256(bytes("registry-admin"))) r.registryAdmin = true;
            else if (name == keccak256(bytes("vault-pauser"))) r.vaultPauser = true;
            else if (name == keccak256(bytes("registry-pauser"))) r.registryPauser = true;
            else {
                revert(
                    string.concat(
                        "unknown role in --keep: '",
                        names[i],
                        "' (iai-admin, vault-admin, registry-admin, vault-pauser, registry-pauser)"
                    )
                );
            }
        }
    }

    /// @param deployer The account that has just stood down.
    /// @param keep     What it kept.
    function _reportRetained(address deployer, Retained memory keep) private pure {
        if (!keep.iaiAdmin && !keep.vaultAdmin && !keep.registryAdmin && !keep.vaultPauser
            && !keep.registryPauser) {
            console.log("the deployer holds nothing.");
            return;
        }
        console.log("the deployer", deployer, "still holds:");
        if (keep.iaiAdmin) console.log("  iai-admin");
        if (keep.vaultAdmin) console.log("  vault-admin");
        if (keep.registryAdmin) console.log("  registry-admin");
        if (keep.vaultPauser) console.log("  vault-pauser");
        if (keep.registryPauser) console.log("  registry-pauser");
    }

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
        g.beaconOwner = vm.parseJsonAddress(json, ".BeaconOwner");
    }

    /// @param c Deployed addresses.
    /// @param g Intended holders.
    function _report(Contracts memory c, Governance memory g) private pure {
        console.log("  admin       ", g.admin);
        console.log("  guardian    ", g.guardian);
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
