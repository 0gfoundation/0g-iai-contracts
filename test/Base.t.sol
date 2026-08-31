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

/**
 * @notice Shared fixture. Deploys the same impl/beacon/proxy topology the deploy script
 *         builds, so the tests exercise the contracts through a proxy exactly as production
 *         does — a plain `new` would miss initializer and storage-slot problems entirely.
 */
abstract contract BaseTest is Test {
    uint256 internal constant WAD = 1e18;

    uint256 internal constant R0 = 4_330e18;
    uint256 internal constant CAP = 9_270e18;
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

    UpgradeableBeacon internal iaiBeacon;
    UpgradeableBeacon internal vaultBeacon;
    UpgradeableBeacon internal registryBeacon;

    address internal admin = address(this);
    address internal guardian = makeAddr("guardian");
    address internal rescuer = makeAddr("rescuer");
    address internal foundation = makeAddr("foundation");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        oracle = new MockA0GOracle(ER0, DEFAULT_APR, ORACLE_MAX_AGE, admin);
        a0g = new MockA0G(address(oracle));

        iaiBeacon = new UpgradeableBeacon(address(new IAI()), admin);
        iai = IAI(
            address(
                new BeaconProxy(
                    address(iaiBeacon), abi.encodeCall(IAI.initialize, ("Infinite AI", "iAI", CAP))
                )
            )
        );

        vaultBeacon = new UpgradeableBeacon(address(new IAIVault()), admin);
        vault = IAIVault(
            address(
                new BeaconProxy(
                    address(vaultBeacon),
                    abi.encodeCall(
                        IAIVault.initialize,
                        (
                            IIAIVault.InitParams({
                                iai: address(iai),
                                a0G: address(a0g),
                                foundation: foundation,
                                r0: R0,
                                cap: CAP,
                                target: TARGET
                            })
                        )
                    )
                )
            )
        );

        registryBeacon = new UpgradeableBeacon(address(new CreditRegistry()), admin);
        registry = CreditRegistry(
            address(
                new BeaconProxy(
                    address(registryBeacon), abi.encodeCall(CreditRegistry.initialize, (address(iai), COOLDOWN))
                )
            )
        );

        iai.grantRole(iai.MINTER_BURNER_ROLE(), address(vault));
        vault.grantRole(vault.PAUSER_ROLE(), guardian);
        vault.grantRole(vault.RESCUE_ROLE(), rescuer);
        registry.grantRole(registry.PAUSER_ROLE(), guardian);

        // Both contracts deploy paused; open them for the tests that are not about pausing.
        vm.prank(guardian);
        vault.unpause();
        vm.prank(guardian);
        registry.unpause();

        vm.label(address(iai), "iAI");
        vm.label(address(vault), "IAIVault");
        vm.label(address(registry), "CreditRegistry");
        vm.label(address(a0g), "a0G");
        vm.label(address(oracle), "oracle");
    }

    // --- helpers ---

    /// @notice Funds `who` with enough a0G to mint `d` iAI and approves the vault.
    function _fund(address who, uint256 d) internal returns (uint256 a0GIn) {
        (, a0GIn) = vault.quoteMint(d);
        a0g.mint(who, a0GIn);
        vm.prank(who);
        a0g.approve(address(vault), a0GIn);
    }

    /// @notice Mints `d` iAI for `who`, funding and approving as needed.
    function _mintFor(address who, uint256 d) internal returns (uint256 a0GIn) {
        a0GIn = _fund(who, d);
        vm.prank(who);
        vault.mint(d, type(uint256).max, type(uint256).max, block.timestamp);
    }

    function _burnFor(address who, uint256 b) internal {
        vm.prank(who);
        vault.burn(b, 0, block.timestamp);
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
    function _assertSolvent() internal view {
        uint256 owed = Math_ceilDiv(vault.totalLocked0G() * WAD, vault.exchangeRate());
        assertGe(a0g.balanceOf(address(vault)), owed, "vault must cover its obligations");
    }

    function Math_ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
