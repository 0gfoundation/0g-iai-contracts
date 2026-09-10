// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {MockA0G} from "../../../src/mocks/MockA0G.sol";
import {MockW0G} from "../../../src/mocks/MockW0G.sol";
import {MockA0GOracle} from "../../../src/mocks/MockA0GOracle.sol";

/**
 * @title MockA0GTest
 * @notice The stand-in collateral's ERC-4626 face, which exists so the wrapping hop can be
 *         exercised somewhere other than mainnet.
 *
 * @dev The property worth protecting is that the **oracle** sets the share price, not the
 *      balance held. That is what the real token does — `SourceCore.totalAssets()` is
 *      `totalSupply() * oracle.getValue() / 1e18` — and it is why the three figures below are
 *      the same number on mainnet:
 *
 *          oracle.getValue() == convertToAssets(1e18) == totalAssets() / totalSupply()
 *
 *      A mock that priced shares off its own balance would break that, and a frontend sizing
 *      a deposit from `previewDeposit` would get an amount the vault then values differently.
 */
contract MockA0GTest is Test {
    uint256 internal constant WAD = 1e18;
    /// @dev The a0G rate observed on 0G mainnet, so the fixture starts from a real number.
    uint256 internal constant ER0 = 1_108_109_704_765_932_179;

    MockW0G internal w0g;
    MockA0GOracle internal oracle;
    MockA0G internal a0g;

    address internal alice = makeAddr("alice");

    function setUp() public {
        w0g = new MockW0G();
        oracle = new MockA0GOracle(ER0, 0.15e18, 21 days, address(this));
        a0g = new MockA0G(address(w0g), address(oracle));

        // Seed supply before anything is priced. ERC-4626's virtual share makes an empty
        // vault quote 1:1 whatever the oracle says, and the real token behaves the same way
        // for the same reason -- so the interesting assertions belong to a vault that has a
        // supply, which on a testnet it does from the moment the accounts are funded.
        // `test_AnEmptyVaultQuotesOneForOne` covers the other case deliberately.
        a0g.faucetMint(makeAddr("existing cohort"), 5_000_000e18);

        w0g.mint(alice, 1_000e18);
        vm.prank(alice);
        w0g.approve(address(a0g), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // The vault face
    // -------------------------------------------------------------------------

    function test_Metadata() public view {
        assertEq(a0g.name(), "Mock Ascend Staked 0G");
        assertEq(a0g.symbol(), "a0G");
        assertEq(a0g.decimals(), 18);
        assertEq(a0g.asset(), address(w0g), "the underlying is what it was built over");
        assertEq(address(a0g.oracle()), address(oracle));
    }

    /// @dev The identity that holds on mainnet, and the reason the price is not derived from
    ///      the balance held. One wei of slack for ERC-4626's virtual share.
    function test_ShareValueIsTheOracleValue() public view {
        assertApproxEqAbs(a0g.convertToAssets(WAD), oracle.getValue(), 1);
        assertApproxEqAbs(
            (a0g.totalAssets() * WAD) / a0g.totalSupply(), oracle.getValue(), 1, "and in aggregate"
        );
    }

    /**
     * @dev The one place the oracle does not set the price. ERC-4626 values the first deposit
     *      against a virtual share, so an empty vault quotes one for one however the oracle is
     *      set. Inherited, not chosen: the real token takes the same base contract with the
     *      same zero decimals offset, so it did this at its own genesis too.
     *
     *      It is reachable here only between deploying the mock and funding the test accounts,
     *      because funding mints supply. Pinned so it is a known property rather than a
     *      surprise for whoever deposits first.
     */
    function test_AnEmptyVaultQuotesOneForOne() public {
        MockA0G empty = new MockA0G(address(w0g), address(oracle));

        assertEq(empty.totalSupply(), 0);
        assertEq(empty.previewDeposit(100e18), 100e18, "one for one, not the oracle rate");
        assertGt(oracle.getValue(), WAD, "even though the rate is well above parity");
    }

    function test_TotalAssetsIsDerivedFromSupply() public {
        a0g.faucetMint(alice, 400e18);

        assertEq(a0g.totalAssets(), (a0g.totalSupply() * oracle.getValue()) / WAD);
        assertApproxEqAbs(
            (a0g.totalAssets() * WAD) / a0g.totalSupply(), oracle.getValue(), 1, "and equals the rate"
        );
    }

    /**
     * @dev The faucet mints shares nothing was paid for, so the contract holds far less than
     *      `totalAssets()` reports. That is not a defect to be fixed: the real token computes
     *      `totalAssets` the same way, from supply and the oracle, so the two stay consistent
     *      with each other whatever the balance is.
     */
    function test_UnbackedFaucetMintLeavesTheAccountingSelfConsistent() public {
        a0g.faucetMint(alice, 400e18);

        assertEq(w0g.balanceOf(address(a0g)), 0, "nothing was ever deposited");
        assertGt(a0g.totalAssets(), 0, "yet the vault accounts for the supply");
        assertApproxEqAbs(a0g.convertToAssets(WAD), oracle.getValue(), 1, "price still the rate");
    }

    // -------------------------------------------------------------------------
    // Depositing
    // -------------------------------------------------------------------------

    function test_Deposit_TakesTheAssetAndMintsAtTheOracleRate() public {
        uint256 assets = 100e18;
        uint256 expected = a0g.previewDeposit(assets);
        assertApproxEqAbs(expected, (assets * WAD) / oracle.getValue(), 1, "priced by the oracle");

        vm.prank(alice);
        uint256 shares = a0g.deposit(assets, alice);

        assertEq(shares, expected, "deposit honoured its own preview");
        assertEq(a0g.balanceOf(alice), shares);
        assertEq(w0g.balanceOf(alice), 900e18, "the asset really left the depositor");
        assertEq(w0g.balanceOf(address(a0g)), assets, "and arrived at the vault");
        assertLe(a0g.convertToAssets(shares), assets, "rounding never favours the depositor");
    }

    function test_Deposit_CreditsTheNamedReceiver() public {
        address bob = makeAddr("bob");
        vm.prank(alice);
        uint256 shares = a0g.deposit(10e18, bob);

        assertEq(a0g.balanceOf(bob), shares);
        assertEq(a0g.balanceOf(alice), 0);
    }

    function test_Deposit_EmitsTheStandardEvent() public {
        uint256 assets = 10e18;
        uint256 shares = a0g.previewDeposit(assets);

        vm.expectEmit(true, true, true, true, address(a0g));
        emit Deposit(alice, alice, assets, shares);
        vm.prank(alice);
        a0g.deposit(assets, alice);
    }

    /// @dev The whole point of exercising this on a testnet: the approve has to be real, so a
    ///      missing one has to fail the same way it would on mainnet.
    function test_Deposit_RequiresAnApproval() public {
        address bob = makeAddr("bob");
        w0g.mint(bob, 10e18);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(a0g), 0, 10e18)
        );
        vm.prank(bob);
        a0g.deposit(10e18, bob);
    }

    /// @dev a0G appreciates, so the same asset buys steadily fewer shares.
    function test_Deposit_BuysFewerSharesAsTheRateRises() public {
        uint256 before_ = a0g.previewDeposit(100e18);

        vm.warp(block.timestamp + 365 days);

        assertGt(oracle.getValue(), ER0, "the rate moved");
        assertLt(a0g.previewDeposit(100e18), before_, "so the same 100 W0G buys less");
    }

    function test_MaxDeposit_IsUnbounded() public view {
        assertEq(a0g.maxDeposit(alice), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Redemption is not modelled
    // -------------------------------------------------------------------------

    /**
     * @dev The real token reverts on both of these too — redemption there goes through
     *      `requestWithdrawal` and an epoch queue, which iAI never touches and this does not
     *      reproduce. The revert means "not modelled here", not "a0G cannot be redeemed".
     */
    function test_WithdrawAndRedeemRevert() public {
        vm.prank(alice);
        a0g.deposit(10e18, alice);

        vm.expectRevert(bytes("MockA0G: withdrawal queue not modelled"));
        vm.prank(alice);
        a0g.withdraw(1e18, alice, alice);

        vm.expectRevert(bytes("MockA0G: withdrawal queue not modelled"));
        vm.prank(alice);
        a0g.redeem(1e18, alice, alice);
    }

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
}
