// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "../Base.t.sol";
import {IAI} from "../../src/IAI.sol";
import {IIAI} from "../../src/interfaces/IIAI.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract IAITest is BaseTest {
    function test_Metadata() public view {
        assertEq(iai.name(), "Infinite AI");
        assertEq(iai.symbol(), "iAI");
        assertEq(iai.decimals(), 18);
        assertEq(iai.cap(), CAP);
    }

    function test_Initialize_RejectsZeroCap() public {
        address beacon = address(new UpgradeableBeacon(address(new IAI()), admin));
        vm.expectRevert(IIAI.ZeroCap.selector);
        new BeaconProxy(beacon, abi.encodeCall(IAI.initialize, ("x", "x", 0)));
    }

    function test_Initialize_ImplementationIsLocked() public {
        IAI impl = new IAI();
        vm.expectRevert();
        impl.initialize("x", "x", CAP);
    }

    /// @dev The vault is the only issuer. Anything else would let total supply drift away
    ///      from the vault's own accounting.
    function test_MintAndBurn_OnlyByTheVault() public {
        bytes32 role = iai.MINTER_BURNER_ROLE();
        assertTrue(iai.hasRole(role, address(vault)));
        assertFalse(iai.hasRole(role, admin), "the deployer must not keep issuance rights");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        vm.prank(alice);
        iai.mint(alice, 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        vm.prank(alice);
        iai.burn(alice, 1e18);
    }

    /// @dev There is deliberately no self-burn path. A holder destroying their own tokens
    ///      would desynchronise total supply from the vault and permanently strand the
    ///      collateral behind them, since redemption requires handing the tokens back.
    function test_HolderCannotBurnTheirOwnTokens() public {
        _mintFor(alice, 10e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, iai.MINTER_BURNER_ROLE()
            )
        );
        vm.prank(alice);
        iai.burn(alice, 10e18);
    }

    function test_Cap_IsEnforcedIndependentlyOfTheVault() public {
        // Grant the role to this test so the cap can be probed without the vault's own check.
        iai.grantRole(iai.MINTER_BURNER_ROLE(), admin);
        iai.mint(alice, CAP);
        vm.expectRevert(abi.encodeWithSelector(IIAI.CapExceeded.selector, CAP + 1, CAP));
        iai.mint(alice, 1);
    }

    /// @dev The compute entitlement is a bearer right, so transfer must stay unrestricted.
    function test_TransfersAreUnrestricted() public {
        _mintFor(alice, 10e18);
        vm.prank(alice);
        iai.transfer(bob, 4e18);
        assertEq(iai.balanceOf(bob), 4e18);

        vm.prank(bob);
        iai.approve(carol, 4e18);
        vm.prank(carol);
        iai.transferFrom(bob, carol, 4e18);
        assertEq(iai.balanceOf(carol), 4e18);
    }
}
