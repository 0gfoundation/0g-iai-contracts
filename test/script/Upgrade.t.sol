// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IAIScript} from "../../script/deploy/IAI.s.sol";
import {MockScript} from "../../script/deploy/Mock.s.sol";
import {UpgradeScript} from "../../script/Upgrade.s.sol";
import {IAI} from "../../src/IAI.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {MockA0G} from "../../src/mocks/MockA0G.sol";

/// @dev Stands in for an implementation whose storage layout has shifted: the ABI still
///      answers, with a different number behind it. This is the failure the rehearsal exists
///      to catch, and the reason the check lives off-chain -- a contract asking itself
///      whether its own slots moved would read the moved slots to find out.
contract DriftedVault {
    function r0() external pure returns (uint256) {
        return 1;
    }
}

/**
 * @title UpgradeScriptTest
 * @notice Exercises the upgrade rehearsal the way the runbook does, and proves the check
 *         fails when it should. A comparison that always passes is worse than none.
 */
contract UpgradeScriptTest is Test {
    uint256 internal constant DEPLOYER_PK =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    string internal dir;
    string internal file;
    address internal deployer;
    UpgradeScript internal upg;

    IAIVault internal vault;
    IAI internal token;
    MockA0G internal a0g;

    function setUp() public {
        deployer = vm.addr(DEPLOYER_PK);
        dir = _scratchDir("upgrade-test");
        file = string.concat(dir, "/iai-", vm.toString(block.chainid), ".json");

        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(DEPLOYER_PK)));

        vm.writeFile(file, vm.readFile(string.concat(vm.projectRoot(), "/deployments/iai-example.json")));
        vm.writeJson(vm.toString(deployer), file, ".Foundation");

        _MockScript().run();
        _IAIScript().run();

        string memory json = vm.readFile(file);
        vault = IAIVault(vm.parseJsonAddress(json, ".IAIVault"));
        token = IAI(vm.parseJsonAddress(json, ".IAI"));
        a0g = MockA0G(vm.parseJsonAddress(json, ".A0G"));

        // Snapshot an *occupied* deployment. An upgrade over an empty one proves nothing,
        // because the numbers it must preserve are all zero.
        _IAIScript().unpause();
        _mint(makeAddr("holder"), 3e18);

        upg = _UpgradeScript();
    }

    function _mint(address who, uint256 d) internal {
        (, uint256 a0GIn) = vault.quoteMint(d);
        a0g.mint(who, a0GIn);
        vm.startPrank(who);
        a0g.approve(address(vault), a0GIn);
        vault.mint(d, type(uint256).max, block.timestamp);
        vm.stopPrank();
    }

    function test_Rehearsal_PassesForAnHonestUpgrade() public {
        vm.setEnv("CHECK_ACCOUNTS", vm.toString(makeAddr("holder")));

        upg.snapshot();
        address implBefore = UpgradeableBeacon(vm.parseJsonAddress(vm.readFile(file), ".IAIVaultBeacon")).implementation();

        upg.upgradeVault();

        address implAfter = UpgradeableBeacon(vm.parseJsonAddress(vm.readFile(file), ".IAIVaultBeacon")).implementation();
        assertTrue(implAfter != implBefore, "beacon actually moved");
        assertEq(vm.parseJsonAddress(vm.readFile(file), ".IAIVaultImpl"), implAfter, "new impl recorded");

        upg.postUpgradeCheck();

        // The deployment must still work afterwards, not merely read the same.
        _mint(makeAddr("second"), 1e18);
        assertEq(token.balanceOf(makeAddr("second")), 1e18);
    }

    function test_Rehearsal_CatchesAnUpgradeThatMovesTheCurve() public {
        upg.snapshot();

        address beacon = vm.parseJsonAddress(vm.readFile(file), ".IAIVaultBeacon");
        // Constructed up front: an argument is evaluated before the outer call, so it would
        // otherwise be the call that `vm.prank` applies to.
        address drifted = address(new DriftedVault());
        vm.prank(deployer);
        UpgradeableBeacon(beacon).upgradeTo(drifted);

        vm.expectRevert(bytes("changed across upgrade: r0"));
        upg.postUpgradeCheck();
    }

    /// @dev Each contract has its own beacon so one upgrade cannot reach the others.
    function test_UpgradingOneContractLeavesTheOthersAlone() public {
        string memory json = vm.readFile(file);
        address vaultImpl = UpgradeableBeacon(vm.parseJsonAddress(json, ".IAIVaultBeacon")).implementation();
        address registryImpl =
            UpgradeableBeacon(vm.parseJsonAddress(json, ".CreditRegistryBeacon")).implementation();

        upg.upgradeIAI();

        json = vm.readFile(file);
        assertEq(
            UpgradeableBeacon(vm.parseJsonAddress(json, ".IAIVaultBeacon")).implementation(),
            vaultImpl,
            "vault untouched"
        );
        assertEq(
            UpgradeableBeacon(vm.parseJsonAddress(json, ".CreditRegistryBeacon")).implementation(),
            registryImpl,
            "registry untouched"
        );
    }

    /// @dev The beacon owner is the upgrade key. Nobody else may move an implementation.
    function test_OnlyTheBeaconOwnerCanUpgrade() public {
        address beacon = vm.parseJsonAddress(vm.readFile(file), ".IAIVaultBeacon");
        assertEq(UpgradeableBeacon(beacon).owner(), deployer, "deployer holds the upgrade key");

        address drifted = address(new DriftedVault());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        UpgradeableBeacon(beacon).upgradeTo(drifted);
    }

    /**
     * @dev A fresh directory per test. `forge` rolls back EVM state between tests but not the
     *      filesystem, so a shared path lets one test's leftover file decide another's result.
     */
    function _scratchDir(string memory name) internal returns (string memory d) {
        d = string.concat(vm.projectRoot(), "/cache/", name, "-", vm.toString(vm.randomUint()));
        vm.createDir(d, true);
    }

    function _IAIScript() internal returns (IAIScript s) {
        s = new IAIScript();
        s.setDeploymentDir(dir);
    }

    function _MockScript() internal returns (MockScript s) {
        s = new MockScript();
        s.setDeploymentDir(dir);
    }

    function _UpgradeScript() internal returns (UpgradeScript s) {
        s = new UpgradeScript();
        s.setDeploymentDir(dir);
    }
}
