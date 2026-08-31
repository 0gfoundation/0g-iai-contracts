// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

import {AccountsScript} from "../../script/deploy/Accounts.s.sol";
import {MockScript} from "../../script/deploy/Mock.s.sol";
import {MockA0G} from "../../src/mocks/MockA0G.sol";

/**
 * @title AccountsScriptTest
 * @notice The artifact the script writes, and the guards that depend on reading a file.
 *
 * @dev Deriving and funding is `AccountFunder`, covered in `test/unit/AccountFunder.t.sol`
 *      without touching disk. What can only be tested here is the file: its shape is what
 *      other people build against, and the keys have to survive the JSON round trip.
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

    function test_WritesAUsableKeyFile() public {
        _bootstrap("key-file");
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
