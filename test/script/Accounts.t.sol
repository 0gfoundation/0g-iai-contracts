// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

import {AccountsScript} from "../../script/deploy/Accounts.s.sol";
import {MockScript} from "../../script/deploy/Mock.s.sol";
import {MockA0G} from "../../src/mocks/MockA0G.sol";

/**
 * @title AccountsScriptTest
 * @notice The artifact this script writes is what other people build against, so its shape
 *         is part of the contract. The keys in it must also actually work -- a file of
 *         well-formed but wrong keys would only be discovered by whoever tried to use it.
 */
contract AccountsScriptTest is Test {
    uint256 internal constant DEPLOYER_PK =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    /// @dev A published BIP-39 test vector, deliberately not anvil's stock phrase: anvil's
    ///      account 0 is the deployer key above, which the script refuses to enumerate.
    ///      Covered by its own test below.
    string internal constant MNEMONIC =
        "legal winner thank year wave sausage worth useful legal winner thank yellow";

    uint256 internal constant COUNT = 25;
    uint256 internal constant GAS_EACH = 0.5 ether;
    uint256 internal constant A0G_EACH = 1234e18;

    string internal dir;
    address internal deployer;
    MockA0G internal a0g;

    function setUp() public {
        deployer = vm.addr(DEPLOYER_PK);
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(DEPLOYER_PK)));
        vm.deal(deployer, 1000 ether);
    }

    /**
     * @dev Each test names its own directory. Tests in one contract run in parallel and the
     *      filesystem is not rolled back between them, so a shared path means two tests race
     *      over the same file. The name cannot be generated in `setUp` either: `setUp` runs
     *      once and every test resumes from a snapshot of it, so a value computed there --
     *      `vm.randomUint()` included -- is the same in every test.
     */
    function _bootstrap(string memory name) internal {
        dir = string.concat(vm.projectRoot(), "/cache/accounts-test-", name);
        vm.createDir(dir, true);
        vm.writeFile(_configFile(), vm.readFile(string.concat(vm.projectRoot(), "/deployments/iai-example.json")));
        _MockScript().run();
        a0g = MockA0G(vm.parseJsonAddress(vm.readFile(_configFile()), ".MockA0G"));
    }

    function _configFile() internal view returns (string memory) {
        return string.concat(dir, "/iai-", vm.toString(block.chainid), ".json");
    }

    function _keysFile() internal view returns (string memory) {
        return vm.readFile(string.concat(dir, "/test-accounts-", vm.toString(block.chainid), ".json"));
    }

    function test_WritesUsableKeysAndFundsThem() public {
        _bootstrap("usable-keys");
        _accounts().run();
        string memory json = _keysFile();

        for (uint256 i = 0; i < COUNT; i++) {
            string memory at = string.concat(".accounts[", vm.toString(i), "]");

            assertEq(vm.parseJsonUint(json, string.concat(at, ".index")), i, "index");

            // The recorded key must control the recorded address. Anything else hands out a
            // file that looks right and cannot sign.
            address recorded = vm.parseJsonAddress(json, string.concat(at, ".address"));
            uint256 key = uint256(vm.parseJsonBytes32(json, string.concat(at, ".privateKey")));
            assertEq(vm.addr(key), recorded, "private key does not control its address");

            assertEq(recorded.balance, GAS_EACH, "gas funded");
            assertEq(a0g.balanceOf(recorded), A0G_EACH, "a0G funded");
        }

        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid);
        assertEq(vm.parseJsonAddress(json, ".mockA0G"), address(a0g), "points at this network's mock");
    }

    /// @dev A rerun must top accounts back up without re-sending what they already hold.
    function test_RerunIsIdempotent() public {
        _bootstrap("idempotent");
        AccountsScript s = _accounts();
        s.run();

        address first = vm.parseJsonAddress(_keysFile(), ".accounts[0].address");
        uint256 spentAfterFirst = 1000 ether - deployer.balance;

        // Spend some of one account's gas, then rerun.
        vm.prank(first);
        payable(address(0xdead)).transfer(0.1 ether);

        s.run();
        assertEq(first.balance, GAS_EACH, "topped back up");
        assertLt(1000 ether - deployer.balance - spentAfterFirst, GAS_EACH, "did not re-fund everyone");
    }

    /// @dev Enumerating the deployer would publish the admin and beacon-owner key.
    function test_RefusesToPublishTheDeployerKey() public {
        _bootstrap("deployer-key");
        AccountsScript s = _accounts();
        s.setParams(0, 0, 0, "test test test test test test test test test test test junk");
        vm.expectRevert(bytes("TEST_MNEMONIC derives the deployer key"));
        s.run();
    }

    function test_RefusesOnMainnet() public {
        _bootstrap("mainnet");
        AccountsScript s = _accounts();
        vm.chainId(16_661);
        vm.expectRevert(bytes("refusing to write test keys for mainnet"));
        s.run();
    }

    function test_RefusesWithoutTheMock() public {
        _bootstrap("no-mock");
        vm.writeJson(vm.toString(address(0)), _configFile(), ".MockA0G");
        AccountsScript s = _accounts();
        vm.expectRevert(bytes("run Mock.s.sol first"));
        s.run();
    }


    function _accounts() internal returns (AccountsScript s) {
        s = new AccountsScript();
        s.setDeploymentDir(dir);
        s.setParams(COUNT, GAS_EACH, A0G_EACH, MNEMONIC);
    }

    function _MockScript() internal returns (MockScript s) {
        s = new MockScript();
        s.setDeploymentDir(dir);
    }
}
