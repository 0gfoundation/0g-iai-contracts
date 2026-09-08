// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "../Base.t.sol";
import {LinearMintCurve} from "../../src/curves/LinearMintCurve.sol";
import {IMintCurve} from "../../src/interfaces/IMintCurve.sol";
import {UpgradeChecker} from "../../script/deploy/UpgradeChecker.sol";
import {IAI} from "../../src/IAI.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {CreditRegistry} from "../../src/CreditRegistry.sol";

/// @dev Any contract will do as an upgrade target for the permission test.
contract Anything {
    function r0() external pure returns (uint256) {
        return 1;
    }
}

/// @dev An implementation whose quote no longer agrees with the curve its own constants
///      describe. Only a changed implementation can produce this -- reading the live vault,
///      the quote and the curve evaluate the same storage and cannot disagree.
contract MispricingVault {
    IMintCurve public curve;

    constructor(IMintCurve curve_) {
        curve = curve_;
    }

    function supply() external pure returns (uint256) {
        return 0;
    }

    function remainingCap() external pure returns (uint256) {
        return 1e18;
    }

    /// @dev Answers a price of its own instead of the one the curve it names would give.
    function quoteMint(uint256) external pure returns (uint256, uint256) {
        return (1, 1);
    }
}

/**
 * @title UpgradeTest
 * @notice The upgrade rehearsal, exercised without touching a file.
 *
 * @dev The state comparison lives in `UpgradeChecker`, so capture, upgrade and compare all
 *      happen in one process here. The script's job -- carrying a snapshot across two separate
 *      `forge script` invocations -- is covered in `test/script/`.
 *
 *      A comparison that always passes is worse than none, so this checks both directions: an
 *      honest upgrade must pass, and a moved value must be caught by name.
 */
contract UpgradeTest is BaseTest, UpgradeChecker {
    address internal holder = makeAddr("holder");
    address[] internal watched;

    function setUp() public override {
        super.setUp();

        // Snapshot an *occupied* deployment. An upgrade over an empty one proves nothing,
        // because every number it must preserve is zero.
        _mintFor(holder, 3e18);
        vm.prank(holder);
        iai.approve(address(registry), 1e18);
        vm.prank(holder);
        registry.stake(1e18);

        watched.push(holder);
        watched.push(alice);
    }

    function _snap() internal view returns (Snapshot memory) {
        return _capture(vault, iai, registry, watched);
    }

    function test_HonestUpgradePreservesEverything() public {
        Snapshot memory before_ = _snap();
        assertGt(before_.totalLocked0G, 0, "the deployment under test is occupied");
        assertGt(before_.locked[0], 0, "the watched position is real");

        address newImpl = address(new IAIVault());
        _pointBeaconAt(address(vaultBeacon), newImpl);
        assertEq(vaultBeacon.implementation(), newImpl, "the beacon actually moved");

        _assertUnchanged(before_, _snap());
        _assertPricingMatchesCurve(vault);

        // And it must still work afterwards, not merely read the same.
        _mintFor(bob, 1e18);
        assertEq(iai.balanceOf(bob), 1e18);
    }

    function test_UpgradingTheTokenAndRegistryAlsoPreservesEverything() public {
        Snapshot memory before_ = _snap();

        _pointBeaconAt(address(iaiBeacon), address(new IAI()));
        _pointBeaconAt(address(registryBeacon), address(new CreditRegistry()));

        _assertUnchanged(before_, _snap());
    }

    /// @dev Pricing now lives outside the beacon, so the one thing an upgrade could do to
    ///      reprice the system is repoint `curve`. If the rehearsal did not snapshot that
    ///      address it would miss repricing entirely -- the loudest failure it exists to catch.
    function test_CatchesACurveSwapAcrossAnUpgrade() public {
        Snapshot memory before_ = _snap();

        address swapped = address(new LinearMintCurve(R0 * 2, CAP, TARGET));
        vault.setCurve(IMintCurve(swapped));
        assertEq(address(vault.curve()), swapped, "the curve really did move");

        Snapshot memory after_ = _snap();
        vm.expectRevert(bytes("changed across upgrade: curve"));
        this.assertUnchangedExternal(before_, after_);
    }

    /// @dev The other half of the same failure: the supply ceiling moving under an upgrade.
    function test_CatchesACapThatMoved() public {
        Snapshot memory before_ = _snap();

        vault.setCap(CAP - 1);

        Snapshot memory after_ = _snap();
        vm.expectRevert(bytes("changed across upgrade: cap"));
        this.assertUnchangedExternal(before_, after_);
    }

    /// @dev Balances are the other half: a layout shift that strands a position must be caught.
    function test_CatchesAStrandedPosition() public {
        Snapshot memory before_ = _snap();

        Snapshot memory after_ = _snap();
        after_.locked[0] = before_.locked[0] - 1;

        vm.expectRevert(bytes("changed across upgrade: position.locked0G"));
        this.assertUnchangedExternal(before_, after_);
    }

    /// @dev A moved constant is caught even without a snapshot to compare against, because
    ///      the quote is checked against an independent evaluation of the curve.
    function test_CatchesAnImplementationThatPricesOffTheCurve() public {
        _assertPricingMatchesCurve(vault); // the real one agrees

        IAIVault mispricer = IAIVault(address(new MispricingVault(vault.curve())));
        vm.expectRevert(bytes("pricing diverged from the curve"));
        this.assertPricingMatchesCurveExternal(mispricer);
    }

    /// @dev The beacon owner is the upgrade key. Nobody else may move an implementation.
    function test_OnlyTheBeaconOwnerCanUpgrade() public {
        assertEq(vaultBeacon.owner(), admin, "the deployer holds the upgrade key");

        address other = address(new Anything());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        vaultBeacon.upgradeTo(other);
    }

    /// @dev `vm.expectRevert` needs a call frame, and these are internal. Snapshots are
    ///      always taken into a local first: an argument is evaluated before the outer call,
    ///      so an inline `_snap()` would be the call the cheatcode applies to.
    function assertUnchangedExternal(Snapshot memory before_, Snapshot memory after_) external pure {
        _assertUnchanged(before_, after_);
    }

    function assertPricingMatchesCurveExternal(IAIVault v) external view {
        _assertPricingMatchesCurve(v);
    }
}
