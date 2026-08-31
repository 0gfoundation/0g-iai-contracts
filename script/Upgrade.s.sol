// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {JsonUtils} from "./deploy/Utils.s.sol";
import {Constants} from "./deploy/Constants.s.sol";
import {IAI} from "../src/IAI.sol";
import {IAIVault} from "../src/IAIVault.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {MintCurve} from "../src/libraries/MintCurve.sol";

/**
 * @title UpgradeScript
 * @notice Points one beacon at a freshly deployed implementation, and the before/after
 *         state comparison that must pass on a mainnet fork before the real transaction.
 *
 * @dev Correctness of an upgrade is established by rehearsal against forked mainnet state,
 *      not by an on-chain self-check. A guard the contract computes about itself is only
 *      sound while it reads the right storage slots -- which is exactly what is in doubt
 *      when a layout has shifted, so it reports "fine" in the case it exists to catch.
 *
 *      The rehearsal:
 *
 *        anvil --fork-url https://evmrpc.0g.ai --chain-id 16661 &
 *        forge script script/Upgrade.s.sol --sig "snapshot()" --rpc-url http://127.0.0.1:8545
 *        forge script script/Upgrade.s.sol --sig "upgradeVault()" \
 *            --rpc-url http://127.0.0.1:8545 --broadcast
 *        forge script script/Upgrade.s.sol --sig "postUpgradeCheck()" --rpc-url http://127.0.0.1:8545
 *        forge inspect IAIVault storageLayout > /tmp/new.json && diff /tmp/old.json /tmp/new.json
 *
 *      `CHECK_ACCOUNTS` (comma-separated) adds real positions to the comparison; on a fork
 *      of a live deployment, pass the largest holders.
 *
 *      Beacons are per-contract, so each entrypoint moves exactly one implementation and
 *      cannot reach the others.
 */
