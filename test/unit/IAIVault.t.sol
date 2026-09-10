// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "../Base.t.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {IIAIVault} from "../../src/interfaces/IIAIVault.sol";
import {IIAI} from "../../src/interfaces/IIAI.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {LinearMintCurve} from "../../src/curves/LinearMintCurve.sol";

contract IAIVaultTest is BaseTest {
    // -------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------

    function test_Initialize_WiresTheCurveAndTheCap() public view {
        // Pricing lives in the curve now; the vault only records which one is in force.
        assertEq(address(vault.curve()), address(mintCurve), "the vault points at the deployed curve");
        assertEq(mintCurve.slope(), SLOPE, "slope must be derived, never supplied");
        assertEq(mintCurve.r0(), R0);
        assertEq(mintCurve.target(), TARGET);
        assertEq(vault.cap(), CAP, "the cap is the vault's own, and adjustable");
        assertEq(vault.remainingCap(), CAP, "nothing minted yet");
        assertEq(address(vault.oracle()), address(oracle), "oracle cached from a0G");
        assertEq(vault.foundation(), foundation);
    }

    /// @dev The implementation sits behind a beacon, which does not protect it. Anyone
    ///      could otherwise initialize it and become its admin.
    function test_Initialize_ImplementationIsLocked() public {
        IAIVault impl = new IAIVault();
        vm.expectRevert(); // InvalidInitialization
        impl.initialize(_params(address(iai), address(a0g), foundation));
    }

    /// @dev Issuance opens on an explicit governance transaction; that is the whole launch
    ///      control. Redemption is unaffected by it.
    function test_Initialize_StartsPausedSoMintIsClosed() public {
        IAIVault fresh = _newVault(_params(address(iai), address(a0g), foundation));
        assertTrue(fresh.paused(), "a freshly deployed vault must not accept mints");
    }

    function test_Initialize_RejectsZeroAddresses() public {
        // The beacon must exist before expectRevert, otherwise the cheatcode latches onto
        // the beacon's own construction instead of the proxy's initializer call.
        address beacon = address(new UpgradeableBeacon(address(new IAIVault()), admin));

        vm.expectRevert(IIAIVault.ZeroAddress.selector);
        new BeaconProxy(beacon, abi.encodeCall(IAIVault.initialize, (_params(address(0), address(a0g), foundation))));

        vm.expectRevert(IIAIVault.ZeroAddress.selector);
        new BeaconProxy(beacon, abi.encodeCall(IAIVault.initialize, (_params(address(iai), address(0), foundation))));

        vm.expectRevert(IIAIVault.ZeroAddress.selector);
        new BeaconProxy(beacon, abi.encodeCall(IAIVault.initialize, (_params(address(iai), address(a0g), address(0)))));
    }

    function _params(address iai_, address a0G_, address foundation_)
        private
        view
        returns (IIAIVault.InitParams memory)
    {
        return IIAIVault.InitParams({
            iai: iai_,
            a0G: a0G_,
            foundation: foundation_,
            curve: address(mintCurve),
            cap: CAP
        });
    }

    function _newVault(IIAIVault.InitParams memory p) private returns (IAIVault) {
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(new IAIVault()), admin);
        return IAIVault(address(new BeaconProxy(address(beacon), abi.encodeCall(IAIVault.initialize, (p)))));
    }

    // -------------------------------------------------------------------------
    // Mint
    // -------------------------------------------------------------------------

    function test_Mint_FirstMintMatchesGoldenValues() public {
        uint256 d = 1e18;
        (uint256 delta0G, uint256 a0GIn) = vault.quoteMint(d);
        assertEq(delta0G, 4_331_010_799_123_502_174_371, "curve cost of the first iAI");
        assertEq(a0GIn, 3_908_467_528_527_194_563_487, "a0G at the mainnet starting rate");

        _mintFor(alice, d);

        assertEq(iai.balanceOf(alice), d, "iAI issued");
        assertEq(vault.supply(), d, "vault supply counter");
        assertEq(iai.totalSupply(), d, "token supply agrees");
        assertEq(vault.totalLocked0G(), delta0G, "collateral recorded in 0G value");
        assertEq(a0g.balanceOf(address(vault)), a0GIn, "collateral escrowed");

        (uint256 locked, uint256 outstanding, uint256 avgRate) = vault.positionOf(alice);
        assertEq(locked, delta0G);
        assertEq(outstanding, d);
        assertEq(avgRate, delta0G, "average entry rate for a single 1-iAI mint");
    }

    function test_Mint_RecordsCurveValueNotA0GAmount() public {
        // The position must be denominated in 0G value. Recording the a0G amount instead
        // would make a position's worth depend on the rate at the moment it was opened.
        uint256 d = 10e18;
        (uint256 delta0G, uint256 a0GIn) = vault.quoteMint(d);
        _mintFor(alice, d);
        (uint256 locked,,) = vault.positionOf(alice);
        assertEq(locked, delta0G);
        assertTrue(locked != a0GIn, "the two must not be conflated");
    }

    function test_Mint_SecondMintPaysHigherCurve() public {
        (uint256 firstDelta,) = vault.quoteMint(1e18);
        _mintFor(alice, 1_000e18);
        (uint256 laterDelta,) = vault.quoteMint(1e18);
        assertGt(laterDelta, firstDelta, "the marginal price must rise with supply");
    }

    function test_Mint_AccumulatesIntoWeightedAverage() public {
        _mintFor(alice, 100e18);
        (uint256 l1, uint256 o1, uint256 avg1) = vault.positionOf(alice);
        _mintFor(alice, 100e18);
        (uint256 l2, uint256 o2, uint256 avg2) = vault.positionOf(alice);

        assertEq(o2, o1 + 100e18);
        assertGt(l2, l1);
        assertGt(avg2, avg1, "second tranche is dearer, so the average rises");
        assertEq(avg2, (l2 * WAD) / o2, "average is derived, not stored");
    }

    function test_Mint_RevertsPastCap() public {
        vm.expectRevert(abi.encodeWithSelector(IIAIVault.CapExceeded.selector, CAP + 1, CAP));
        vm.prank(alice);
        vault.mint(CAP + 1, type(uint256).max, block.timestamp);
    }

    function test_Mint_RevertsOnZero() public {
        vm.expectRevert(IIAIVault.ZeroAmount.selector);
        vm.prank(alice);
        vault.mint(0, type(uint256).max, block.timestamp);
    }

    function test_Mint_RevertsPastDeadline() public {
        vm.warp(1_000);
        vm.expectRevert(abi.encodeWithSelector(IIAIVault.Expired.selector, 999, 1_000));
        vm.prank(alice);
        vault.mint(1e18, type(uint256).max, 999);
    }

    /// @dev One bound, both risks. `maxA0GIn` is what leaves the caller's wallet, so a
    ///      curve move and a rate move are visible through it alike.
    function test_Mint_SlippageBoundCatchesAFrontRunningMint() public {
        uint256 d = 1e18;
        (, uint256 quoted) = vault.quoteMint(d);
        _fund(alice, d);

        // Someone mints first and pushes the curve up under alice.
        _mintFor(bob, 50e18);

        (, uint256 nowCosts) = vault.quoteMint(d);
        assertGt(nowCosts, quoted, "the curve did move");

        a0g.faucetMint(alice, nowCosts);
        vm.prank(alice);
        a0g.approve(address(vault), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IIAIVault.ExcessiveInput.selector, nowCosts, quoted));
        vm.prank(alice);
        vault.mint(d, quoted, block.timestamp);

        // The exact bound is accepted.
        vm.prank(alice);
        vault.mint(d, nowCosts, block.timestamp);
        assertEq(iai.balanceOf(alice), d);
    }

    /// @dev A rate move shows up through the same bound.
    function test_Mint_SlippageBoundCatchesARateMove() public {
        uint256 d = 1e18;
        (, uint256 quoted) = vault.quoteMint(d);
        _fund(alice, d);

        // A falling rate is the adverse direction for a minter: the same 0G costs more a0G.
        oracle.setValue(ER0 * 9 / 10);

        (, uint256 nowCosts) = vault.quoteMint(d);
        assertGt(nowCosts, quoted, "the rate move raised the cost");

        a0g.faucetMint(alice, nowCosts);
        vm.expectRevert(abi.encodeWithSelector(IIAIVault.ExcessiveInput.selector, nowCosts, quoted));
        vm.prank(alice);
        vault.mint(d, quoted, block.timestamp);
    }

    function test_Mint_TakesNoMoreThanQuoted() public {
        uint256 d = 5e18;
        (, uint256 a0GIn) = vault.quoteMint(d);
        a0g.faucetMint(alice, a0GIn * 2);
        vm.prank(alice);
        a0g.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.mint(d, type(uint256).max, block.timestamp);
        assertEq(a0g.balanceOf(alice), a0GIn, "must not take more than the quote");
    }

    // -------------------------------------------------------------------------
    // Minting while issuance is paused
    // -------------------------------------------------------------------------

    /// @dev The role's whole purpose: one address gets through the pause. Note the vault is
    ///      still paused afterwards -- the exemption is not an unpause.
    function test_Mint_SucceedsWhilePausedForAnExemptHolder() public {
        bytes32 exemption = vault.PAUSE_EXEMPT_MINTER_ROLE();
        vault.grantRole(exemption, carol);
        vm.prank(guardian);
        vault.pause();

        uint256 d = 10e18;
        _mintFor(carol, d);

        assertTrue(vault.paused(), "the exemption is not an unpause");
        assertEq(iai.balanceOf(carol), d, "the iAI went to the caller");
        (, uint256 outstanding,) = vault.positionOf(carol);
        assertEq(outstanding, d, "and so did the position");
    }

    /// @dev Granting it to one address must not open issuance for anyone else. Alice is funded
    ///      and approved first, so what stops her is the pause gate and not a missing
    ///      allowance.
    function test_Mint_StillRevertsWhilePausedForEveryoneElse() public {
        bytes32 exemption = vault.PAUSE_EXEMPT_MINTER_ROLE();
        vault.grantRole(exemption, carol);
        uint256 d = 10e18;
        _fund(alice, d);
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(alice);
        vault.mint(d, type(uint256).max, block.timestamp);
    }

    /// @dev An exempt mint runs the same code as any other, so a quote taken while paused must
    ///      hold to the wei. `quoteMint` is not pause-gated, which is what makes this
    ///      checkable from inside the paused state rather than by comparison with a second
    ///      run.
    function test_Mint_ExemptMintIsPricedAndAccountedIdenticallyWhilePaused() public {
        bytes32 exemption = vault.PAUSE_EXEMPT_MINTER_ROLE();
        vault.grantRole(exemption, carol);
        vm.prank(guardian);
        vault.pause();

        uint256 d = 250e18;
        (uint256 expected0G, uint256 expectedA0G) = vault.quoteMint(d);
        _fund(carol, d);
        uint256 heldBefore = a0g.balanceOf(carol);

        vm.prank(carol);
        vault.mint(d, type(uint256).max, block.timestamp);

        assertEq(heldBefore - a0g.balanceOf(carol), expectedA0G, "took exactly the quoted collateral");
        (uint256 locked, uint256 outstanding,) = vault.positionOf(carol);
        assertEq(locked, expected0G, "recorded the curve's 0G value, not the a0G amount");
        assertEq(outstanding, d);
        assertEq(vault.totalLocked0G(), expected0G, "the aggregate moved by the same amount");
        assertEq(vault.supply(), d);
        _assertSolvent();
    }

    /// @dev The exemption is not a cap bypass. The ceiling check sits inside `mint`'s body,
    ///      below the gate, so `setCap(0)` is the one switch that closes issuance to everyone.
    function test_Mint_ExemptHolderIsStillBoundByTheCapWhilePaused() public {
        bytes32 exemption = vault.PAUSE_EXEMPT_MINTER_ROLE();
        vault.grantRole(exemption, carol);
        uint256 d = 10e18;
        // Funded before the cap moves: quoting past the ceiling reverts, and the point here is
        // the mint's own guard.
        _fund(carol, d);
        vault.setCap(0);
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert(abi.encodeWithSelector(IIAIVault.CapExceeded.selector, d, 0));
        vm.prank(carol);
        vault.mint(d, type(uint256).max, block.timestamp);
    }

    /// @dev Nor a bypass of the caller's own bounds. Both guards live below the gate.
    function test_Mint_ExemptHolderStillObeysSlippageAndDeadlineWhilePaused() public {
        bytes32 exemption = vault.PAUSE_EXEMPT_MINTER_ROLE();
        vault.grantRole(exemption, carol);
        uint256 d = 10e18;
        uint256 a0GIn = _fund(carol, d);
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert(abi.encodeWithSelector(IIAIVault.ExcessiveInput.selector, a0GIn, a0GIn - 1));
        vm.prank(carol);
        vault.mint(d, a0GIn - 1, block.timestamp);

        vm.warp(block.timestamp + 1);
        uint256 past = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(IIAIVault.Expired.selector, past, block.timestamp));
        vm.prank(carol);
        vault.mint(d, type(uint256).max, past);
    }

    /// @dev A deployment must not ship with anybody able to mint through the pause it comes up
    ///      in. `initialize` grants `DEFAULT_ADMIN_ROLE` and nothing else, so the exemption
    ///      opens only on a later, explicit grant.
    function test_Mint_NobodyIsExemptOnAFreshlyDeployedVault() public {
        IAIVault fresh = _newVault(_params(address(iai), address(a0g), foundation));
        bytes32 exemption = fresh.PAUSE_EXEMPT_MINTER_ROLE();

        assertTrue(fresh.paused(), "and it deploys paused");
        assertFalse(fresh.hasRole(exemption, admin), "not even the account that deployed it");
        assertFalse(fresh.hasRole(exemption, alice));
    }

    // -------------------------------------------------------------------------
    // Burn
    // -------------------------------------------------------------------------

    function test_Burn_FullRedemptionClearsPositionExactly() public {
        uint256 d = 100e18;
        uint256 a0GIn = _mintFor(alice, d);

        _burnFor(alice, d);

        (uint256 locked, uint256 outstanding,) = vault.positionOf(alice);
        assertEq(locked, 0, "no stranded principal");
        assertEq(outstanding, 0, "no stranded obligation");
        assertEq(vault.totalLocked0G(), 0);
        assertEq(vault.supply(), 0);
        assertEq(iai.totalSupply(), 0);
        // A round trip costs only the rounding on the way in.
        assertEq(a0g.balanceOf(alice), a0GIn - 1, "round trip loses one wei to rounding");
    }

    function test_Burn_PartialRedemptionsAlwaysClearToZero() public {
        uint256 d = 270e18;
        _mintFor(alice, d);

        uint256[4] memory chunks = [uint256(1), 13e18, 100e18, d - 1 - 13e18 - 100e18];
        for (uint256 i = 0; i < chunks.length; i++) {
            _burnFor(alice, chunks[i]);
        }

        (uint256 locked, uint256 outstanding,) = vault.positionOf(alice);
        assertEq(outstanding, 0, "all obligation retired");
        assertEq(locked, 0, "all principal released, none stranded");
    }

    function test_Burn_RevertsForNonMinter() public {
        _mintFor(alice, 10e18);
        vm.prank(alice);
        iai.transfer(bob, 10e18);

        // Bob holds the tokens but owns no position: the compute right is bearer, the
        // collateral claim is not.
        vm.expectRevert(abi.encodeWithSelector(IIAIVault.BurnExceedsPosition.selector, 10e18, 0));
        vm.prank(bob);
        vault.burn(10e18, block.timestamp);
    }

    function test_Burn_RevertsBeyondOutstanding() public {
        _mintFor(alice, 10e18);
        vm.expectRevert(abi.encodeWithSelector(IIAIVault.BurnExceedsPosition.selector, 10e18 + 1, 10e18));
        vm.prank(alice);
        vault.burn(10e18 + 1, block.timestamp);
    }

    /**
     * @dev Redemption takes no minimum-output bound. This pins the reason: what a redeemer
     *      gets back is fixed in 0G, and the a0G it converts to only shrinks as a0G
     *      appreciates. There is no adverse surprise for a bound to catch -- delay is the
     *      only thing that costs the redeemer, and `deadline` already limits that.
     */
    function test_Burn_PaysAFixed0GValueThatBuysLessA0GOverTime() public {
        _mintFor(alice, 10e18);
        (uint256 unlockedNow, uint256 a0GNow) = vault.quoteBurn(alice, 10e18);

        vm.warp(block.timestamp + 180 days);

        (uint256 unlockedLater, uint256 a0GLater) = vault.quoteBurn(alice, 10e18);
        assertEq(unlockedLater, unlockedNow, "the 0G owed does not move");
        assertLt(a0GLater, a0GNow, "the same 0G buys less a0G once a0G has appreciated");

        vm.prank(alice);
        vault.burn(10e18, block.timestamp);
        assertEq(a0g.balanceOf(alice), a0GLater);
    }

    /// @dev The redemption path must not be reachable by the pause switch. This encodes
    ///      that promise as an executable property rather than a comment.
    function test_Burn_SucceedsWhilePaused() public {
        _mintFor(alice, 10e18);
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(alice);
        vault.mint(1e18, type(uint256).max, block.timestamp);

        _burnFor(alice, 10e18);
        assertEq(vault.supply(), 0, "redemption works while paused");
    }

    function test_Burn_DoesNotRequireApproval() public {
        // The vault holds the burner role and burns from the caller directly. A frontend
        // that inserts an approve step here is wrong, so pin the behaviour.
        _mintFor(alice, 10e18);
        assertEq(iai.allowance(alice, address(vault)), 0, "no allowance granted anywhere");
        _burnFor(alice, 10e18);
        assertEq(iai.balanceOf(alice), 0);
    }

    // -------------------------------------------------------------------------
    // burnFor
    // -------------------------------------------------------------------------

    function test_BurnFor_SendsCollateralToMinterNotCaller() public {
        uint256 d = 10e18;
        _mintFor(alice, d);
        // Alice sends her tokens away; without a rescue path her collateral is stranded.
        vm.prank(alice);
        iai.transfer(rescuer, d);

        uint256 aliceBefore = a0g.balanceOf(alice);
        uint256 rescuerBefore = a0g.balanceOf(rescuer);
        (, uint256 expectedOut) = vault.quoteBurn(alice, d);

        vm.prank(rescuer);
        vault.burnFor(alice, d, block.timestamp);

        assertEq(a0g.balanceOf(alice) - aliceBefore, expectedOut, "collateral returns to the minter");
        assertEq(a0g.balanceOf(rescuer), rescuerBefore, "the caller receives nothing");
        assertEq(iai.balanceOf(rescuer), 0, "the caller supplied the tokens");
        (uint256 locked, uint256 outstanding,) = vault.positionOf(alice);
        assertEq(locked, 0);
        assertEq(outstanding, 0);
    }

    function test_BurnFor_RequiresRole() public {
        _mintFor(alice, 10e18);
        vm.prank(alice);
        iai.transfer(bob, 10e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, vault.RESCUE_ROLE()
            )
        );
        vm.prank(bob);
        vault.burnFor(alice, 10e18, block.timestamp);
    }

    // -------------------------------------------------------------------------
    // Harvest
    // -------------------------------------------------------------------------

    function test_Harvest_MovesOnlyAppreciationAndLeavesPositionsUntouched() public {
        uint256 d = 1e18;
        _mintFor(alice, d);
        (uint256 lockedBefore,,) = vault.positionOf(alice);

        vm.warp(block.timestamp + 365 days);

        uint256 pending = vault.pendingSurplus();
        assertGt(pending, 0, "a year of accrual must show up");

        uint256 got = vault.harvest();
        assertEq(got, pending);
        assertEq(a0g.balanceOf(foundation), pending, "surplus goes to the foundation");

        (uint256 lockedAfter,,) = vault.positionOf(alice);
        assertEq(lockedAfter, lockedBefore, "principal is denominated in 0G and does not move");
        _assertSolvent();
    }

    function test_Harvest_IsNoOpWhenNothingAccrued() public {
        _mintFor(alice, 1e18);
        assertEq(vault.harvest(), 0, "nothing to sweep immediately after minting");
    }

    function test_Harvest_LeavesEnoughToCoverEveryRedemption() public {
        _mintFor(alice, 100e18);
        _mintFor(bob, 100e18);
        vm.warp(block.timestamp + 200 days);
        vault.harvest();
        _assertSolvent();

        // Both minters must still be able to exit in full after the sweep.
        _burnFor(alice, 100e18);
        _burnFor(bob, 100e18);
        assertEq(vault.totalLocked0G(), 0);
    }

    /// @dev A user who redeems after appreciation receives fewer a0G than they deposited,
    ///      while their 0G value is untouched. This is the single hardest thing to
    ///      communicate, so it is pinned here as an executable statement of the property.
    function test_Redemption_ReturnsFewerTokensButTheSame0GValue() public {
        uint256 d = 1e18;
        uint256 a0GIn = _mintFor(alice, d);
        (uint256 locked0G,,) = vault.positionOf(alice);

        vm.warp(block.timestamp + 365 days);
        vault.harvest();

        (, uint256 a0GOut) = vault.quoteBurn(alice, d);
        assertLt(a0GOut, a0GIn, "fewer tokens come back");

        uint256 valueOut = (a0GOut * vault.exchangeRate()) / WAD;
        assertApproxEqAbs(valueOut, locked0G, 1e6, "but the same 0G value, to rounding dust");
    }

    /**
     * @notice Documents, as an executable fact, what a falling exchange rate actually does.
     *
     * @dev The rate is expected to rise monotonically and the design accepts that a fall is
     *      not defended against, so this test exists to make the consequence visible rather
     *      than to assert it away. Two things hold and one does not:
     *
     *      - the sweep goes to zero instead of underflowing;
     *      - holders can still exit while the vault has cover;
     *      - **once the cover runs out, later redemptions revert.** There is no pro-rata
     *        haircut: it is first come, first served. Anyone reconsidering that trade-off
     *        should start here.
     */
    function test_RateFall_SweepGoesQuietButLateRedeemersAreLeftShort() public {
        _mintFor(alice, 100e18);
        _mintFor(bob, 100e18);
        vm.warp(block.timestamp + 100 days);
        vault.harvest(); // sweeps the vault down to exactly what it owes

        oracle.setValue((vault.exchangeRate() * 90) / 100);

        // The sweep degrades quietly.
        assertEq(vault.pendingSurplus(), 0, "nothing to sweep when under water");
        assertEq(vault.harvest(), 0, "must return zero, not revert");

        // Alice is early enough to be paid in full.
        _burnFor(alice, 100e18);
        (, uint256 aliceOutstanding,) = vault.positionOf(alice);
        assertEq(aliceOutstanding, 0, "the first redeemer is made whole");

        // Bob is not. The shortfall lands entirely on whoever is last.
        (, uint256 bobOwed) = vault.quoteBurn(bob, 100e18);
        assertGt(bobOwed, a0g.balanceOf(address(vault)), "vault can no longer cover the rest");
        vm.expectRevert(); // ERC20InsufficientBalance
        vm.prank(bob);
        vault.burn(100e18, block.timestamp);
    }

    // -------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------

    function test_Pause_OnlyPauser() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.PAUSER_ROLE()
            )
        );
        vm.prank(alice);
        vault.pause();
    }

    /// @dev A grant is meant to be temporary, so the revoke is the half worth pinning: it has
    ///      to close issuance again for the same address, from the same paused state.
    function test_PausedMintExemption_GrantAndRevokeRoundTripClosesIssuanceAgain() public {
        bytes32 exemption = vault.PAUSE_EXEMPT_MINTER_ROLE();
        uint256 d = 10e18;
        vm.prank(guardian);
        vault.pause();

        _fund(carol, d);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(carol);
        vault.mint(d, type(uint256).max, block.timestamp);

        vault.grantRole(exemption, carol);
        vm.prank(carol);
        vault.mint(d, type(uint256).max, block.timestamp);
        assertEq(vault.supply(), d, "open for that address");

        vault.revokeRole(exemption, carol);
        _fund(carol, d);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(carol);
        vault.mint(d, type(uint256).max, block.timestamp);
    }

    /// @dev Only admin opens it. The pauser especially must not: it closes issuance, and being
    ///      able to grant a way around its own switch would make that switch meaningless.
    function test_PausedMintExemption_OnlyAdminCanGrantIt() public {
        bytes32 exemption = vault.PAUSE_EXEMPT_MINTER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0)
            )
        );
        vm.prank(alice);
        vault.grantRole(exemption, alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, bytes32(0)
            )
        );
        vm.prank(guardian);
        vault.grantRole(exemption, guardian);

        vault.grantRole(exemption, carol);
        assertTrue(vault.hasRole(exemption, carol));
    }

    /// @dev The exemption covers `mint` and nothing else. Harvesting stays closed to a holder,
    ///      which is the scope decision made executable.
    function test_Harvest_StillRevertsWhilePausedForAnExemptHolder() public {
        bytes32 exemption = vault.PAUSE_EXEMPT_MINTER_ROLE();
        vault.grantRole(exemption, carol);
        _mintFor(alice, 100e18);
        vm.warp(block.timestamp + 30 days);
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(carol);
        vault.harvest();
    }

    function test_SetFoundation_OnlyAdminAndNonZero() public {
        vm.expectRevert(IIAIVault.ZeroAddress.selector);
        vault.setFoundation(address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0)
            )
        );
        vm.prank(alice);
        vault.setFoundation(alice);

        vault.setFoundation(bob);
        assertEq(vault.foundation(), bob);
    }

    // -------------------------------------------------------------------------
    // Accounting invariants on a mixed sequence
    // -------------------------------------------------------------------------

    function test_Invariants_HoldAcrossMixedActivity() public {
        _mintFor(alice, 500e18);
        _mintFor(bob, 1_200e18);
        vm.warp(block.timestamp + 30 days);
        vault.harvest();
        _burnFor(alice, 200e18);
        _mintFor(carol, 300e18);
        vm.warp(block.timestamp + 100 days);
        _burnFor(bob, 1_200e18);
        vault.harvest();

        assertEq(_sumLocked(_actors()), vault.totalLocked0G(), "A: positions sum to the total");
        assertEq(vault.supply(), iai.totalSupply(), "D: supply counters agree");
        assertLe(vault.supply(), vault.cap(), "D: cap respected");
        _assertSolvent(); // C
    }

    /// @dev Redemption settles at the burner's own average, while the curve gives back the
    ///      top slice. The two differ, so the aggregate can only drift upward — the target
    ///      is not an upper bound on custody and nothing may assert that it is.
    function test_TotalLockedCanExceedTargetRatioAfterChurn() public {
        _mintFor(alice, 4_000e18);
        _mintFor(bob, 4_000e18);
        // Alice exits her cheap early slice; Carol buys the freed top slice at the margin.
        _burnFor(alice, 4_000e18);
        _mintFor(carol, 4_000e18);

        // Asked of the concrete curve, not of the vault: "what would this curve have locked"
        // is a question about one curve's shape, and the vault no longer answers it because
        // after a swap it would be a counterfactual about mints that curve never priced.
        assertGt(
            vault.totalLocked0G(),
            LinearMintCurve(address(vault.curve())).lockedAt(vault.supply()),
            "aggregate collateral ratchets above the curve after churn"
        );
    }
}
