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
import {ExponentialMintCurve} from "../../src/curves/ExponentialMintCurve.sol";
import {ExponentialTable} from "../unit/curves/ExponentialTable.sol";
import {IIAIVault} from "../../src/interfaces/IIAIVault.sol";
import {IMintCurve} from "../../src/interfaces/IMintCurve.sol";
import {MockW0G} from "../../src/mocks/MockW0G.sol";

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
        assertEq(vm.parseJsonAddress(json, ".ExponentialMintCurve"), recordedCurve, "recorded under its kind");
        assertEq(vm.parseJsonString(json, ".MintCurveKind"), "ExponentialMintCurve", "the default kind");
        assertEq(vm.parseJsonUint(json, ".Cap"), vault.cap(), "inputs echoed back intact");

        // The curve's own parameters are nested under its kind, and the script rewrites the
        // record around them without flattening or dropping them. Worth an assertion because
        // every other key in this file is a single flat level, so a future `serializeJson`
        // change would take the nesting out silently and `deployCurve` would stop resolving.
        // The exponential block carries a 371-entry array, which is the shape most at risk.
        string memory at = string.concat(".CurveParams.", vm.parseJsonString(json, ".MintCurveKind"), ".");
        assertEq(vm.parseJsonUint(json, string.concat(at, "BucketWidth")), 25e18);
        assertEq(vm.parseJsonUint(json, string.concat(at, "Base")), 3237.4e18);
        assertEq(vm.parseJsonUint(json, string.concat(at, "Exponent")), 3.419e18);
        assertEq(vm.parseJsonUint(json, string.concat(at, "Target")), CAP);
        uint256[] memory prices = vm.parseJsonUintArray(json, string.concat(at, "Prices"));
        assertEq(prices.length, 371, "the whole table survived the rewrite");
        assertEq(prices[0], 3_237_400_217_108_237_297_865, "and so did its entries");
        assertEq(prices[370], 99_415_286_098_687_872_720_911);

        // The other kind's block is carried along too, so `deployCurve("LinearMintCurve")`
        // keeps resolving on a record whose default is the exponential curve.
        assertEq(vm.parseJsonUint(json, ".CurveParams.LinearMintCurve.R0"), 4330e18);
        assertEq(vm.parseJsonUint(json, ".CurveParams.LinearMintCurve.AnchorCap"), CAP);
        assertEq(vm.parseJsonUint(json, ".CurveParams.LinearMintCurve.Target"), 127_000_000e18);

        // And the deployed curve is the table the record describes, entry for entry -- which
        // is also what `checkDeployment` re-verifies on every run.
        ExponentialMintCurve deployedCurve = ExponentialMintCurve(recordedCurve);
        assertEq(deployedCurve.bucketCount(), 371);
        assertEq(deployedCurve.priceAt(80), prices[80]);
        assertEq(deployedCurve.maxSafeSupply(), 9275e18, "the table's top, five iAI above the cap");

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
        MockA0G(mockA0G).faucetMint(holder, 400_000e18);

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

        // The default deployment is the exponential curve; the linear one is deployed on the
        // side, from the block the record still carries for it.
        _IAIScript().deployCurve("LinearMintCurve");
        address original = vm.parseJsonAddress(vm.readFile(file), ".LinearMintCurve");
        uint256 slope = LinearMintCurve(original).slope();
        assertEq(slope, 2_021_598_247_004_348_741, "the deployed curve is the published one");

        // Governance moves the ceiling; the record follows. Lowered rather than raised: the
        // exponential curve in force prices up to 9,275 iAI and the vault refuses a cap above
        // that, while lowering never consults the curve.
        _IAIScript().setCap(CAP / 2);
        assertEq(vm.parseJsonUint(vm.readFile(file), ".Cap"), CAP / 2, "the vault's cap moved");

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

        _IAIScript().setCap(CAP / 2); // the record changes underneath; the curve does not care
        _IAIScript().deployCurve("LinearMintCurve");
        address second = vm.parseJsonAddress(vm.readFile(file), ".LinearMintCurve");
        assertTrue(second != first, "the linear kind key names a curve the default never deployed");

        // The window between the two steps: still checkable, and the exponential table check
        // still runs against the exponential kind key, which is still the deployed curve.
        _IAIScript().checkDeployment();
        assertEq(vm.parseJsonAddress(vm.readFile(file), ".MintCurve"), first, "still pricing on the first");

        _IAIScript().setCurve("LinearMintCurve");
        assertEq(vm.parseJsonAddress(vm.readFile(file), ".MintCurve"), second, "now pricing on the second");
        assertEq(vm.parseJsonString(vm.readFile(file), ".MintCurveKind"), "LinearMintCurve");
        _IAIScript().checkDeployment();

        // And back: the testnet swap, rehearsed in both directions.
        _IAIScript().setCurve("ExponentialMintCurve");
        assertEq(vm.parseJsonAddress(vm.readFile(file), ".MintCurve"), first, "pricing on the exponential curve again");
        _IAIScript().checkDeployment();

        address[] memory history = vm.parseJsonAddressArray(vm.readFile(file), ".MintCurveHistory");
        assertEq(history.length, 2, "both curves are still named");
        assertEq(history[0], first, "the superseded curve was not dropped");
        assertEq(history[1], second);
    }

    /**
     * @dev The table is constructor data, so nothing on chain can say whether a deployed curve
     *      is the one the record describes -- except this check. Edit a parameter beside the
     *      table without regenerating and redeploying, and `check` must refuse until the
     *      record and the chain agree again.
     */
    function test_CheckDeployment_RefusesATableThatDisagreesWithItsParameters() public {
        _bootstrap("curve-table-check");
        _MockScript().run();
        _IAIScript().run();
        _IAIScript().checkDeployment();

        string memory key = ".CurveParams.ExponentialMintCurve.BucketWidth";
        vm.writeJson(vm.toString(uint256(50e18)), file, key);

        IAIScript checker = _IAIScript();
        vm.expectRevert(bytes("curve bucket width differs from the record"));
        checker.checkDeployment();

        // Restoring the record restores the check.
        vm.writeJson(vm.toString(uint256(25e18)), file, key);
        _IAIScript().checkDeployment();
    }

    /**
     * @dev The consequence operators will meet first: the exponential curve prices up to the
     *      top of its table and no further, so a cap above it cannot be paired with it in
     *      either order. Raising the cap past the table means deploying a taller table first.
     */
    function test_SetCurve_ExponentialRefusesACapAboveItsTable() public {
        _bootstrap("curve-domain");
        _MockScript().run();
        _IAIScript().run();

        // The reverts are provoked on the vault directly, as the deployer: a revert inside a
        // script leaves forge's broadcast open and the next script call trips over it.
        IAIVault vault = IAIVault(vm.parseJsonAddress(vm.readFile(file), ".IAIVault"));
        address deployer = vm.addr(DEPLOYER_PK);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IIAIVault.CapAboveCurveDomain.selector, CAP * 2, 9275e18));
        vault.setCap(CAP * 2);

        // The linear curve has room to spare, so the cap can move once it is in force ...
        _IAIScript().deployCurve("LinearMintCurve");
        _IAIScript().setCurve("LinearMintCurve");
        _IAIScript().setCap(CAP * 2);

        // ... but the exponential curve then cannot come back until the cap is inside its table.
        address exponentialCurve = vm.parseJsonAddress(vm.readFile(file), ".ExponentialMintCurve");
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IIAIVault.CapAboveCurveDomain.selector, CAP * 2, 9275e18));
        vault.setCurve(IMintCurve(exponentialCurve));

        _IAIScript().setCap(9275e18);
        _IAIScript().setCurve("ExponentialMintCurve");
        _IAIScript().checkDeployment();
        assertEq(address(vault.curve()), exponentialCurve, "back on the table, with the cap at its top");
    }

    /// @dev The unit tests may not read files, so they use a generated Solidity copy of the
    ///      table. This is the one place both are in reach; if they ever differ, the copy is
    ///      stale and `gen_exponential_table.py --solidity` regenerates it.
    function test_ExponentialTableLibrary_MatchesTheRecord() public view {
        string memory template = vm.readFile(string.concat(vm.projectRoot(), "/deployments/iai-example.json"));
        string memory at = ".CurveParams.ExponentialMintCurve.";
        uint256[] memory recorded = vm.parseJsonUintArray(template, string.concat(at, "Prices"));
        uint128[] memory library_ = ExponentialTable.prices();

        assertEq(library_.length, recorded.length, "same number of buckets");
        for (uint256 i = 0; i < recorded.length; i++) {
            assertEq(uint256(library_[i]), recorded[i], "same price");
        }
        assertEq(ExponentialTable.BUCKET_WIDTH, vm.parseJsonUint(template, string.concat(at, "BucketWidth")));
        assertEq(ExponentialTable.BASE, vm.parseJsonUint(template, string.concat(at, "Base")));
        assertEq(ExponentialTable.EXPONENT, vm.parseJsonUint(template, string.concat(at, "Exponent")));
        assertEq(ExponentialTable.TARGET, vm.parseJsonUint(template, string.concat(at, "Target")));
    }

    /**
     * @dev The documented way to raise the target, end to end on the Solidity side: a taller
     *      table lands in the record (what `genCurve --target` writes; synthesised here because
     *      tests cannot run the generator), then `deployCurve`, `setCurve`, and only then
     *      `setCap` -- which is refused until the new table is in force.
     */
    function test_RaisingTheTarget_IsGenCurveDeployCurveSetCurveThenSetCap() public {
        _bootstrap("curve-raise-target");
        _MockScript().run();
        _IAIScript().run();

        // A table four buckets taller, as the generator would produce for a target of 9,363
        // iAI: 375 buckets, top 9,375. The extra prices only need to keep the table monotone.
        uint128[] memory current = ExponentialTable.prices();
        uint256[] memory taller = new uint256[](current.length + 4);
        for (uint256 i = 0; i < current.length; i++) {
            taller[i] = current[i];
        }
        for (uint256 i = current.length; i < taller.length; i++) {
            taller[i] = taller[i - 1] + 1e21;
        }
        string memory o = "exp";
        vm.serializeUint(o, "Base", 3_237.4e18);
        vm.serializeUint(o, "BucketWidth", 25e18);
        vm.serializeUint(o, "Exponent", 3.419e18);
        vm.serializeUint(o, "Prices", taller);
        string memory block_ = vm.serializeUint(o, "Target", 9_363e18);
        vm.writeJson(block_, file, ".CurveParams.ExponentialMintCurve");

        IAIVault vault = IAIVault(vm.parseJsonAddress(vm.readFile(file), ".IAIVault"));
        address deployer = vm.addr(DEPLOYER_PK);

        // The record now describes a curve that is not deployed; the check says so.
        IAIScript checker = _IAIScript();
        vm.expectRevert(bytes("curve bucket count differs from the record"));
        checker.checkDeployment();

        _IAIScript().deployCurve("ExponentialMintCurve");
        _IAIScript().checkDeployment(); // the kind key now matches the record again
        address newer = vm.parseJsonAddress(vm.readFile(file), ".ExponentialMintCurve");
        assertEq(ExponentialMintCurve(newer).maxSafeSupply(), 9_375e18, "the new table is taller");
        assertEq(ExponentialMintCurve(newer).target(), 9_363e18);

        // Too early: the old table is still in force and stops at 9,275.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IIAIVault.CapAboveCurveDomain.selector, 9_363e18, 9_275e18));
        vault.setCap(9_363e18);

        _IAIScript().setCurve("ExponentialMintCurve");
        _IAIScript().setCap(9_363e18);
        _IAIScript().checkDeployment();

        assertEq(address(vault.curve()), newer);
        assertEq(vault.cap(), 9_363e18);
        assertEq(vm.parseJsonUint(vm.readFile(file), ".Cap"), 9_363e18);
        assertEq(vm.parseJsonAddressArray(vm.readFile(file), ".MintCurveHistory").length, 2, "both tables kept");
    }

    /// @dev Lowering the cap -- including to zero, the burn-only switch -- is a vault-side act
    ///      that the curve and its record know nothing about. Every script must keep working.
    function test_LoweringTheCap_LeavesTheCurveAndItsCheckUntouched() public {
        _bootstrap("curve-lower-cap");
        _MockScript().run();
        _IAIScript().run();

        _IAIScript().setCap(4_000e18);
        _IAIScript().checkDeployment();
        _IAIScript().deployCurve("ExponentialMintCurve"); // same parameters, same table, new address
        _IAIScript().checkDeployment();

        _IAIScript().setCap(0);
        _IAIScript().checkDeployment();
        _IAIScript().setCurve("ExponentialMintCurve");
        _IAIScript().checkDeployment();

        string memory json = vm.readFile(file);
        assertEq(vm.parseJsonUint(json, ".Cap"), 0);
        assertEq(vm.parseJsonUintArray(json, ".CurveParams.ExponentialMintCurve.Prices").length, 371, "the table did not follow the cap");
        assertEq(ExponentialMintCurve(vm.parseJsonAddress(json, ".MintCurve")).maxSafeSupply(), 9_275e18);
    }

    /**
     * @dev A record written before `MintCurveHistory` existed still names a curve. Appending
     *      only the newcomer would lose that incumbent the moment `setCurve` moves `MintCurve`
     *      off it, leaving its address nowhere in the record -- and positions it priced are
     *      still open, so reconciling them needs it.
     *
     *      This is not hypothetical: it happened on the testnet, whose record predates the
     *      list, and the first swap dropped the curve that had priced the only live position.
     */
    function test_DeployCurve_AdoptsAnIncumbentThatPredatesTheHistoryList() public {
        _bootstrap("curve-history-backfill");
        _MockScript().run();
        _IAIScript().run();

        // The older record shape: an incumbent curve and no history to speak of. A missing
        // key and an empty list reach the same branch, and the missing key is already covered
        // by every fresh deployment in this file, so the list is emptied here rather than
        // deleted -- Foundry has no cheatcode that removes a key.
        address incumbent = vm.parseJsonAddress(vm.readFile(file), ".MintCurve");
        vm.writeJson("[]", file, ".MintCurveHistory");
        assertEq(vm.parseJsonAddressArray(vm.readFile(file), ".MintCurveHistory").length, 0);

        _IAIScript().setCap(CAP / 2); // lowered: the curve in force does not price above its table
        _IAIScript().deployCurve("LinearMintCurve");

        address[] memory history = vm.parseJsonAddressArray(vm.readFile(file), ".MintCurveHistory");
        assertEq(history.length, 2, "the incumbent was adopted, not dropped");
        assertEq(history[0], incumbent, "and it comes first");
        assertEq(history[1], vm.parseJsonAddress(vm.readFile(file), ".LinearMintCurve"));
    }

    /**
     * @dev The deliberate way past the reuse guard, for the one case that needs it: the mock
     *      itself changed shape. It must actually replace the token and rewrite every key
     *      that names it, or the system would be redeployed against a stale address.
     */
    function test_MockScript_RedeployReplacesTheCollateralAndRewritesEveryKey() public {
        _bootstrap("mock-redeploy");
        _MockScript().run();

        string memory json = vm.readFile(file);
        address first = vm.parseJsonAddress(json, ".MockA0G");
        address holder = makeAddr("funded account");
        MockA0G(first).faucetMint(holder, 400_000e18);

        _MockScript().redeploy();

        string memory json2 = vm.readFile(file);
        address second = vm.parseJsonAddress(json2, ".MockA0G");
        assertTrue(second != first, "the mock really was replaced");
        assertEq(vm.parseJsonAddress(json2, ".A0G"), second, "and the system will wire to it");
        assertTrue(vm.parseJsonAddress(json2, ".MockA0GOracle") != address(0), "oracle recorded");
        assertEq(MockA0G(second).asset(), vm.parseJsonAddress(json2, ".W0G"), "underlying recorded");

        // The point of the guard this walked past: the old balance is gone, not migrated.
        assertEq(MockA0G(second).balanceOf(holder), 0, "nothing migrates -- this is the cost");
        assertEq(MockA0G(first).balanceOf(holder), 400_000e18, "it is stranded on the old token");
    }

    /**
     * @dev A network that already has the real W0G names it in the record, and the script
     *      must build the vault over that rather than deploying a stand-in beside it. Getting
     *      this wrong would give the testnet an a0G whose underlying nobody holds, so the
     *      wrapping hop it exists to exercise would not work.
     */
    function test_MockScript_UsesTheRecordedW0GAndNeverOverwritesIt() public {
        _bootstrap("mock-real-w0g");

        MockW0G real = new MockW0G();
        vm.writeJson(vm.toString(address(real)), file, ".W0G");

        _MockScript().run();

        string memory json = vm.readFile(file);
        assertEq(vm.parseJsonAddress(json, ".W0G"), address(real), "the recorded W0G stands");
        assertEq(MockA0G(vm.parseJsonAddress(json, ".MockA0G")).asset(), address(real));

        // And a redeploy keeps using it: the underlying is not ours to replace.
        _MockScript().redeploy();
        string memory json2 = vm.readFile(file);
        assertEq(vm.parseJsonAddress(json2, ".W0G"), address(real), "still the recorded one");
        assertEq(MockA0G(vm.parseJsonAddress(json2, ".MockA0G")).asset(), address(real));
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
        a0g.faucetMint(user, a0GIn);
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
