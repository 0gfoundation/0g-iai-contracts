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
    }


    function test_Initialize_ImplementationIsLocked() public {
        IAI impl = new IAI();
        vm.expectRevert();
        impl.initialize("x", "x");
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
