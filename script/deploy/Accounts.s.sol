// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";

import {JsonUtils} from "./Utils.s.sol";
import {Constants} from "./Constants.s.sol";
import {AccountFunder} from "./AccountFunder.sol";
import {MockA0G} from "../../src/mocks/MockA0G.sol";

/**
 * @title AccountsScript
 * @notice Derives a batch of funded testnet accounts and writes them out with their private
 *         keys, so whoever is testing can use them directly.
 *
 * @dev The chain work is in `AccountFunder`; what is left here is reading the parameters and
 *      writing the artifact.
 *
 *      The output is deliberately a plain list of `{index, address, privateKey}`. Handing
 *      over a mnemonic and a derivation path instead would make every consumer -- frontend,
 *      PM, a load-testing script -- reimplement BIP-32 correctly before they can send a
 *      transaction.
 *
 *      That makes the artifact a secret. `deployments/test-accounts-*.json` is gitignored,
 *      and this script refuses to run anywhere but a test network, so a mnemonic that also
 *      controls mainnet funds cannot be enumerated into a file by accident.
 *
 */
contract AccountsScript is Script, JsonUtils, Constants, AccountFunder {
    uint256 private countOverride;
    uint256 private gasOverride;
    uint256 private a0GOverride;
    string private mnemonicOverride;

    /**
     * @notice Overrides the environment for this instance. Everything else comes from
     *         `ACCOUNT_COUNT`, `ACCOUNT_GAS`, `ACCOUNT_A0G` and `TEST_MNEMONIC`.
     * @param count    Number of accounts to derive and fund. Zero keeps the env value.
     * @param gasEach  Native balance to top each account up to, in wei. Zero keeps the env value.
     * @param a0GEach  Mock a0G to mint to each account, in wei. Zero keeps the env value.
     * @param mnemonic BIP-39 phrase to derive from. Empty keeps the env value.
     *
     * @dev `vm.setEnv` writes the process environment, which forge's parallel tests all
     *      share, so a test cannot configure this script through it without racing others.
     */
    function setParams(uint256 count, uint256 gasEach, uint256 a0GEach, string memory mnemonic) public {
        if (count != 0) countOverride = count;
        if (gasEach != 0) gasOverride = gasEach;
        if (a0GEach != 0) a0GOverride = a0GEach;
        if (bytes(mnemonic).length != 0) mnemonicOverride = mnemonic;
    }

    function run() public {
        require(usesMockCollateral(), "refusing to write test keys for mainnet");

        uint256 count = countOverride != 0 ? countOverride : vm.envOr("ACCOUNT_COUNT", uint256(50));
        uint256 gasEach = gasOverride != 0 ? gasOverride : vm.envOr("ACCOUNT_GAS", uint256(10 ether));
        uint256 a0GEach = a0GOverride != 0 ? a0GOverride : vm.envOr("ACCOUNT_A0G", uint256(100_000 ether));
        string memory mnemonic =
            bytes(mnemonicOverride).length != 0 ? mnemonicOverride : vm.envString("TEST_MNEMONIC");

        (string memory json,) = loadOrInitJson("iai");
        MockA0G a0g = MockA0G(vm.parseJsonAddress(json, ".MockA0G"));
        require(address(a0g) != address(0), "run Mock.s.sol first");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        // Fails before deriving anything, rather than halfway through funding.
        require(deployer.balance >= count * gasEach, "deployer cannot fund that many accounts");

        (address[] memory addrs, uint256[] memory keys) = _deriveAccounts(mnemonic, count, deployer);

        // Written before funding: if a funding transaction fails halfway, the keys are still
        // on disk and the run can be repeated rather than leaving funded accounts unrecorded.
        _write(addrs, keys, gasEach, a0GEach, address(a0g));

        vm.startBroadcast(pk);
        _fundAccounts(a0g, addrs, gasEach, a0GEach);
        vm.stopBroadcast();

        console.log("network        ", networkName());
        console.log("accounts       ", count);
        console.log("gas each (wei) ", gasEach);
        console.log("a0G each (wei) ", a0GEach);
    }

    /**
     * @param addrs   Derived account addresses, in derivation order.
     * @param keys    Their private keys, same order.
     * @param gasEach Native balance each account is topped up to, in wei; recorded so a
     *                consumer knows what it was given.
     * @param a0GEach Mock a0G minted to each account, in wei.
     * @param a0g     The mock collateral token these balances are held in.
     *
     * @dev Its own file, never `iai-<chainId>.json`: the deployment record gets shared and
     *      committed, and these keys must not ride along with it.
     */
    function _write(
        address[] memory addrs,
        uint256[] memory keys,
        uint256 gasEach,
        uint256 a0GEach,
        address a0g
    ) private {
        string memory path = deploymentPath("test-accounts");

        string[] memory entries = new string[](addrs.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            string memory item = string.concat("acc", vm.toString(i));
            vm.serializeUint(item, "index", i);
            vm.serializeAddress(item, "address", addrs[i]);
            entries[i] = vm.serializeString(item, "privateKey", vm.toString(bytes32(keys[i])));
        }

        string memory root = "root";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "mockA0G", a0g);
        vm.serializeString(root, "gasEach", vm.toString(gasEach));
        vm.serializeString(root, "a0GEach", vm.toString(a0GEach));
        vm.serializeString(
            root, "warning", "Contains private keys. Test networks only. Never commit this file."
        );
        string memory finalJson = vm.serializeString(root, "accounts", entries);

        vm.writeJson(finalJson, path);
        console.log("wrote          ", path);
    }
}
