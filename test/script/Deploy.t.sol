// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

import {IAIScript} from "../../script/deploy/IAI.s.sol";
import {MockScript} from "../../script/deploy/Mock.s.sol";
import {IAI} from "../../src/IAI.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {CreditRegistry} from "../../src/CreditRegistry.sol";
import {MockA0G} from "../../src/mocks/MockA0G.sol";
import {LinearMintCurve} from "../../src/curves/LinearMintCurve.sol";

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

    uint256 internal constant CAP = 9_270e18;

    string internal dir;
    string internal file;

    function setUp() public {
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
        dir = string.concat(vm.projectRoot(), "/cache/deploy-test-", name);
        vm.createDir(dir, true);
        file = string.concat(dir, "/iai-", vm.toString(block.chainid), ".json");

        // The operator's starting point: copy the shipped template and fill in the blanks.
        string memory template = vm.readFile(string.concat(vm.projectRoot(), "/deployments/iai-example.json"));
        vm.writeFile(file, template);
        vm.writeJson(vm.toString(vm.addr(DEPLOYER_PK)), file, ".Foundation");
    }

    /// @dev Mock first (it writes `A0G`), then the system, exactly as the runbook says.
    function test_Scripts_DeployAWorkingSystemAndRecordIt() public {
        _bootstrap("records-it");
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

        IAIVault vault = IAIVault(vaultAddr);

        // The active curve must be recorded both as `MintCurve` and under its own kind, so a
        // record can hold several deployed curves and still say which one is pricing.
        address recordedCurve = vm.parseJsonAddress(json, ".MintCurve");
        assertEq(recordedCurve, address(vault.curve()), "recorded curve matches the chain");
        assertEq(vm.parseJsonAddress(json, ".LinearMintCurve"), recordedCurve, "recorded under its kind");
        assertEq(vm.parseJsonString(json, ".MintCurveKind"), "LinearMintCurve");
        assertEq(vm.parseJsonUint(json, ".Cap"), vault.cap(), "inputs echoed back intact");

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

    /**
     * @dev Rerunning the mock script on a network that already has one must reuse it. This is
     *      the single most destructive thing in the deployment scripts if it is wrong, and it
     *      is invisible when it goes wrong: an unconditional redeploy leaves every balance
     *      ever minted sitting in the old collateral token while the newly deployed system
     *      points at a fresh, empty one. Nothing reverts. On the testnet, where fifty funded
     *      accounts hold their a0G in that contract, it is total and silent loss.
     *
     *      Redeploying the *system* against the same collateral is a supported operation --
     *      it is how the testnet gets a rebuilt vault without re-funding the accounts -- so
     *      this asserts the address is unchanged and that a real balance survived it.
     */
    function test_MockScript_ReusesTheCollateralItAlreadyDeployed() public {
        _bootstrap("mock-idempotent");
        _MockScript().run();

        string memory json = vm.readFile(file);
        address mockA0G = vm.parseJsonAddress(json, ".MockA0G");
        address mockOracle = vm.parseJsonAddress(json, ".MockA0GOracle");

        // Someone holds collateral in it, the way the funded test accounts do.
        address holder = makeAddr("funded account");
        MockA0G(mockA0G).mint(holder, 400_000e18);

        _MockScript().run();

        string memory json2 = vm.readFile(file);
        assertEq(vm.parseJsonAddress(json2, ".MockA0G"), mockA0G, "the collateral token was reused");
        assertEq(vm.parseJsonAddress(json2, ".MockA0GOracle"), mockOracle, "and so was its oracle");
        assertEq(vm.parseJsonAddress(json2, ".A0G"), mockA0G, "the system still points at it");
        assertEq(MockA0G(mockA0G).balanceOf(holder), 400_000e18, "the balance was not orphaned");

        // And the system deploys fresh against that same collateral.
        _IAIScript().run();
        assertEq(
            vm.parseJsonAddress(vm.readFile(file), ".A0G"), mockA0G, "redeployed against the same a0G"
        );
    }

    /**
     * @dev The curve's anchor and the vault's cap start life as the same number and then part
     *      company: `setCap` moves the vault's, while the anchor is burned into a deployed
     *      curve and only records how its slope was reached.
     *
     *      They used to share one record key, so deploying a curve after any cap change
     *      derived a **different curve** from the same published `R0` and `Target` -- silently,
     *      since every number involved still looked reasonable. Doubling the cap and
     *      redeploying produced a slope of 271850478687441015 instead of
     *      2021598247004348741: a curve nobody asked for, and one the golden vectors would
     *      never be checked against because they only ever run against the constants.
     */
    function test_DeployCurve_IsUnaffectedByACapChange() public {
        _bootstrap("curve-anchor");
        _MockScript().run();
        _IAIScript().run();

        address original = vm.parseJsonAddress(vm.readFile(file), ".MintCurve");
        uint256 slope = LinearMintCurve(original).slope();
        assertEq(slope, 2_021_598_247_004_348_741, "the deployed curve is the published one");

        // Governance moves the ceiling; the record follows.
        _IAIScript().setCap(CAP * 2);
        assertEq(vm.parseJsonUint(vm.readFile(file), ".Cap"), CAP * 2, "the vault's cap moved");

        _IAIScript().deployCurve("LinearMintCurve");

        LinearMintCurve redeployed =
            LinearMintCurve(vm.parseJsonAddress(vm.readFile(file), ".LinearMintCurve"));
        assertTrue(address(redeployed) != original, "a new curve was deployed");
        assertEq(redeployed.slope(), slope, "the same parameters produced the same curve");
        assertEq(redeployed.anchorCap(), CAP, "the anchor did not follow the cap");
    }

    /**
     * @dev `deployCurve` and `setCurve` are two steps on purpose, and the check has to work in
     *      between them -- that gap is precisely where an operator wants to look at a curve
     *      before putting it in service. The check used to require the active curve to equal
     *      whatever the kind key named, which is false by construction in that window.
     *
     *      Also asserts no address is lost. The kind key holds only the newest curve of its
     *      kind, so a same-kind redeploy overwrites it; the history list is what keeps the
     *      previous one, which still priced real mints and is still live on chain.
     */
    function test_DeployCurve_LeavesTheCheckWorkingAndLosesNoAddress() public {
        _bootstrap("curve-two-step");
        _MockScript().run();
        _IAIScript().run();

        address first = vm.parseJsonAddress(vm.readFile(file), ".MintCurve");
        _IAIScript().checkDeployment();

        _IAIScript().setCap(CAP * 2); // makes the second curve a different contract
        _IAIScript().deployCurve("LinearMintCurve");
        address second = vm.parseJsonAddress(vm.readFile(file), ".LinearMintCurve");
        assertTrue(second != first, "the kind key now names the newer curve");

        // The window between the two steps: still checkable.
        _IAIScript().checkDeployment();
        assertEq(vm.parseJsonAddress(vm.readFile(file), ".MintCurve"), first, "still pricing on the first");

        _IAIScript().setCurve("LinearMintCurve");
        assertEq(vm.parseJsonAddress(vm.readFile(file), ".MintCurve"), second, "now pricing on the second");
        _IAIScript().checkDeployment();

        address[] memory history = vm.parseJsonAddressArray(vm.readFile(file), ".MintCurveHistory");
        assertEq(history.length, 2, "both curves are still named");
        assertEq(history[0], first, "the superseded curve was not dropped");
        assertEq(history[1], second);
    }

    function test_Scripts_ProduceASystemThatActuallyWorks() public {
        _bootstrap("works");
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
        _bootstrap("refuses-mainnet");
        MockScript s = _MockScript();
        vm.chainId(16_661);
        vm.expectRevert(bytes("refusing to deploy mock collateral to mainnet"));
        s.run();
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
