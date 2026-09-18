// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IAI} from "../src/IAI.sol";
import {IAIVault} from "../src/IAIVault.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {IIAIVault} from "../src/interfaces/IIAIVault.sol";
import {MockA0G} from "../src/mocks/MockA0G.sol";
import {MockA0GOracle} from "../src/mocks/MockA0GOracle.sol";
import {IAIDeployer} from "../script/deploy/IAIDeployer.sol";
import {LinearMintCurve} from "../src/curves/LinearMintCurve.sol";

/**
 * @notice Shared fixture.
 *
 * @dev Builds the system by calling the **deployment script's own wiring**, not a copy of
 *      it. A fixture that re-implemented the topology would leave the script untested and
 *      let the two drift: the suite could stay green against a system the script no longer
 *      produces. Inheriting `IAIDeployer` means every test run is also a rehearsal of the
 *      deployment, including its post-deploy sanity checks.
 */
abstract contract BaseTest is Test, IAIDeployer {
    uint256 internal constant WAD = 1e18;

    uint256 internal constant R0 = 4_330e18;
    uint256 internal constant CAP = 9_270e18;
    /// The foundation's cut of collateral appreciation the fixture deploys with.
    uint256 internal constant HARVEST_SHARE = 0.5e18;
    uint256 internal constant TARGET = 127_000_000e18;
    uint256 internal constant SLOPE = 2_021_598_247_004_348_741;

    /// @dev The a0G rate observed on 0G mainnet, so the fixture starts from a real number.
    uint256 internal constant ER0 = 1_108_109_704_765_932_179;
    uint256 internal constant ORACLE_MAX_AGE = 21 days;
    uint256 internal constant DEFAULT_APR = 0.15e18;
    uint256 internal constant COOLDOWN = 1 days;

    IAI internal iai;
    IAIVault internal vault;
    CreditRegistry internal registry;
    MockA0G internal a0g;
    MockA0GOracle internal oracle;
    LinearMintCurve internal mintCurve;

    UpgradeableBeacon internal iaiBeacon;
    UpgradeableBeacon internal vaultBeacon;
    UpgradeableBeacon internal registryBeacon;

    address internal admin = address(this);
    address internal guardian = makeAddr("guardian");
    address internal foundation = makeAddr("foundation");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        // Same helper the testnet script uses, so the fixture cannot drift from what gets
        // deployed. Only the numbers differ, and they come from the deployment file there.
        (oracle, a0g,) = _deployMockCollateral(
            MockConfig({asset: address(0), initialValue: ER0, apr: DEFAULT_APR, maxAge: ORACLE_MAX_AGE}), admin
        );

        Deployment memory d = _deployIAISystem(
            Config({
                a0G: address(a0g),
                foundation: foundation,
                curveKind: "LinearMintCurve",
                cap: CAP,
                harvestShare: HARVEST_SHARE,
                cooldownDuration: COOLDOWN,
                name: "Infinite AI",
                symbol: "iAI"
            }),
            // Typed, not name-dispatched: the fixture states which curve it wants and gives
            // that curve's own parameters, exactly as the script does after resolving a kind.
            _deployLinearCurve(LinearCurveParams({r0: R0, anchorCap: CAP, target: TARGET})),
            admin,
            admin
        );

        iai = IAI(d.iai);
        vault = IAIVault(d.vault);
        registry = CreditRegistry(d.registry);
        mintCurve = LinearMintCurve(d.curve);
        iaiBeacon = UpgradeableBeacon(d.iaiBeacon);
        vaultBeacon = UpgradeableBeacon(d.vaultBeacon);
        registryBeacon = UpgradeableBeacon(d.registryBeacon);

        // The deployment already grants PAUSER_ROLE to whoever deployed; the fixture only
        // adds the roles a real launch would hand out afterwards. Deliberately not
        // re-granting PAUSER here -- doing so would hide a deployment that forgot to.
        vault.grantRole(vault.PAUSER_ROLE(), guardian);
        registry.grantRole(registry.PAUSER_ROLE(), guardian);

        // Issuance deploys paused; open it for the tests that are not about pausing. The
        // registry needs no such step -- it deploys open.
        vm.prank(guardian);
        vault.unpause();

        vm.label(address(iai), "iAI");
        vm.label(address(vault), "IAIVault");
        vm.label(address(registry), "CreditRegistry");
        vm.label(address(a0g), "a0G");
        vm.label(address(oracle), "oracle");
        vm.label(address(mintCurve), "LinearMintCurve");
    }

    // --- helpers ---

    /// @notice Funds `who` with enough a0G to mint `d` iAI and approves the vault.
    function _fund(address who, uint256 d) internal returns (uint256 a0GIn) {
        (, a0GIn) = vault.quoteMint(d);
        a0g.faucetMint(who, a0GIn);
        vm.prank(who);
        a0g.approve(address(vault), a0GIn);
    }

    /// @notice Mints `d` iAI for `who`, funding and approving as needed.
    function _mintFor(address who, uint256 d) internal returns (uint256 a0GIn) {
        a0GIn = _fund(who, d);
        vm.prank(who);
        vault.mint(d, type(uint256).max, block.timestamp);
    }

    function _burn(address who, uint256 b) internal {
        vm.prank(who);
        vault.burn(b, block.timestamp);
    }

    /// @notice Sum of `locked0G` over the actors a test touches, for the accounting invariant.
    function _sumLocked(address[] memory accounts) internal view returns (uint256 total) {
        for (uint256 i = 0; i < accounts.length; i++) {
            (uint256 locked,,) = vault.positionOf(accounts[i]);
            total += locked;
        }
    }

    function _actors() internal view returns (address[] memory a) {
        a = new address[](3);
        a[0] = alice;
        a[1] = bob;
        a[2] = carol;
    }

    /// @dev Solvency: the vault must always hold at least what it owes at the current rate.
    /**
     * @dev Two statements, and the difference between them matters.
     *
     *      The promise is that every holder can be paid, so that is asserted directly and
     *      strictly: the sum of what each position would actually receive never exceeds what
     *      the vault holds.
     *
     *      `owed` is the vault's own accounting figure and is deliberately a ceiling -- the
     *      totals round up where a position rounds down, so that the sweep can never take a
     *      wei a redeemer is still entitled to. That makes it an upper bound on the promise
     *      rather than the promise itself, and after a change of split it can sit a few wei
     *      above the balance while every position remains fully covered. `harvest` already
     *      treats that case as nothing to sweep. The slack allowed here is per change, which
     *      is where it comes from.
     */
    function _assertSolvent() internal view {
        uint256 held = a0g.balanceOf(address(vault));
        uint256 er = vault.exchangeRate();

        address[] memory who = _actors();
        uint256 payable_;
        for (uint256 i = 0; i < who.length; i++) {
            (uint256 claim0G, uint256 claimA0G,) = vault.positionClaims(who[i]);
            payable_ += (claim0G * WAD) / er + claimA0G;
        }
        assertGe(held, payable_, "vault must be able to pay every position");

        uint256 owed = Math_ceilDiv(vault.totalClaim0G() * WAD, er) + vault.totalClaimA0G();
        assertLe(owed, held + 4 * (vault.currentEpoch() + 1), "the obligation is a ceiling, not a gap");
    }

    function Math_ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /**
     * @notice How far a position's recorded value may sit from the curve price that created it.
     * @param mints Number of mints the figure has to cover.
     *
     * @dev A mint splits its claim into a 0G half and an a0G half and floors both, while the
     *      a0G it collected was itself rounded up. The position therefore lands within a few
     *      wei of the curve's price rather than exactly on it -- a wei from each floor, and a
     *      share's worth from each conversion, a share being `rate / WAD` in 0G. The residue
     *      belongs to nobody and leaves as surplus.
     */
    function _mintDust(uint256 mints) internal view returns (uint256) {
        return mints * (2 + 2 * (oracle.getValue() / WAD));
    }


    /**
     * @notice Advances the clock by `by` seconds.
     *
     * @dev Use this rather than `_warp(by)`. Under `via_ir` the compiler
     *      reads `TIMESTAMP` once per function and reuses the value across the cheatcode
     *      calls between, so a second warp written that way targets the same moment as the
     *      first and the clock silently stops advancing -- no revert, no warning, just a test
     *      that no longer exercises the passage of time it claims to. Three tests in this
     *      suite were doing exactly that. Reading the timestamp back through a cheatcode
     *      cannot be folded away.
     */
    function _warp(uint256 by) internal {
        vm.warp(vm.getBlockTimestamp() + by);
    }

}
