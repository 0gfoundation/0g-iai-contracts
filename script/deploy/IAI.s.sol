// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";

import {JsonUtils} from "./Utils.s.sol";
import {Constants} from "./Constants.s.sol";
import {IAIDeployer} from "./IAIDeployer.sol";
import {IAI} from "../../src/IAI.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {CreditRegistry} from "../../src/CreditRegistry.sol";

/**
 * @title IAIScript
 * @notice Deploys the iAI system and records it, plus the handful of operational calls that
 *         are needed after launch.
 *
 * @dev The wiring itself lives in `IAIDeployer`, which the test fixture also inherits, so
 *      the topology this script produces is the one every test runs against.
 *
 *      Parameters come from `deployments/iai-<chainId>.json`; the resulting addresses are
 *      written back to the same file. Secrets only ever come from the environment.
 */
contract IAIScript is Script, JsonUtils, Constants, IAIDeployer {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        (string memory json, string memory path) = loadOrInitJson("iai");

        Config memory c = Config({
            a0G: vm.parseJsonAddress(json, ".A0G"),
            foundation: vm.parseJsonAddress(json, ".Foundation"),
            r0: vm.parseJsonUint(json, ".R0"),
            cap: vm.parseJsonUint(json, ".Cap"),
            target: vm.parseJsonUint(json, ".Target"),
            cooldownDuration: vm.parseJsonUint(json, ".CooldownDuration"),
            name: vm.parseJsonString(json, ".Name"),
            symbol: vm.parseJsonString(json, ".Symbol")
        });

        vm.startBroadcast(pk);
        Deployment memory d = _deployIAISystem(c, deployer, deployer);
        vm.stopBroadcast();

        console.log("network        ", networkName());
        console.log("iAI            ", d.iai);
        console.log("IAIVault       ", d.vault);
        console.log("CreditRegistry ", d.registry);
        console.log("slope          ", d.slope);
        console.log("");
        console.log("Issuance is PAUSED. Open it with --sig 'unpause()' when ready.");
        console.log("DEFAULT_ADMIN and the beacon owner are the deployer; hand them to the");
        console.log("multisig before launch.");

        // Seed with the file as it stands so nothing already recorded is lost -- the mock
        // addresses, and any notes the operator keeps alongside them.
        string memory obj = "iai";
        vm.serializeJson(obj, json);

        // Echo the inputs so a rerun of this script cannot silently drop them.
        vm.serializeAddress(obj, "A0G", c.a0G);
        vm.serializeAddress(obj, "Foundation", c.foundation);
        vm.serializeString(obj, "R0", vm.toString(c.r0));
        vm.serializeString(obj, "Cap", vm.toString(c.cap));
        vm.serializeString(obj, "Target", vm.toString(c.target));
        vm.serializeString(obj, "CooldownDuration", vm.toString(c.cooldownDuration));
        vm.serializeString(obj, "Name", c.name);
        vm.serializeString(obj, "Symbol", c.symbol);

        vm.serializeAddress(obj, "IAIImpl", d.iaiImpl);
        vm.serializeAddress(obj, "IAIBeacon", d.iaiBeacon);
        vm.serializeAddress(obj, "IAI", d.iai);
        vm.serializeAddress(obj, "IAIVaultImpl", d.vaultImpl);
        vm.serializeAddress(obj, "IAIVaultBeacon", d.vaultBeacon);
        vm.serializeAddress(obj, "IAIVault", d.vault);
        vm.serializeAddress(obj, "CreditRegistryImpl", d.registryImpl);
        vm.serializeAddress(obj, "CreditRegistryBeacon", d.registryBeacon);
        vm.serializeAddress(obj, "CreditRegistry", d.registry);

        // Derived, not an input. Recorded so off-chain tooling can cross-check the curve.
        // Only the last `serialize` call returns the completed document.
        string memory finalJson = vm.serializeString(obj, "Slope", vm.toString(d.slope));

        vm.writeJson(finalJson, path);
    }

    // --- operational entrypoints ---

    /// @notice Opens issuance and staking. Deliberately a separate, explicit transaction.
    function unpause() public {
        (string memory json,) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IAIVault(vm.parseJsonAddress(json, ".IAIVault")).unpause();
        // The registry deploys open, so it is only unpaused here if something closed it.
        CreditRegistry registry = CreditRegistry(vm.parseJsonAddress(json, ".CreditRegistry"));
        if (registry.paused()) registry.unpause();
        vm.stopBroadcast();
    }

    function pause() public {
        (string memory json,) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IAIVault(vm.parseJsonAddress(json, ".IAIVault")).pause();
        CreditRegistry(vm.parseJsonAddress(json, ".CreditRegistry")).pause();
        vm.stopBroadcast();
    }

    function harvest() public {
        (string memory json,) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        uint256 swept = IAIVault(vm.parseJsonAddress(json, ".IAIVault")).harvest();
        vm.stopBroadcast();
        console.log("swept a0G      ", swept);
    }

    function setFoundation(address newFoundation) public {
        (string memory json,) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IAIVault(vm.parseJsonAddress(json, ".IAIVault")).setFoundation(newFoundation);
        vm.stopBroadcast();
    }

    /// @notice Read-only snapshot. Run without `--broadcast`.
    function status() public view {
        (string memory json,) = loadOrInitJsonView("iai");
        IAIVault vault = IAIVault(vm.parseJsonAddress(json, ".IAIVault"));
        IAI token = IAI(vm.parseJsonAddress(json, ".IAI"));
        CreditRegistry registry = CreditRegistry(vm.parseJsonAddress(json, ".CreditRegistry"));

        console.log("network        ", networkName());
        console.log("paused (vault) ", vault.paused());
        console.log("supply         ", token.totalSupply());
        console.log("cap            ", vault.cap());
        console.log("totalLocked0G  ", vault.totalLocked0G());
        console.log("exchangeRate   ", vault.exchangeRate());
        console.log("pendingSurplus ", vault.pendingSurplus());
        console.log("foundation     ", vault.foundation());
        console.log("totalStaked    ", registry.totalStaked());
    }

    /**
     * @param task Artifact name to read.
     * @return The file's contents and its path.
     * @dev `status` is `view`, so it cannot use the writing variant of the JSON loader.
     */
    function loadOrInitJsonView(string memory task) internal view returns (string memory, string memory) {
        string memory path = deploymentPath(task);
        return (vm.readFile(path), path);
    }
}
