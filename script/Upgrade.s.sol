// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";

import {JsonUtils} from "./deploy/Utils.s.sol";
import {Constants} from "./deploy/Constants.s.sol";
import {UpgradeChecker} from "./deploy/UpgradeChecker.sol";
import {IAI} from "../src/IAI.sol";
import {IAIVault} from "../src/IAIVault.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";

/**
 * @title UpgradeScript
 * @notice Points one beacon at a freshly deployed implementation, and the before/after state
 *         comparison that must pass on a mainnet fork before the real transaction.
 *
 * @dev The comparison itself lives in `UpgradeChecker`, which the tests use directly. What is
 *      here is the file half: `snapshot()` and `postUpgradeCheck()` are two separate
 *      `forge script` invocations, so the snapshot has to cross a process boundary.
 *
 *      The rehearsal, which `./upgrade.sh rehearse <target>` runs for you:
 *
 *        anvil --fork-url https://evmrpc.0g.ai --chain-id 16661 &
 *        forge script script/Upgrade.s.sol --sig "snapshot()" --rpc-url http://127.0.0.1:8545
 *        forge script script/Upgrade.s.sol --sig "upgradeVault()" \
 *            --rpc-url http://127.0.0.1:8545 --broadcast
 *        forge script script/Upgrade.s.sol --sig "postUpgradeCheck()" --rpc-url http://127.0.0.1:8545
 *        forge inspect IAIVault storageLayout > /tmp/new.json && diff /tmp/old.json /tmp/new.json
 *
 *      `CHECK_ACCOUNTS` (comma-separated) adds real positions to the comparison; on a fork of a
 *      live deployment, pass the largest holders.
 */
