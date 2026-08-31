// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "../Base.t.sol";
import {IIAIVault} from "../../src/interfaces/IIAIVault.sol";

/**
 * @title QuotesTest
 * @notice `quoteMintForA0G`, the "spend all of it" path.
 *
 * @dev The library's root solver is fuzzed separately; what is covered here is the vault's
 *      wrapper around it — the a0G-to-0G conversion and the headroom clamp. The property that
 *      matters is a round trip: whatever `quoteMintForA0G(x)` returns must be mintable for at
 *      most `x`. Nothing enforced that before, so flipping the conversion's rounding would
 *      have left every test green while real "mint with my whole balance" transactions began
 *      reverting on slippage.
 */
contract QuotesTest is BaseTest {
    function test_QuoteMintForA0G_RoundTripsIntoAMintThatSucceeds() public {
        uint256 x = 10_000e18;

        uint256 d = vault.quoteMintForA0G(x);
        assertGt(d, 0, "a real amount of a0G must buy something");
        (, uint256 quotedIn) = vault.quoteMint(d);

        // Funded with exactly `x`: if the quote asked for a wei more, the mint cannot pay.
        a0g.mint(alice, x);
        vm.prank(alice);
        a0g.approve(address(vault), x);
        vm.prank(alice);
        vault.mint(d, x, block.timestamp);

        assertEq(iai.balanceOf(alice), d, "minted exactly what was quoted");
        // Pinning the amount, not bounding it: `maxA0GIn = x` already made "at most x"
        // impossible to violate, so asserting that would have proved nothing.
        assertEq(x - a0g.balanceOf(alice), quotedIn, "spent exactly what quoteMint priced");
        assertLe(quotedIn, x, "the two quotes agree that this is affordable");
    }

    /// @dev The round trip has to hold everywhere, including at dust and at the far end of
    ///      the curve, since the rounding is what decides it.
    function testFuzz_QuoteMintForA0G_IsAlwaysAffordable(uint256 x, uint256 seed) public {
        // Start from an arbitrary point on the curve, not only from empty.
        uint256 warmUp = bound(seed, 0, 4_000e18);
        if (warmUp > 0) _mintFor(bob, warmUp);

        (, uint256 forTheRest) = vault.quoteMint(CAP - iai.totalSupply());
        x = bound(x, 1, forTheRest);

        uint256 d = vault.quoteMintForA0G(x);
        if (d == 0) return;

        a0g.mint(alice, x);
        vm.prank(alice);
        a0g.approve(address(vault), x);
        vm.prank(alice);
        vault.mint(d, x, block.timestamp);

        assertEq(iai.balanceOf(alice), d);
    }

    /// @dev More a0G than the curve has room for must quote the remaining headroom, not a
    ///      number that would breach the cap.
    function test_QuoteMintForA0G_ClampsToHeadroom() public {
        _mintFor(bob, 1_000e18);
        uint256 headroom = CAP - iai.totalSupply();

        (, uint256 forEverything) = vault.quoteMint(headroom);
        assertEq(vault.quoteMintForA0G(forEverything * 10), headroom, "clamped to what is left");

        // And the clamped amount is still mintable, which is the point of clamping.
        a0g.mint(alice, forEverything * 10);
        vm.prank(alice);
        a0g.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.mint(headroom, type(uint256).max, block.timestamp);
        assertEq(iai.totalSupply(), CAP, "the cap is reachable, exactly");
    }

    /// @dev Below the price of one wei of iAI there is nothing to sell.
    function test_QuoteMintForA0G_ReturnsZeroForDust() public view {
        assertEq(vault.quoteMintForA0G(0), 0);
        assertEq(vault.quoteMintForA0G(1), 0, "one wei of a0G buys no iAI at 4,330 0G each");
    }

    /// @dev A quote must fail wherever the action it prices would fail. Unguarded, the
    ///      pro-rata ratio exceeds one and reports releasing more 0G than was ever locked.
    function test_QuoteBurn_RevertsAboveThePosition_LikeBurnDoes() public {
        _mintFor(alice, 1e18);
        (uint256 locked,,) = vault.positionOf(alice);

        // Full exit is fine, one wei more is not -- and both fail the same way as `burn`.
        (uint256 unlocked,) = vault.quoteBurn(alice, 1e18);
        assertEq(unlocked, locked, "a full exit releases exactly what was locked");

        vm.expectRevert(abi.encodeWithSelector(IIAIVault.BurnExceedsPosition.selector, 1e18 + 1, 1e18));
        vault.quoteBurn(alice, 1e18 + 1);

        vm.expectRevert(abi.encodeWithSelector(IIAIVault.BurnExceedsPosition.selector, 1e18 + 1, 1e18));
        vm.prank(alice);
        vault.burn(1e18 + 1, block.timestamp);
    }

    /// @dev Someone who bought iAI on a market has tokens but no position. Quoting a burn they
    ///      cannot perform must not hand them a number.
    function test_QuoteBurn_RevertsForAHolderWithNoPosition() public {
        _mintFor(alice, 2e18);
        vm.prank(alice);
        iai.transfer(bob, 2e18);

        vm.expectRevert(abi.encodeWithSelector(IIAIVault.BurnExceedsPosition.selector, 1e18, 0));
        vault.quoteBurn(bob, 1e18);

        // Zero stays answerable, so a UI can quote an empty input box.
        (uint256 unlocked, uint256 out) = vault.quoteBurn(bob, 0);
        assertEq(unlocked, 0);
        assertEq(out, 0);
    }

    /// @dev Same principle on the issuance side: pricing an amount that can never be minted
    ///      would hand the caller a number the contract will refuse a moment later.
    function test_QuoteMint_RevertsBeyondTheCap_LikeMintDoes() public {
        _mintFor(bob, 9_000e18);
        uint256 headroom = CAP - iai.totalSupply();

        vault.quoteMint(headroom); // the exact headroom is priceable

        vm.expectRevert(abi.encodeWithSelector(IIAIVault.CapExceeded.selector, CAP + 1, CAP));
        vault.quoteMint(headroom + 1);

        _fund(alice, headroom);
        vm.expectRevert(abi.encodeWithSelector(IIAIVault.CapExceeded.selector, CAP + 1, CAP));
        vm.prank(alice);
        vault.mint(headroom + 1, type(uint256).max, block.timestamp);
    }

    /// @dev `quoteMintForA0G` deliberately does not follow that rule. It is asked what a spend
    ///      buys, not for a named amount, so the remaining headroom is a true answer.
    function test_QuoteMintForA0G_ClampsWhereQuoteMintWouldRevert() public {
        _mintFor(bob, 9_000e18);
        uint256 headroom = CAP - iai.totalSupply();
        (, uint256 forEverything) = vault.quoteMint(headroom);

        assertEq(vault.quoteMintForA0G(forEverything * 100), headroom, "clamped, not reverted");
    }

    /**
     * @dev Which error an underfunded mint raises is part of the frontend contract, and it is
     *      not obvious: the failure happens inside a0G, reached through `SafeERC20`. OZ 5.3
     *      bubbles the original revert data rather than wrapping it, so the caller sees a0G's
     *      own `ERC20InsufficientBalance` -- the same selector a short iAI balance produces on
     *      the burn side, from a different contract. Asserted rather than assumed.
     */
    function test_Mint_UnderfundedRaisesTheCollateralTokensOwnError() public {
        (, uint256 needs) = vault.quoteMint(1e18);

        a0g.mint(alice, needs - 1);
        vm.prank(alice);
        a0g.approve(address(vault), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", alice, needs - 1, needs
            )
        );
        vm.prank(alice);
        vault.mint(1e18, type(uint256).max, block.timestamp);
    }

    /// @dev And a missing approval raises a0G's allowance error, not a vault error.
    function test_Mint_WithoutApprovalRaisesTheAllowanceError() public {
        (, uint256 needs) = vault.quoteMint(1e18);
        a0g.mint(alice, needs);

        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", address(vault), 0, needs
            )
        );
        vm.prank(alice);
        vault.mint(1e18, type(uint256).max, block.timestamp);
    }

    /// @dev A quote is a read, not a promise: it moves as soon as anyone else mints.
    function test_QuoteMintForA0G_FallsAsTheCurveRises() public {
        uint256 x = 100_000e18;
        uint256 before = vault.quoteMintForA0G(x);

        _mintFor(bob, 2_000e18);

        assertLt(vault.quoteMintForA0G(x), before, "the same a0G buys less further up the curve");
    }
}
