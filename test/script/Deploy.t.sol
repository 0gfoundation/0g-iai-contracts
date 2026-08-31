// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

import {IAIScript} from "../../script/deploy/IAI.s.sol";
import {MockScript} from "../../script/deploy/Mock.s.sol";
import {IAI} from "../../src/IAI.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {CreditRegistry} from "../../src/CreditRegistry.sol";
import {MockA0G} from "../../src/mocks/MockA0G.sol";

/**
 * @title DeployScriptTest
 * @notice Runs the deployment scripts exactly as an operator would, against a scratch
 *         deployment directory, and then uses what they produced.
 *
 * @dev The unit suite already exercises the wiring, because the fixture inherits the same
 *      `IAIDeployer`. What is only reachable here is everything *around* it: reading the
 *      parameter file, handing those values to the deployer, writing the addresses back,
 *      and the operational entrypoints. Without this, a typo in a JSON key would ship.
 *
 *      `DEPLOYMENT_PATH` is redirected so the committed per-network files are never touched.
 */
contract DeployScriptTest is Test {
    uint256 internal constant DEPLOYER_PK =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    string internal dir;
    string internal file;

    function setUp() public {
        dir = _scratchDir("deploy-test");
        file = string.concat(dir, "/iai-", vm.toString(block.chainid), ".json");

        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(DEPLOYER_PK)));

        // The operator's starting point: copy the shipped template and fill in the blanks.
        string memory template = vm.readFile(string.concat(vm.projectRoot(), "/deployments/iai-example.json"));
        vm.writeFile(file, template);
        vm.writeJson(vm.toString(vm.addr(DEPLOYER_PK)), file, ".Foundation");
    }

    /// @dev Mock first (it writes `A0G`), then the system, exactly as the runbook says.
    function test_Scripts_DeployAWorkingSystemAndRecordIt() public {
        _MockScript().run();
        _IAIScript().run();

        string memory json = vm.readFile(file);

        // Every address the frontend and the upgrade script depend on must be recorded.
        address tokenAddr = vm.parseJsonAddress(json, ".IAI");
        address vaultAddr = vm.parseJsonAddress(json, ".IAIVault");
        address registryAddr = vm.parseJsonAddress(json, ".CreditRegistry");
        assertTrue(tokenAddr != address(0) && vaultAddr != address(0) && registryAddr != address(0));
        assertTrue(vm.parseJsonAddress(json, ".IAIBeacon") != address(0), "beacon recorded for upgrades");
        assertTrue(vm.parseJsonAddress(json, ".IAIVaultBeacon") != address(0));
        assertTrue(vm.parseJsonAddress(json, ".CreditRegistryBeacon") != address(0));
        assertTrue(vm.parseJsonAddress(json, ".IAIVaultImpl") != address(0));

        // The mock addresses a prior run wrote must survive the rewrite, or the next
        // deployment would lose track of its own collateral.
        address mockA0G = vm.parseJsonAddress(json, ".MockA0G");
        assertEq(vm.parseJsonAddress(json, ".A0G"), mockA0G, "A0G points at the deployed mock");
        assertTrue(vm.parseJsonAddress(json, ".MockA0GOracle") != address(0), "mock oracle preserved");

        IAI token = IAI(tokenAddr);
        IAIVault vault = IAIVault(vaultAddr);

        // The recorded slope must match what the vault actually derived.
        assertEq(vm.parseJsonUint(json, ".Slope"), vault.slope(), "recorded slope matches the chain");
        assertEq(vm.parseJsonUint(json, ".Cap"), vault.cap(), "inputs echoed back intact");
        assertEq(token.cap(), vault.cap());

        // A deployment that arrives open would be a launch incident.
        assertTrue(vault.paused(), "vault must arrive paused");
        assertFalse(CreditRegistry(registryAddr).paused(), "registry needs no launch gate");

        // Whoever deployed must be able to open them and to hand the keys over.
        address deployer = vm.addr(DEPLOYER_PK);
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), deployer), "deployer can unpause");
        assertTrue(vault.hasRole(0x00, deployer), "deployer is the admin");

        // Keys the scripts do not own must survive being rewritten around.
        assertEq(vm.parseJsonUint(json, ".MockApr"), 36.5e18, "operator parameters preserved");
        assertEq(vm.parseJsonUint(json, ".MockOracleMaxAge"), 21 days);

        // A rerun redeploys, but must not lose what it does not own.
        _IAIScript().run();
        string memory json2 = vm.readFile(file);
        assertEq(vm.parseJsonAddress(json2, ".MockA0G"), mockA0G, "rerun keeps the mock");
        assertEq(vm.parseJsonUint(json2, ".MockApr"), 36.5e18, "rerun keeps the parameters");
    }

    function test_Scripts_ProduceASystemThatActuallyWorks() public {
        _MockScript().run();
        _IAIScript().run();

        IAIScript ops = _IAIScript();
        ops.unpause();

        string memory json = vm.readFile(file);
        IAIVault vault = IAIVault(vm.parseJsonAddress(json, ".IAIVault"));
        IAI token = IAI(vm.parseJsonAddress(json, ".IAI"));
        MockA0G a0g = MockA0G(vm.parseJsonAddress(json, ".A0G"));
        CreditRegistry registry = CreditRegistry(vm.parseJsonAddress(json, ".CreditRegistry"));

        assertFalse(vault.paused(), "unpause entrypoint works");

        // Mint through the deployed system.
        address user = makeAddr("user");
        (, uint256 a0GIn) = vault.quoteMint(1e18);
        a0g.mint(user, a0GIn);
        vm.prank(user);
        a0g.approve(address(vault), a0GIn);
        vm.prank(user);
        vault.mint(1e18, a0GIn, block.timestamp);
        assertEq(token.balanceOf(user), 1e18, "minting works end to end");

        // Stake through the deployed registry.
        vm.prank(user);
        token.approve(address(registry), 1e18);
        vm.prank(user);
        registry.stake(1e18);
        assertEq(registry.stakedOf(user), 1e18, "staking works end to end");

        // Harvest entrypoint, after the mock oracle has accrued.
        vm.warp(block.timestamp + 2 days);
        assertGt(vault.pendingSurplus(), 0, "mock oracle accrues fast enough to be observable");
        ops.harvest();
        assertEq(vault.pendingSurplus(), 0, "harvest entrypoint swept it");

        // Read-only entrypoint must not revert against a real deployment.
        ops.status();

        // Pause entrypoint closes both contracts again.
        ops.pause();
        assertTrue(vault.paused());
        assertTrue(registry.paused());

    }

    /// @dev Pointing the vault at mock collateral on mainnet would be unrecoverable, so the
    ///      script refuses rather than relying on the operator noticing.
    function test_MockScript_RefusesOnMainnet() public {
        MockScript s = _MockScript();
        vm.chainId(16_661);
        vm.expectRevert(bytes("refusing to deploy mock collateral to mainnet"));
        s.run();
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
}
