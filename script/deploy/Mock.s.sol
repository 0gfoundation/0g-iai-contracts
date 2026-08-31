// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";

import {JsonUtils} from "./Utils.s.sol";
import {Constants} from "./Constants.s.sol";
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
contract MockScript is Script, JsonUtils, Constants {
    function run() public {
        require(usesMockCollateral(), "refusing to deploy mock collateral to mainnet");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        (string memory json, string memory path) = loadOrInitJson("iai");
        uint256 initialValue = _uintOr(json, ".MockInitialValue", 1e18);
        uint256 apr = _uintOr(json, ".MockApr", 36.5e18); // ~10%/day, so accrual is visible
        uint256 maxAge = _uintOr(json, ".MockOracleMaxAge", 21 days);

        vm.startBroadcast(pk);
        MockA0GOracle oracle = new MockA0GOracle(initialValue, apr, maxAge, deployer);
        MockA0G a0g = new MockA0G(address(oracle));
        vm.stopBroadcast();

        console.log("network        ", networkName());
        console.log("MockA0GOracle  ", address(oracle));
        console.log("MockA0G        ", address(a0g));

        // Seed the output object with the file as it stands, then override. The key-targeted
        // form of `writeJson` can only replace a key that already exists -- writing a new one
        // is silently a no-op -- so on a fresh network the mock addresses would never be
        // recorded and nothing downstream could find them.
        string memory obj = "iai";
        vm.serializeJson(obj, json);
        vm.serializeAddress(obj, "MockA0GOracle", address(oracle));
        vm.serializeAddress(obj, "MockA0G", address(a0g));
        // The vault reads its collateral from `A0G`; point it at what was just deployed.
        string memory finalJson = vm.serializeAddress(obj, "A0G", address(a0g));
        vm.writeJson(finalJson, path);
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