contract UpgradeScript is Script, JsonUtils, Constants {
    string internal constant SNAPSHOT_TASK = "upgrade-snapshot";

    // --- upgrades ---

    function upgradeIAI() public {
        (string memory json, string memory path) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address impl = address(new IAI());
        UpgradeableBeacon(vm.parseJsonAddress(json, ".IAIBeacon")).upgradeTo(impl);
        vm.stopBroadcast();
        _record(json, path, "IAIImpl", impl);
    }

    function upgradeVault() public {
        (string memory json, string memory path) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address impl = address(new IAIVault());
        UpgradeableBeacon(vm.parseJsonAddress(json, ".IAIVaultBeacon")).upgradeTo(impl);
        vm.stopBroadcast();
        _record(json, path, "IAIVaultImpl", impl);
    }

    function upgradeRegistry() public {
        (string memory json, string memory path) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address impl = address(new CreditRegistry());
        UpgradeableBeacon(vm.parseJsonAddress(json, ".CreditRegistryBeacon")).upgradeTo(impl);
        vm.stopBroadcast();
        _record(json, path, "CreditRegistryImpl", impl);
    }

    // --- rehearsal ---

    /// @notice Records the state that an upgrade must leave untouched. Run before upgrading.
    function snapshot() public {
        (string memory json,) = loadOrInitJson("iai");
        (, string memory snapPath) = loadOrInitJson(SNAPSHOT_TASK);

        IAIVault vault = IAIVault(vm.parseJsonAddress(json, ".IAIVault"));
        IAI token = IAI(vm.parseJsonAddress(json, ".IAI"));
        CreditRegistry registry = CreditRegistry(vm.parseJsonAddress(json, ".CreditRegistry"));

        string memory o = "snap";
        // Curve constants. A shifted storage layout shows up here first, and any change to
        // them silently reprices every future mint.
        vm.serializeString(o, "r0", vm.toString(vault.r0()));
        vm.serializeString(o, "slope", vm.toString(vault.slope()));
        vm.serializeString(o, "cap", vm.toString(vault.cap()));
        vm.serializeString(o, "target", vm.toString(vault.target()));

        vm.serializeAddress(o, "iai", address(vault.iai()));
        vm.serializeAddress(o, "a0G", address(vault.a0G()));
        vm.serializeAddress(o, "oracle", address(vault.oracle()));
        vm.serializeAddress(o, "foundation", vault.foundation());

        // Live accounting. Every 0G in here is someone's redeemable collateral.
        vm.serializeString(o, "totalLocked0G", vm.toString(vault.totalLocked0G()));
        vm.serializeString(o, "supply", vm.toString(vault.supply()));
        vm.serializeString(o, "totalSupply", vm.toString(token.totalSupply()));
        vm.serializeString(o, "tokenCap", vm.toString(token.cap()));
        vm.serializeBool(o, "paused", vault.paused());

        vm.serializeString(o, "totalStaked", vm.toString(registry.totalStaked()));
        vm.serializeString(o, "cooldownDuration", vm.toString(registry.cooldownDuration()));
        vm.serializeAddress(o, "registryIai", address(registry.iai()));

        // Pricing at the live supply, quoted through the proxy rather than recomputed, so a
        // change in how the contract reaches the answer is caught even if the inputs match.
        (uint256 delta0G,) = vault.quoteMint(1e18);
        vm.serializeString(o, "quote1", vm.toString(delta0G));
        (uint256 delta0G100,) = vault.quoteMint(100e18);
        vm.serializeString(o, "quote100", vm.toString(delta0G100));

        // Real positions, if any were named. These are the balances an upgrade would strand.
        address[] memory accounts = _checkAccounts();
        string memory finalJson;
        for (uint256 i = 0; i < accounts.length; i++) {
            (uint256 locked, uint256 outstanding,) = vault.positionOf(accounts[i]);
            vm.serializeString(o, string.concat("locked_", vm.toString(accounts[i])), vm.toString(locked));
            finalJson = vm.serializeString(
                o, string.concat("outstanding_", vm.toString(accounts[i])), vm.toString(outstanding)
            );
        }
        if (accounts.length == 0) finalJson = vm.serializeUint(o, "accounts", 0);

        vm.writeJson(finalJson, snapPath);
        console.log("snapshot written", snapPath);
        console.log("accounts covered", accounts.length);
    }

    /// @notice Compares the post-upgrade state against the snapshot. Reverts on any drift.
    function postUpgradeCheck() public view {
        (string memory json,) = _read("iai");
        (string memory snap,) = _read(SNAPSHOT_TASK);

        IAIVault vault = IAIVault(vm.parseJsonAddress(json, ".IAIVault"));
        IAI token = IAI(vm.parseJsonAddress(json, ".IAI"));
        CreditRegistry registry = CreditRegistry(vm.parseJsonAddress(json, ".CreditRegistry"));

        _eq(vault.r0(), snap, "r0");
        _eq(vault.slope(), snap, "slope");
        _eq(vault.cap(), snap, "cap");
        _eq(vault.target(), snap, "target");
        _eqAddr(address(vault.iai()), snap, "iai");
        _eqAddr(address(vault.a0G()), snap, "a0G");
        _eqAddr(address(vault.oracle()), snap, "oracle");
        _eqAddr(vault.foundation(), snap, "foundation");
        _eq(vault.totalLocked0G(), snap, "totalLocked0G");
        _eq(vault.supply(), snap, "supply");
        _eq(token.totalSupply(), snap, "totalSupply");
        _eq(token.cap(), snap, "tokenCap");
        require(vault.paused() == vm.parseJsonBool(snap, ".paused"), "paused changed");
        _eq(registry.totalStaked(), snap, "totalStaked");
        _eq(registry.cooldownDuration(), snap, "cooldownDuration");
        _eqAddr(address(registry.iai()), snap, "registryIai");

        (uint256 q1,) = vault.quoteMint(1e18);
        _eqValue(q1, snap, "quote1");
        (uint256 q100,) = vault.quoteMint(100e18);
        _eqValue(q100, snap, "quote100");

        // The proxy's answer must still equal an independent evaluation of the curve, so an
        // upgrade that changes the maths is caught even where the snapshot happens to match.
        require(
            q1 == MintCurve.cost(vault.r0(), vault.slope(), vault.supply(), 1e18),
            "pricing diverged from the curve"
        );

        address[] memory accounts = _checkAccounts();
        for (uint256 i = 0; i < accounts.length; i++) {
            (uint256 locked, uint256 outstanding,) = vault.positionOf(accounts[i]);
            _eqValue(locked, snap, string.concat("locked_", vm.toString(accounts[i])));
            _eqValue(outstanding, snap, string.concat("outstanding_", vm.toString(accounts[i])));
        }

        console.log("post-upgrade check PASSED");
        console.log("accounts covered", accounts.length);
        console.log("Also diff `forge inspect <contract> storageLayout` before going to mainnet.");
    }

    // --- internals ---

    function _checkAccounts() internal view returns (address[] memory) {
        return vm.envOr("CHECK_ACCOUNTS", ",", new address[](0));
    }

    function _record(string memory json, string memory path, string memory key, address impl) private {
        string memory o = "upg";
        vm.serializeJson(o, json);
        vm.writeJson(vm.serializeAddress(o, key, impl), path);
        console.log(key, impl);
    }

    /**
     * @param task Artifact name to read.
     * @return The file's contents and its path.
     * @dev `postUpgradeCheck` is `view`, so it cannot use the file-creating loader.
     */
    function _read(string memory task) private view returns (string memory, string memory) {
        string memory path = deploymentPath(task);
        return (vm.readFile(path), path);
    }

    function _eq(uint256 actual, string memory snap, string memory key) private pure {
        _eqValue(actual, snap, key);
    }

    function _eqValue(uint256 actual, string memory snap, string memory key) private pure {
        uint256 expected = vm.parseJsonUint(snap, string.concat(".", key));
        require(actual == expected, string.concat("changed across upgrade: ", key));
    }

    function _eqAddr(address actual, string memory snap, string memory key) private pure {
        address expected = vm.parseJsonAddress(snap, string.concat(".", key));
        require(actual == expected, string.concat("changed across upgrade: ", key));
    }
}
