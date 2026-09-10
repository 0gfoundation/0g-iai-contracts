// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";

import {JsonUtils} from "./Utils.s.sol";
import {Constants} from "./Constants.s.sol";
import {IAIDeployer} from "./IAIDeployer.sol";
import {MockA0G} from "../../src/mocks/MockA0G.sol";
import {MockA0GOracle} from "../../src/mocks/MockA0GOracle.sol";

/**
 * @title MockScript
 * @notice Deploys stand-in collateral for networks without a usable a0G.
 *
 * @dev Writes `A0G` into the same deployment file the main script reads, so the two are
 *      wired together by the artifact rather than by hand. Refuses to run on mainnet:
 *      pointing the vault at a mock there would be unrecoverable.
 *
 *      A testnet oracle wants a much faster rate than production. At the real 15%/year the
 *      value moves about 0.04% a day, which is invisible in a testing session and makes
 *      `harvest()` look broken. `MockApr` is therefore its own parameter.
 */
contract MockScript is Script, JsonUtils, Constants, IAIDeployer {
    function run() public {
        require(usesMockCollateral(), "refusing to deploy mock collateral to mainnet");
        (string memory json, string memory path) = loadOrInitJson("iai");

        // Reuse whatever is already there. Redeploying over a live mock would strand every
        // balance ever minted from it: the tokens stay in the old contract while the system
        // starts pointing at a new one, and nothing errors. On a testnet with funded test
        // accounts that is silent, total loss of their collateral.
        address existing = _recordedAddress(json, ".MockA0G");
        if (existing != address(0) && existing.code.length != 0) {
            console.log("network        ", networkName());
            console.log("MockA0G        ", existing, "(already deployed, reusing)");
            console.log("MockA0GOracle  ", address(MockA0G(existing).oracle()));
            _recordExistingAsset(json, path, existing);
            return;
        }

        _deployAndRecord(json, path);
    }

    /**
     * @notice Replaces the mock collateral even though one is already deployed.
     *
     * @dev The guard in `run()` is the right default and stays. This is the deliberate way
     *      past it, for the one case that needs it: the mock itself has to change shape.
     *      It abandons every balance on the old token, so it is a named, separate entry
     *      point rather than a flag -- nobody reaches it by rerunning a deployment.
     */
    function redeploy() public {
        require(usesMockCollateral(), "refusing to deploy mock collateral to mainnet");
        (string memory json, string memory path) = loadOrInitJson("iai");

        address existing = _recordedAddress(json, ".MockA0G");
        if (existing != address(0)) {
            console.log("");
            console.log("!! REPLACING the mock collateral at", existing);
            console.log("!! Every a0G balance on it is abandoned. Nothing migrates.");
            console.log("!! Afterwards you MUST run, in order:");
            console.log("!!   ./run.sh            redeploy the system against the new token");
            console.log("!!   ./run.sh accounts   re-fund the test accounts from it");
            console.log("");
        }

        _deployAndRecord(json, path);
    }

    /**
     * @param json The record as it stands.
     * @param path Where to write it back.
     *
     * @dev Shared by both entry points so the recorded shape cannot differ between them.
     */
    function _deployAndRecord(string memory json, string memory path) private {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // A network that already has the real W0G names it here, and then the wrapping hop
        // is exercised against the real token rather than a stand-in.
        address asset = _recordedAddress(json, ".W0G");
        uint256 initialValue = _uintOr(json, ".MockInitialValue", 1e18);
        uint256 apr = _uintOr(json, ".MockApr", 36.5e18); // ~10%/day, so accrual is visible
        uint256 maxAge = _uintOr(json, ".MockOracleMaxAge", 21 days);

        vm.startBroadcast(pk);
        (MockA0GOracle oracle, MockA0G a0g, address asset_) = _deployMockCollateral(
            MockConfig({asset: asset, initialValue: initialValue, apr: apr, maxAge: maxAge}), deployer
        );
        vm.stopBroadcast();

        console.log("network        ", networkName());
        console.log("W0G            ", asset_, asset == address(0) ? "(deployed)" : "(reused)");
        console.log("MockA0GOracle  ", address(oracle));
        console.log("MockA0G        ", address(a0g));

        // Seed the output object with the file as it stands, then override. The key-targeted
        // form of `writeJson` can only replace a key that already exists -- writing a new one
        // is silently a no-op -- so on a fresh network the mock addresses would never be
        // recorded and nothing downstream could find them.
        string memory obj = "iai";
        vm.serializeJson(obj, json);
        vm.serializeAddress(obj, "W0G", asset_);
        vm.serializeAddress(obj, "MockA0GOracle", address(oracle));
        vm.serializeAddress(obj, "MockA0G", address(a0g));
        // The vault reads its collateral from `A0G`; point it at what was just deployed.
        string memory finalJson = vm.serializeAddress(obj, "A0G", address(a0g));
        vm.writeJson(finalJson, path);
    }

    /**
     * @param json     The record as it stands.
     * @param path     Where to write it back.
     * @param existing The mock already deployed on this network.
     *
     * @dev The reuse path returns before writing anything, which was fine while the record
     *      held every address the mock involved. It no longer does: a record written before
     *      `W0G` existed names a token whose underlying is nowhere in the file. Recover it
     *      from the token itself rather than leaving a hole for the next reader to fall in.
     */
    function _recordExistingAsset(string memory json, string memory path, address existing) private {
        if (_recordedAddress(json, ".W0G") != address(0)) return;

        try MockA0G(existing).asset() returns (address asset) {
            string memory obj = "iai";
            vm.serializeJson(obj, json);
            vm.writeJson(vm.serializeAddress(obj, "W0G", asset), path);
            console.log("W0G            ", asset, "(recovered from the token)");
        } catch {
            console.log("W0G             -- this mock predates it; use --sig 'redeploy()'");
        }
    }

    /**
     * @param json The deployment record.
     * @param key  Path to an address.
     * @return The recorded address, or zero when the key is absent.
     */
    function _recordedAddress(string memory json, string memory key) private pure returns (address) {
        try vm.parseJsonAddress(json, key) returns (address v) {
            return v;
        } catch {
            return address(0);
        }
    }

    function _uintOr(string memory json, string memory key, uint256 fallbackValue)
        private
        pure
        returns (uint256)
    {
        try vm.parseJsonUint(json, key) returns (uint256 v) {
            return v;
        } catch {
            return fallbackValue;
        }
    }
}
