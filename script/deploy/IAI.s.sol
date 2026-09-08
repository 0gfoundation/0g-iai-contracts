// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";

import {JsonUtils} from "./Utils.s.sol";
import {Constants} from "./Constants.s.sol";
import {IAIDeployer} from "./IAIDeployer.sol";
import {IAI} from "../../src/IAI.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {CreditRegistry} from "../../src/CreditRegistry.sol";
import {IMintCurve} from "../../src/interfaces/IMintCurve.sol";

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
            curveKind: vm.parseJsonString(json, ".MintCurveKind"),
            r0: vm.parseJsonUint(json, ".R0"),
            curveAnchorCap: vm.parseJsonUint(json, ".CurveAnchorCap"),
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
        console.log("curve          ", d.curve, c.curveKind);
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
        vm.serializeString(obj, "MintCurveKind", c.curveKind);
        vm.serializeString(obj, "R0", vm.toString(c.r0));
        vm.serializeString(obj, "CurveAnchorCap", vm.toString(c.curveAnchorCap));
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

        // The active curve, the same address under its own kind, and the running list of
        // every curve this record has named -- the kind key holds only the newest of its
        // kind, so without the list a redeploy would drop an address that historical mints
        // were priced by and that is still live on chain.
        vm.serializeAddress(obj, c.curveKind, d.curve);
        vm.serializeAddress(obj, "MintCurveHistory", _appendCurve(json, d.curve));
        // Only the last `serialize` call returns the completed document.
        string memory finalJson = vm.serializeAddress(obj, "MintCurve", d.curve);

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

    /**
     * @notice Changes the unstaking delay on a live deployment. `DEFAULT_ADMIN_ROLE`.
     * @param newDuration New delay in seconds.
     *
     * @dev Also rewrites `CooldownDuration` in the deployment record, so the file keeps
     *      describing the chain. Applies to withdrawals started after this call; anything
     *      already cooling down keeps the end time it was given.
     */
    function setCooldownDuration(uint256 newDuration) public {
        (string memory json, string memory path) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        CreditRegistry(vm.parseJsonAddress(json, ".CreditRegistry")).setCooldownDuration(newDuration);
        vm.stopBroadcast();

        string memory o = "iai";
        vm.serializeJson(o, json);
        vm.writeJson(vm.serializeString(o, "CooldownDuration", vm.toString(newDuration)), path);
        console.log("cooldownDuration", newDuration);
    }

    /**
     * @notice Deploys a curve of the given kind from the parameters in the record, and records
     *         its address under that kind. Does **not** put it into service.
     * @param kind Curve contract name, e.g. `"LinearMintCurve"`.
     *
     * @dev Two steps on purpose: deploy, read the address back, then switch. A curve is an
     *      immutable value, so several may coexist in one record and the active one is
     *      whichever `MintCurve` names.
     */
    function deployCurve(string memory kind) public {
        (string memory json, string memory path) = loadOrInitJson("iai");

        Config memory c = Config({
            a0G: vm.parseJsonAddress(json, ".A0G"),
            foundation: vm.parseJsonAddress(json, ".Foundation"),
            curveKind: kind,
            r0: vm.parseJsonUint(json, ".R0"),
            curveAnchorCap: vm.parseJsonUint(json, ".CurveAnchorCap"),
            cap: vm.parseJsonUint(json, ".Cap"),
            target: vm.parseJsonUint(json, ".Target"),
            cooldownDuration: vm.parseJsonUint(json, ".CooldownDuration"),
            name: vm.parseJsonString(json, ".Name"),
            symbol: vm.parseJsonString(json, ".Symbol")
        });

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address deployed = address(_deployCurve(c));
        vm.stopBroadcast();

        string memory o = "iai";
        vm.serializeJson(o, json);
        vm.serializeAddress(o, kind, deployed);
        vm.writeJson(vm.serializeAddress(o, "MintCurveHistory", _appendCurve(json, deployed)), path);

        console.log("deployed       ", kind, deployed);
        console.log("Not yet in service. Switch with --sig 'setCurve(string)' when ready.");
    }

    /**
     * @param json     The record as it stands.
     * @param deployed The curve just deployed.
     * @return next Every curve this record has ever named, with `deployed` appended.
     *
     * @dev The kind key holds only the newest curve of its kind, and `MintCurve` only the
     *      active one, so without this a redeploy of the same kind would drop an address that
     *      is still needed: reconciling historical mints means knowing which curve priced
     *      them, and that curve is still live on chain whether or not the record names it.
     */
    function _appendCurve(string memory json, address deployed)
        private
        pure
        returns (address[] memory next)
    {
        address[] memory previous;
        try vm.parseJsonAddressArray(json, ".MintCurveHistory") returns (address[] memory a) {
            previous = a;
        } catch {
            previous = new address[](0);
        }
        for (uint256 i = 0; i < previous.length; i++) {
            if (previous[i] == deployed) return previous; // re-running a script, not a new curve
        }

        next = new address[](previous.length + 1);
        for (uint256 i = 0; i < previous.length; i++) {
            next[i] = previous[i];
        }
        next[previous.length] = deployed;
    }

    /**
     * @notice Puts an already-deployed curve into service, by kind. `DEFAULT_ADMIN_ROLE`.
     * @param kind Curve contract name, which must already be recorded by `deployCurve`.
     *
     * @dev Prices only future mints. Everything already minted keeps its own price, because
     *      positions record an absolute 0G amount and redemption never consults a curve.
     */
    function setCurve(string memory kind) public {
        (string memory json, string memory path) = loadOrInitJson("iai");
        address target = vm.parseJsonAddress(json, string.concat(".", kind));
        require(target != address(0), "no curve recorded under that kind -- run deployCurve first");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IAIVault(vm.parseJsonAddress(json, ".IAIVault")).setCurve(IMintCurve(target));
        vm.stopBroadcast();

        string memory o = "iai";
        vm.serializeJson(o, json);
        vm.serializeString(o, "MintCurveKind", kind);
        vm.writeJson(vm.serializeAddress(o, "MintCurve", target), path);

        console.log("now pricing on ", kind, target);
    }

    /**
     * @notice Moves the supply ceiling. `DEFAULT_ADMIN_ROLE`.
     * @param newCap New ceiling in wei-iAI. Below the current supply this closes issuance
     *               while leaving redemption working.
     */
    function setCap(uint256 newCap) public {
        (string memory json, string memory path) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IAIVault(vm.parseJsonAddress(json, ".IAIVault")).setCap(newCap);
        vm.stopBroadcast();

        string memory o = "iai";
        vm.serializeJson(o, json);
        vm.writeJson(vm.serializeString(o, "Cap", vm.toString(newCap)), path);
        console.log("cap            ", newCap);
    }

    function setFoundation(address newFoundation) public {
        (string memory json,) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IAIVault(vm.parseJsonAddress(json, ".IAIVault")).setFoundation(newFoundation);
        vm.stopBroadcast();
    }

    /**
     * @notice Re-checks the recorded deployment against the chain. Read-only.
     *
     * @dev Worth running after every deployment, because the record is written during
     *      simulation: a run interrupted partway -- this chain's RPC intermittently answers
     *      `eth_getTransactionReceipt` with null and forge gives up after a few retries --
     *      still leaves a file naming contracts that were never deployed. Nothing later
     *      notices, because reading from an address with no code simply returns nothing.
     */
    function checkDeployment() public view {
        (string memory json,) = loadOrInitJsonView("iai");

        Config memory c = Config({
            a0G: vm.parseJsonAddress(json, ".A0G"),
            foundation: vm.parseJsonAddress(json, ".Foundation"),
            curveKind: vm.parseJsonString(json, ".MintCurveKind"),
            r0: vm.parseJsonUint(json, ".R0"),
            curveAnchorCap: vm.parseJsonUint(json, ".CurveAnchorCap"),
            cap: vm.parseJsonUint(json, ".Cap"),
            target: vm.parseJsonUint(json, ".Target"),
            cooldownDuration: vm.parseJsonUint(json, ".CooldownDuration"),
            name: vm.parseJsonString(json, ".Name"),
            symbol: vm.parseJsonString(json, ".Symbol")
        });
        Deployment memory d = Deployment({
            iai: vm.parseJsonAddress(json, ".IAI"),
            iaiImpl: vm.parseJsonAddress(json, ".IAIImpl"),
            iaiBeacon: vm.parseJsonAddress(json, ".IAIBeacon"),
            vault: vm.parseJsonAddress(json, ".IAIVault"),
            vaultImpl: vm.parseJsonAddress(json, ".IAIVaultImpl"),
            vaultBeacon: vm.parseJsonAddress(json, ".IAIVaultBeacon"),
            registry: vm.parseJsonAddress(json, ".CreditRegistry"),
            registryImpl: vm.parseJsonAddress(json, ".CreditRegistryImpl"),
            registryBeacon: vm.parseJsonAddress(json, ".CreditRegistryBeacon"),
            curve: vm.parseJsonAddress(json, ".MintCurve")
        });

        _assertWiring(c, d);

        console.log("network        ", networkName());
        console.log("every recorded address holds code and the wiring matches the file.");
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
        console.log("remainingCap   ", vault.remainingCap());
        console.log("curve          ", address(vault.curve()));
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
