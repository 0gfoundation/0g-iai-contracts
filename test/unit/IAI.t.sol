// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "../Base.t.sol";
import {IAI} from "../../src/IAI.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

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

    /// @dev The vault is the only issuer. Anything else would let total supply drift away
    ///      from the vault's own accounting -- and total supply is what the vault prices
    ///      against, so a second issuer moves the curve for everyone. With the token's own
    ///      cap gone this role is unbounded, which makes who holds it matter more, not less.
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