contract UpgradeScript is Script, JsonUtils, Constants, UpgradeChecker {
    string internal constant SNAPSHOT_TASK = "upgrade-snapshot";

    // --- upgrades ---

    function upgradeIAI() public {
        (string memory json, string memory path) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address impl = address(new IAI());
        _pointBeaconAt(vm.parseJsonAddress(json, ".IAIBeacon"), impl);
        vm.stopBroadcast();
        _record(json, path, "IAIImpl", impl);
    }

    function upgradeVault() public {
        (string memory json, string memory path) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address impl = address(new IAIVault());
        _pointBeaconAt(vm.parseJsonAddress(json, ".IAIVaultBeacon"), impl);
        vm.stopBroadcast();
        _record(json, path, "IAIVaultImpl", impl);
    }

    function upgradeRegistry() public {
        (string memory json, string memory path) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address impl = address(new CreditRegistry());
        _pointBeaconAt(vm.parseJsonAddress(json, ".CreditRegistryBeacon"), impl);
        vm.stopBroadcast();
        _record(json, path, "CreditRegistryImpl", impl);
    }

    // --- rehearsal ---

    /// @notice Records the state an upgrade must leave untouched. Run before upgrading.
    function snapshot() public {
        (string memory json,) = loadOrInitJson("iai");
        (, string memory snapPath) = loadOrInitJson(SNAPSHOT_TASK);

        Snapshot memory s = _capture(_vault(json), _token(json), _registry(json), _checkAccounts());

        string memory o = "snap";
        vm.serializeAddress(o, "curve", s.curve);
        vm.serializeString(o, "cap", vm.toString(s.cap));
        vm.serializeAddress(o, "iai", s.iai);
        vm.serializeAddress(o, "a0G", s.a0G);
        vm.serializeAddress(o, "oracle", s.oracle);
        vm.serializeAddress(o, "foundation", s.foundation);
        vm.serializeAddress(o, "registryIai", s.registryIai);
        vm.serializeString(o, "totalLocked0G", vm.toString(s.totalLocked0G));
        vm.serializeString(o, "supply", vm.toString(s.supply));
        vm.serializeString(o, "tokenSupply", vm.toString(s.tokenSupply));
        vm.serializeBool(o, "paused", s.paused);
        vm.serializeString(o, "totalStaked", vm.toString(s.totalStaked));
        vm.serializeString(o, "cooldownDuration", vm.toString(s.cooldownDuration));
        vm.serializeBool(o, "quotesAvailable", s.quotesAvailable);
        vm.serializeString(o, "quote1", vm.toString(s.quote1));
        vm.serializeString(o, "quote100", vm.toString(s.quote100));
        vm.serializeAddress(o, "accounts", s.accounts);
        // Amounts go out as strings rather than JSON numbers: a uint256 balance does not
        // survive a round trip through a double.
        vm.serializeString(o, "locked", _toStrings(s.locked));
        string memory finalJson = vm.serializeString(o, "outstanding", _toStrings(s.outstanding));

        vm.writeJson(finalJson, snapPath);
        console.log("snapshot written", snapPath);
        console.log("accounts covered", s.accounts.length);
    }

    /// @notice Compares the post-upgrade state against the snapshot. Reverts on any drift.
    function postUpgradeCheck() public view {
        (string memory json,) = _read("iai");
        (string memory snap,) = _read(SNAPSHOT_TASK);

        // The accounts come from the snapshot, not the environment, so the two sides are
        // guaranteed to be comparing the same positions.
        Snapshot memory before_ = _readSnapshot(snap);
        Snapshot memory after_ = _capture(_vault(json), _token(json), _registry(json), before_.accounts);

        _assertUnchanged(before_, after_);
        _assertPricingMatchesCurve(_vault(json));

        console.log("post-upgrade check PASSED");
        console.log("accounts covered", before_.accounts.length);
        console.log("Also diff `forge inspect <contract> storageLayout` before going to mainnet.");
    }

    // --- internals ---

    /**
     * @param snap Contents of the snapshot file.
     * @return s The snapshot it encodes.
     */
    function _readSnapshot(string memory snap) private pure returns (Snapshot memory s) {
        s.curve = vm.parseJsonAddress(snap, ".curve");
        s.cap = _uint(snap, ".cap");
        s.iai = vm.parseJsonAddress(snap, ".iai");
        s.a0G = vm.parseJsonAddress(snap, ".a0G");
        s.oracle = vm.parseJsonAddress(snap, ".oracle");
        s.foundation = vm.parseJsonAddress(snap, ".foundation");
        s.registryIai = vm.parseJsonAddress(snap, ".registryIai");
        s.totalLocked0G = _uint(snap, ".totalLocked0G");
        s.supply = _uint(snap, ".supply");
        s.tokenSupply = _uint(snap, ".tokenSupply");
        s.paused = vm.parseJsonBool(snap, ".paused");
        s.totalStaked = _uint(snap, ".totalStaked");
        s.cooldownDuration = _uint(snap, ".cooldownDuration");
        s.quotesAvailable = vm.parseJsonBool(snap, ".quotesAvailable");
        s.quote1 = _uint(snap, ".quote1");
        s.quote100 = _uint(snap, ".quote100");
        s.accounts = vm.parseJsonAddressArray(snap, ".accounts");
        s.locked = _uints(snap, ".locked");
        s.outstanding = _uints(snap, ".outstanding");
    }

    /// @return The addresses named by `CHECK_ACCOUNTS`, or an empty list.
    function _checkAccounts() private view returns (address[] memory) {
        return vm.envOr("CHECK_ACCOUNTS", ",", new address[](0));
    }

    /**
     * @param json The deployment record as it currently stands.
     * @param path Where to write it back.
     * @param key  Which implementation key to update.
     * @param impl The newly deployed implementation.
     */
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

    /// @param json The deployment record. @return The vault proxy it names.
    function _vault(string memory json) private pure returns (IAIVault) {
        return IAIVault(vm.parseJsonAddress(json, ".IAIVault"));
    }

    /// @param json The deployment record. @return The iAI proxy it names.
    function _token(string memory json) private pure returns (IAI) {
        return IAI(vm.parseJsonAddress(json, ".IAI"));
    }

    /// @param json The deployment record. @return The credit registry proxy it names.
    function _registry(string memory json) private pure returns (CreditRegistry) {
        return CreditRegistry(vm.parseJsonAddress(json, ".CreditRegistry"));
    }

    /// @param json A JSON document. @param key Path to a decimal string. @return Its value.
    function _uint(string memory json, string memory key) private pure returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, key));
    }

    /// @param json A JSON document. @param key Path to an array of decimal strings.
    /// @return out The values.
    function _uints(string memory json, string memory key) private pure returns (uint256[] memory out) {
        string[] memory raw = vm.parseJsonStringArray(json, key);
        out = new uint256[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            out[i] = vm.parseUint(raw[i]);
        }
    }

    /// @param values Amounts to encode. @return out Their decimal representations.
    function _toStrings(uint256[] memory values) private pure returns (string[] memory out) {
        out = new string[](values.length);
        for (uint256 i = 0; i < values.length; i++) {
            out[i] = vm.toString(values[i]);
        }
    }
}
