// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IAIScript} from "../../script/deploy/IAI.s.sol";
import {MockScript} from "../../script/deploy/Mock.s.sol";
import {HandoverScript} from "../../script/Handover.s.sol";
import {IAI} from "../../src/IAI.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {CreditRegistry} from "../../src/CreditRegistry.sol";

/**
 * @title HandoverScriptTest
 * @notice The handover run the way an operator runs it, through the deployment file.
 *
 * @dev The logic is covered without files in `test/unit/Handover.t.sol`. What is only reachable
 *      here is the part an operator actually touches: four addresses typed into a JSON file,
 *      and a script that has to read the right keys. A typo in a key name would mean handing
 *      the system to `address(0)` — so this checks the wiring from the file, not just the moves.
 */
contract HandoverScriptTest is Test {
    uint256 internal constant DEPLOYER_PK =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    address internal deployer;
    address internal multisig = makeAddr("multisig");
    address internal ops = makeAddr("ops");
    address internal timelock = makeAddr("timelock");

    string internal dir;
    string internal file;

    IAIVault internal vault;
    IAI internal token;
    CreditRegistry internal registry;

    function setUp() public {
        deployer = vm.addr(DEPLOYER_PK);
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(DEPLOYER_PK)));
    }

    /**
     * @dev Each test names its own directory. Tests in one contract run in parallel and the
     *      filesystem is not rolled back between them, so a shared path means two tests race
     *      over the same file. The name cannot be generated in `setUp` either: `setUp` runs
     *      once and every test resumes from a snapshot of it, so a value computed there --
     *      `vm.randomUint()` included -- is the same in every test.
     */
    function _bootstrap(string memory name) internal {
        dir = string.concat(vm.projectRoot(), "/cache/handover-test-", name);
        vm.createDir(dir, true);
        file = string.concat(dir, "/iai-", vm.toString(block.chainid), ".json");

        vm.writeFile(file, vm.readFile(string.concat(vm.projectRoot(), "/deployments/iai-example.json")));
        vm.writeJson(vm.toString(deployer), file, ".Foundation");

        _script(new MockScript()).run();
        _iai().run();

        string memory json = vm.readFile(file);
        vault = IAIVault(vm.parseJsonAddress(json, ".IAIVault"));
        token = IAI(vm.parseJsonAddress(json, ".IAI"));
        registry = CreditRegistry(vm.parseJsonAddress(json, ".CreditRegistry"));
    }

    /// @dev The operator's step: fill in the three governance addresses by hand.
    function _writeTargets() internal {
        vm.writeJson(vm.toString(multisig), file, ".Admin");
        vm.writeJson(vm.toString(ops), file, ".Guardian");
        vm.writeJson(vm.toString(timelock), file, ".BeaconOwner");
    }

    function test_ReadsTheTargetsFromTheFileAndMovesEverything() public {
        _bootstrap("full");
        _writeTargets();

        HandoverScript h = _handover();
        h.grant();

        // Read back through the file, the way the next operator would.
        string memory json = vm.readFile(file);
        assertTrue(vault.hasRole(0x00, multisig), "admin came from .Admin");
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), ops), "guardian came from .Guardian");
        assertEq(
            UpgradeableBeacon(vm.parseJsonAddress(json, ".IAIVaultBeacon")).owner(),
            timelock,
            "beacon owner came from .BeaconOwner"
        );
        assertTrue(vault.hasRole(0x00, deployer), "grant leaves the deployer in place");

        h.renounce();

        assertFalse(vault.hasRole(0x00, deployer), "deployer stood down");
        assertFalse(registry.hasRole(0x00, deployer));
        assertTrue(token.hasRole(token.MINTER_BURNER_ROLE(), address(vault)), "the vault still mints");

        h.status(); // must not revert against a handed-over deployment
    }

    /// @dev The file ships with zero addresses. Running the handover before they are filled in
    ///      would grant the system to nobody, so it has to stop at the file, not at the chain.
    function test_RefusesWhileTheTargetsAreStillPlaceholders() public {
        _bootstrap("placeholders");

        HandoverScript h = _handover();
        vm.expectRevert(bytes("admin is the zero address"));
        h.grant();

        assertTrue(vault.hasRole(0x00, deployer), "nothing moved");
    }

    /// @dev The precondition holds when the script is driven from the file too: renouncing
    ///      before granting must leave the deployer in control.
    function test_RenounceRefusesBeforeGrant() public {
        _bootstrap("out-of-order");
        _writeTargets();

        HandoverScript h = _handover();
        vm.expectRevert(bytes("admin does not hold iAI admin"));
        h.renounce();

        assertTrue(vault.hasRole(0x00, deployer), "the deployer is still in control");
    }

    function _handover() internal returns (HandoverScript h) {
        h = new HandoverScript();
        h.setDeploymentDir(dir);
    }

    function _iai() internal returns (IAIScript s) {
        s = new IAIScript();
        s.setDeploymentDir(dir);
    }

    function _script(MockScript s) internal returns (MockScript) {
        s.setDeploymentDir(dir);
        return s;
    }
}
