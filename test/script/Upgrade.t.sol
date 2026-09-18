// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

import {IAIScript} from "../../script/deploy/IAI.s.sol";
import {MockScript} from "../../script/deploy/Mock.s.sol";
import {UpgradeScript} from "../../script/Upgrade.s.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {MockA0G} from "../../src/mocks/MockA0G.sol";

/**
 * @title UpgradeScriptTest
 * @notice The upgrade rehearsal as an operator runs it: snapshot to a file, upgrade, read the
 *         file back, compare.
 *
 * @dev `test/unit/Upgrade.t.sol` exercises `UpgradeChecker` in memory, so it cannot see the one
 *      thing that only the script does: writing the snapshot to disk and parsing it back. A
 *      field added to `Snapshot` and to `_assertUnchanged` but not to the serializer reads as
 *      zero after the round trip, and every rehearsal on a deployment where that field is
 *      non-zero then fails with "changed across upgrade" on a system nothing changed in. That
 *      happened with `harvestShare`, and it was found on a testnet rehearsal rather than here.
 *
 *      So the fixture gives every compared field a non-zero value -- a mint for the totals and
 *      for the watched position's four figures, a change of split for the share and the epoch --
 *      and then asserts that a rehearsal with **no** upgrade in between passes. If it does not,
 *      a field was dropped on the way through the file. Dropping either claim array from the
 *      serializer makes both tests panic with an out-of-bounds read, which is what the testnet
 *      rehearsal did.
 */
contract UpgradeScriptTest is Test {
    uint256 internal constant DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    string internal dir;
    string internal file;

    function setUp() public {
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(DEPLOYER_PK)));
    }

    /// @dev Same convention as `Deploy.t.sol`: each test names its own directory, because tests
    ///      in one contract run in parallel and the filesystem is not rolled back between them.
    function _bootstrap(
        string memory name
    ) internal {
        dir = string.concat(vm.projectRoot(), "/cache/upgrade-test-", name);
        vm.createDir(dir, true);
        file = string.concat(dir, "/iai-", vm.toString(block.chainid), ".json");
        string memory template = vm.readFile(string.concat(vm.projectRoot(), "/deployments/iai-example.json"));
        vm.writeFile(file, template);
        vm.writeJson(vm.toString(vm.addr(DEPLOYER_PK)), file, ".Foundation");

        MockScript mock = new MockScript();
        mock.setDeploymentDir(dir);
        mock.run();
        _iai().run();
    }

    function _iai() internal returns (IAIScript s) {
        s = new IAIScript();
        s.setDeploymentDir(dir);
    }

    /// @dev Watches the deployer's own position, so the per-account arrays -- locked,
    ///      outstanding, and the two claim halves -- are populated and round-tripped too.
    function _upgrade() internal returns (UpgradeScript s) {
        s = new UpgradeScript();
        s.setDeploymentDir(dir);
        address[] memory watched = new address[](1);
        watched[0] = vm.addr(DEPLOYER_PK);
        s.setCheckAccounts(watched);
    }

    /// @dev Leaves no compared field at its default: the totals, the watched position's four
    ///      figures, the split and the epoch counter are all non-zero afterwards.
    function _populate() internal {
        string memory json = vm.readFile(file);
        address deployer = vm.addr(DEPLOYER_PK);
        MockA0G(vm.parseJsonAddress(json, ".A0G")).faucetMint(deployer, 1_000_000e18);

        _iai().unpause();
        _iai().mint(10e18, type(uint256).max);
        _iai().setHarvestShare(0.25e18);

        IAIVault vault = IAIVault(vm.parseJsonAddress(json, ".IAIVault"));
        assertGt(vault.totalClaim0G(), 0, "fixture: the 0G half is populated");
        assertGt(vault.totalClaimA0G(), 0, "fixture: the a0G half is populated");
        assertEq(vault.harvestShare(), 0.25e18, "fixture: the split is not the default");
        assertEq(vault.currentEpoch(), 1, "fixture: one change has happened");
        assertEq(vault.supply(), 10e18);
    }

    function test_Snapshot_RoundTripsThroughTheFileWithNothingDropped() public {
        _bootstrap("snapshot-round-trip");
        _populate();

        UpgradeScript u = _upgrade();
        u.snapshot();
        assertTrue(vm.exists(string.concat(dir, "/upgrade-snapshot-", vm.toString(block.chainid), ".json")));
        // Nothing was upgraded, so nothing may read as changed. Every field the check compares
        // has a non-zero value here, so a field the serializer forgot fails this line.
        u.postUpgradeCheck();
    }

    function test_Rehearsal_UpgradesTheVaultAndComparesClean() public {
        _bootstrap("rehearsal-vault");
        _populate();
        string memory before_ = vm.readFile(file);
        address implBefore = vm.parseJsonAddress(before_, ".IAIVaultImpl");

        UpgradeScript u = _upgrade();
        u.snapshot();
        u.upgradeVault();
        u.postUpgradeCheck();

        address implAfter = vm.parseJsonAddress(vm.readFile(file), ".IAIVaultImpl");
        assertTrue(implAfter != implBefore, "the record names the new implementation");
        _iai().checkDeployment();
    }
}
