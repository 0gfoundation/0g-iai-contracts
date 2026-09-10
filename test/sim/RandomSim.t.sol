// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "../Base.t.sol";
import {Prng} from "./Prng.sol";
import {ICreditRegistry} from "../../src/interfaces/ICreditRegistry.sol";
import {IIAIVault} from "../../src/interfaces/IIAIVault.sol";
import {IMintCurve} from "../../src/interfaces/IMintCurve.sol";
import {LinearMintCurve} from "../../src/curves/LinearMintCurve.sol";
import {ExponentialMintCurve} from "../../src/curves/ExponentialMintCurve.sol";

/**
 * @title RandomSimTest
 * @notice Drives the system through tens of thousands of randomly chosen operations against
 *         a shadow model maintained in the test, comparing every field after every step.
 *
 * @dev Three deliberate choices:
 *
 *      1. **The shadow recomputes the curve, but only partly independently.** It uses plain
 *         checked arithmetic with hand-written ceilings instead of the library's `Math.mulDiv`
 *         path, so it catches a rounding or overflow regression -- which is what the
 *         simulation is for. It does **not** catch an algebraic one: it evaluates the same
 *         expansion the contract does, `R0*d + slope*d*(2s+d)/2`, rather than the equivalent
 *         `lockedAt(s+d) - lockedAt(s)`. The algebra is pinned elsewhere, by golden vectors
 *         computed outside this codebase and asserted in `test/unit/curves/LinearCurveMath.t.sol`. Stating
 *         this plainly because "independent shadow" would overclaim what these steps prove.
 *         The same holds for the step curve: the shadow walks the same buckets the contract
 *         does and takes one ceiling over the sum; that the *table* is the formula's is pinned
 *         by `test/unit/curves/ExponentialMintCurve.t.sol`. What the simulation adds is
 *         thousands of mints that straddle bucket boundaries from states no hand-written test
 *         reaches, priced against a table the shadow holds separately.
 *
 *      2. **State is compared after every operation, not at the end.** A mismatch then
 *         names the operation that caused it instead of the thousandth one after it.
 *
 *      3. **The exchange rate only ever rises**, matching how the real oracle behaves. The
 *         downward case is a documented, accepted risk and is covered by a dedicated test
 *         rather than smeared through the simulation, where it would mask real failures.
 */
contract RandomSimTest is BaseTest {
    using Prng for Prng.State;

    uint256 internal constant SEED = 0x1A1_5EED;
    uint256 internal constant ACTORS = 8;

    Prng.State internal rng;
    address[ACTORS] internal actors;

    // --- shadow model ---
    mapping(address => uint256) internal mLocked;
    mapping(address => uint256) internal mOutstanding;
    uint256 internal mTotalLocked;
    uint256 internal mSupply;

    mapping(address => uint256) internal mStaked;
    mapping(address => uint256) internal mCooling;
    mapping(address => uint256) internal mCoolEnd;
    uint256 internal mTotalStaked;

    uint256 internal mHarvested;
    bool internal mPaused;

    // The pricing surface and the ceiling, both adjustable by governance mid-run. Two shapes
    // of curve alternate; `mKind` says which set of shadow parameters is live.
    enum CurveKind {
        Linear,
        Step
    }

    CurveKind internal mKind;
    uint256 internal mR0;
    uint256 internal mSlope;
    uint256 internal mWidth;
    uint128[] internal mPrices;
    uint256 internal mCap;
    address internal mCurve;

    /// @dev The simulation's step tables are coarse and cover twice the production cap, so
    ///      `_opSetCap`'s range never meets the table's top and the two operations stay
    ///      independent. 38 buckets of 500 iAI reach 19,000 iAI.
    uint256 internal constant SIM_WIDTH = 500e18;
    uint256 internal constant SIM_BUCKETS = 38;

    // --- coverage counters, asserted at the end so a silently degenerate run is caught ---
    uint256 internal nMints;
    uint256 internal nBurns;
    uint256 internal nHarvests;
    uint256 internal nStakes;
    uint256 internal nUnstakes;
    uint256 internal nPauseToggles;
    uint256 internal nBurnsWhilePaused;
    uint256 internal nRejections;
    uint256 internal nCapChanges;
    uint256 internal nCurveSwaps;
    uint256 internal nStepSwaps;
    uint256 internal nStepMints;
    uint256 internal nMintsRejectedByCap;
    uint256 internal nBurnsInBurnOnlyMode;
    uint256 internal nHarvestsInBurnOnlyMode;

    function setUp() public override {
        super.setUp();
        rng.value = SEED;
        for (uint256 i = 0; i < ACTORS; i++) {
            address a = address(uint160(0xA11CE00 + i));
            actors[i] = a;
            vm.label(a, string.concat("actor", vm.toString(i)));
            vm.prank(a);
            a0g.approve(address(vault), type(uint256).max);
            vm.prank(a);
            iai.approve(address(registry), type(uint256).max);
        }

        mKind = CurveKind.Linear;
        mR0 = R0;
        mSlope = SLOPE;
        mCap = CAP;
        mCurve = address(vault.curve());
    }

    // -------------------------------------------------------------------------
    // Independent re-implementation of the curve, for the shadow model
    // -------------------------------------------------------------------------

    /// @dev Written without `Math.mulDiv` on purpose: hand-rolled ceilings over plain
    ///      checked arithmetic, so a rounding-direction change in the library shows up as
    ///      a disagreement rather than being silently mirrored. Takes the curve parameters
    ///      as arguments rather than reading the constants, because the curve in force
    ///      changes during the run.
    function _shadowCost(uint256 r0, uint256 slope, uint256 s, uint256 d)
        internal
        pure
        returns (uint256)
    {
        uint256 linear = (r0 * d + WAD - 1) / WAD;
        uint256 quadratic = (slope * (d * (2 * s + d)) + (2 * WAD * WAD) - 1) / (2 * WAD * WAD);
        return linear + quadratic;
    }

    /// @dev The step curve's price: the exact bucket sum, then a single hand-rolled ceiling.
    ///      One ceiling and not one per bucket, because that is the contract's stated rounding
    ///      and the property it buys -- monotonic in `s` at the wei -- would be lost otherwise.
    function _shadowStepCost(uint256 s, uint256 d) internal view returns (uint256) {
        uint256 num;
        uint256 cursor = s;
        uint256 end = s + d;
        while (cursor < end) {
            uint256 i = cursor / mWidth;
            uint256 upper = (i + 1) * mWidth;
            uint256 stop = end < upper ? end : upper;
            num += uint256(mPrices[i]) * (stop - cursor);
            cursor = stop;
        }
        return _shadowCeilDiv(num, WAD);
    }

    /// @dev The price the curve currently in force asks, whichever shape it is.
    function _shadowCost(uint256 s, uint256 d) internal view returns (uint256) {
        return mKind == CurveKind.Linear ? _shadowCost(mR0, mSlope, s, d) : _shadowStepCost(s, d);
    }

    /// @dev Re-derives the slope the way `LinearCurveMath` does, in plain checked arithmetic.
    ///      Floors, exactly as the library's `mulDiv` default does.
    function _shadowSlope(uint256 r0, uint256 anchorCap, uint256 target)
        internal
        pure
        returns (uint256)
    {
        uint256 flat = (r0 * anchorCap) / WAD;
        return (2 * (target - flat) * (WAD * WAD)) / (anchorCap * anchorCap);
    }

    function _shadowCeilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // -------------------------------------------------------------------------
    // The run
    // -------------------------------------------------------------------------

    function test_Sim_10k() public {
        _run(10_000);
    }

    /// @dev Long run, 100k operations. Gated on an env var so the default suite stays fast:
    ///      `SIM_LONG=1 forge test --match-test test_Sim_Long` (about 30s).
    function test_Sim_Long() public {
        if (vm.envOr("SIM_LONG", uint256(0)) == 0) return;
        _run(vm.envOr("SIM_OPS", uint256(100_000)));
    }

    function _run(uint256 ops) internal {
        for (uint256 i = 0; i < ops; i++) {
            _step();
            _assertState();
        }
        _assertCoverage();
    }

    function _step() internal {
        uint256 roll = rng.next() % 100;

        if (roll < 26) {
            _opMint();
        } else if (roll < 51) {
            _opBurn();
        } else if (roll < 58) {
            _opHarvest();
        } else if (roll < 66) {
            _opStake();
        } else if (roll < 73) {
            _opInitiateUnstake();
        } else if (roll < 78) {
            _opUnstake();
        } else if (roll < 83) {
            _opWarp();
        } else if (roll < 87) {
            _opTransfer();
        } else if (roll < 90) {
            _opTogglePause();
        } else if (roll < 93) {
            _opSetCap();
        } else if (roll < 95) {
            _opSetCurve();
        } else {
            _opRejection();
        }
    }

    function _actor() internal returns (address) {
        return actors[rng.next() % ACTORS];
    }

    // --- operations ---

    /**
     * @dev The amount is drawn without reference to the cap, so whether this mint is allowed
     *      is a question the shadow answers rather than one the sampler avoids. Both outcomes
     *      are asserted: a rejection has to come back as `CapExceeded` with the exact pair of
     *      numbers, from whatever state the run has reached. That is a stronger statement than
     *      the `supply <= cap` assertion it replaces, which could not survive a cap lowered
     *      below the live supply -- the very mode this simulation now spends time in.
     */
    function _opMint() internal {
        address a = _actor();
        uint256 d = rng.magnitude(1, 400e18);
        if (d == 0) return;

        uint256 supplyAfter = mSupply + d;
        bool overCap = supplyAfter > mCap;
        uint256 expectedDelta = overCap ? 0 : _shadowCost(mSupply, d);
        uint256 er = vault.exchangeRate();
        uint256 expectedIn = overCap ? type(uint256).max : _shadowCeilDiv(expectedDelta * WAD, er);

        if (mPaused) {
            // `whenIssuanceOpen` is a modifier, so it fires ahead of the body's own cap
            // check. No actor here holds `PAUSE_EXEMPT_MINTER_ROLE`, so it never lets one past.
            if (!overCap) a0g.faucetMint(a, expectedIn);
            vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
            vm.prank(a);
            vault.mint(d, expectedIn, block.timestamp);
            nRejections++;
            return;
        }

        if (overCap) {
            vm.expectRevert(abi.encodeWithSelector(IIAIVault.CapExceeded.selector, supplyAfter, mCap));
            vm.prank(a);
            vault.mint(d, expectedIn, block.timestamp);
            nMintsRejectedByCap++;
            nRejections++;
            return;
        }

        // Funded with exactly the shadow's price, so the balance must come back to where it
        // started: a wei more and the transfer fails, a wei less and this assertion does.
        uint256 heldBefore = a0g.balanceOf(a);
        a0g.faucetMint(a, expectedIn);
        vm.prank(a);
        vault.mint(d, expectedIn, block.timestamp);

        assertEq(a0g.balanceOf(a), heldBefore, "mint took exactly what the shadow priced");

        mLocked[a] += expectedDelta;
        mOutstanding[a] += d;
        mTotalLocked += expectedDelta;
        mSupply += d;
        nMints++;
        if (mKind == CurveKind.Step) nStepMints++;
    }

    function _opBurn() internal {
        address a = _pickWithPosition();
        if (a == address(0)) return;

        uint256 outstanding = mOutstanding[a];
        // Bias toward full exits so positions actually close and the clear-to-zero
        // property gets exercised, not just partial reductions.
        uint256 b = rng.chance(35) ? outstanding : rng.magnitude(1, outstanding);
        if (b == 0 || iai.balanceOf(a) < b) return;

        uint256 expectedUnlock = (mLocked[a] * b) / outstanding;
        // Redemption no longer takes a minimum-output bound, so the shadow checks the payout
        // instead of merely bounding it.
        uint256 expectedOut = (expectedUnlock * WAD) / vault.exchangeRate();
        uint256 heldBefore = a0g.balanceOf(a);

        vm.prank(a);
        vault.burn(b, block.timestamp);

        assertEq(a0g.balanceOf(a) - heldBefore, expectedOut, "burn payout matches the shadow");
        // The promise that redemption is never gated, held as a running property rather than
        // a single test: this line executes with the vault paused many times per run.
        if (mPaused) nBurnsWhilePaused++;
        // The same promise against the other issuance switch: a cap below the live supply
        // closes minting, and redemption has to stay open through it.
        if (mSupply > mCap) nBurnsInBurnOnlyMode++;

        mLocked[a] -= expectedUnlock;
        mOutstanding[a] -= b;
        mTotalLocked -= expectedUnlock;
        mSupply -= b;
        nBurns++;
    }

    /**
     * @notice Governance moves the ceiling, deliberately across the live supply.
     *
     * @dev Roughly two in five draws land below the current supply, which is the burn-only
     *      mode: `mint` refuses, everything else carries on. Sampling it this often is the
     *      point -- it is a state the system is expected to sit in during an emergency, so
     *      thousands of operations run from inside it rather than one test poking at it.
     *
     *      `setCap` deliberately has no `newCap >= supply` guard. Adding one would make the
     *      ceiling un-lowerable exactly when it needs lowering, so this operation exercises
     *      the case that guard would have blocked, zero included.
     */
    function _opSetCap() internal {
        uint256 newCap;
        if (rng.chance(40) && mSupply != 0) {
            newCap = rng.range(0, mSupply - 1); // below the live supply: burn-only
        } else {
            newCap = rng.range(mSupply, 2 * CAP);
        }

        vault.setCap(newCap);
        mCap = newCap;
        nCapChanges++;
    }

    /**
     * @notice Governance swaps the pricing surface, in both directions.
     *
     * @dev The swap is free to make the curve cheaper or dearer, because the invariant that
     *      would have forbidden one direction -- "the running total covers what the current
     *      curve says the supply is worth" -- is not a property of a system whose curve can
     *      change. It was never an accounting identity; it asserted that every wei in the
     *      total had been priced by the curve in force, which stops being true the moment a
     *      swap happens, with nobody having done anything. What actually matters survives
     *      untouched and is still checked after every step: positions sum to the total (A),
     *      the vault covers its obligations (C), and no position is half-cleared (F).
     *
     *      The shadow re-derives the slope rather than reading it back off the curve, so a
     *      regression in `deriveSlope` shows up here as well as in its golden vectors.
     *
     *      The two shapes alternate, so every swap also changes shape: a position priced by a
     *      table is then redeemed under a line and vice versa, thousands of times. The step
     *      table is random and monotone rather than the formula's -- the simulation checks the
     *      vault's and the curve's arithmetic, not the table's provenance -- and its prices
     *      sit in the production range so the amounts involved are realistic.
     */
    function _opSetCurve() internal {
        if (nCurveSwaps % 2 == 0) {
            uint256 r0 = rng.range(1e21, 20e21);
            // Keep the anchor fixed and vary the curvature: `extra` is the 0G the sloped part
            // accounts for on top of the flat part, and it is what fixes the slope.
            uint256 flat = (r0 * CAP) / WAD;
            uint256 extra = rng.range(1e25, 3e26);

            LinearMintCurve c = new LinearMintCurve(r0, CAP, flat + extra);
            uint256 slope = _shadowSlope(r0, CAP, flat + extra);
            assertEq(c.slope(), slope, "the shadow derives the same slope the library does");

            vault.setCurve(IMintCurve(address(c)));

            mKind = CurveKind.Linear;
            mR0 = r0;
            mSlope = slope;
            mCurve = address(c);
        } else {
            uint128[] memory p = new uint128[](SIM_BUCKETS);
            p[0] = uint128(rng.range(1e21, 20e21));
            for (uint256 i = 1; i < SIM_BUCKETS; i++) {
                // Zero is a legal increment: flat runs of equal buckets are part of the mix.
                p[i] = p[i - 1] + uint128(rng.range(0, 3e21));
            }

            ExponentialMintCurve c = new ExponentialMintCurve(SIM_WIDTH, p, p[0], 0, SIM_BUCKETS * SIM_WIDTH);
            assertEq(c.maxSafeSupply(), SIM_BUCKETS * SIM_WIDTH, "the table reaches past twice the cap");
            assertGe(c.maxSafeSupply(), 2 * CAP);

            vault.setCurve(IMintCurve(address(c)));

            mKind = CurveKind.Step;
            mWidth = SIM_WIDTH;
            mPrices = p;
            mCurve = address(c);
            nStepSwaps++;
        }
        nCurveSwaps++;
    }

    function _opHarvest() internal {
        if (mPaused) {
            vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
            vault.harvest();
            nRejections++;
            return;
        }

        uint256 held = a0g.balanceOf(address(vault));
        uint256 owed = _shadowCeilDiv(mTotalLocked * WAD, vault.exchangeRate());
        uint256 expected = held > owed ? held - owed : 0;

        uint256 got = vault.harvest();
        assertEq(got, expected, "harvest must sweep exactly the surplus");
        mHarvested += got;
        nHarvests++;
        // `harvest` is gated by `pause`, not by the cap. Lowering the cap to zero therefore
        // closes issuance while the sweep keeps running -- which is why the documented way
        // to wind the system down is `pause()`, not `setCap(0)`.
        if (mSupply > mCap) nHarvestsInBurnOnlyMode++;
    }

    function _opStake() internal {
        address a = _actor();
        uint256 bal = iai.balanceOf(a);
        if (bal == 0) return;
        uint256 amount = rng.magnitude(1, bal);
        if (amount == 0) return;

        if (mPaused) {
            vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
            vm.prank(a);
            registry.stake(amount);
            nRejections++;
            return;
        }

        vm.prank(a);
        registry.stake(amount);

        mStaked[a] += amount;
        mTotalStaked += amount;
        nStakes++;
    }

    function _opInitiateUnstake() internal {
        address a = _actor();
        if (mStaked[a] == 0) return;
        uint256 amount = rng.magnitude(1, mStaked[a]);
        if (amount == 0) return;

        vm.prank(a);
        registry.initiateUnstake(amount);

        mStaked[a] -= amount;
        mCooling[a] += amount;
        // Every fresh request restarts the clock for the whole pending amount.
        mCoolEnd[a] = block.timestamp + registry.cooldownDuration();
    }

    function _opUnstake() internal {
        address a = _actor();
        if (mCooling[a] == 0 || block.timestamp < mCoolEnd[a]) return;

        uint256 amount = mCooling[a];
        vm.prank(a);
        registry.unstake();

        mCooling[a] = 0;
        mCoolEnd[a] = 0;
        mTotalStaked -= amount;
        nUnstakes++;
    }

    /// @dev Advancing time is what makes the collateral appreciate, so it is an operation
    ///      in its own right rather than something done between phases.
    function _opWarp() internal {
        vm.warp(block.timestamp + rng.range(1 hours, 20 days));
    }

    /// @dev Transfers must not touch positions at all: the compute right moves, the
    ///      collateral claim does not.
    function _opTransfer() internal {
        address from = _actor();
        address to = _actor();
        if (from == to) return;
        uint256 bal = iai.balanceOf(from);
        if (bal == 0) return;
        uint256 amount = rng.magnitude(1, bal);
        if (amount == 0) return;
        vm.prank(from);
        iai.transfer(to, amount);
    }

    /**
     * @dev Opens and closes issuance mid-run. Pausing is an operational reality, not a phase
     *      the tests visit once, and putting it in the mix is what turns "redemption is never
     *      gated" into a property held across the whole run instead of a single assertion.
     */
    function _opTogglePause() internal {
        if (mPaused) {
            vault.unpause();
            registry.unpause();
        } else {
            vault.pause();
            registry.pause();
        }
        mPaused = !mPaused;
        nPauseToggles++;
    }

    /**
     * @dev Attempts an operation that must fail, from whatever state the run has reached, and
     *      asserts **which** error comes back rather than merely that something did.
     *
     *      There is no before/after snapshot here on purpose. The EVM already rolls back a
     *      reverted frame, so asserting "state did not change" would be testing the EVM; and
     *      the shadow is not advanced for a rejected operation, so the `_assertState()` that
     *      runs after every step already fails if the contract kept anything.
     */
    function _opRejection() internal {
        uint256 pick = rng.next() % 7;
        address a = _actor();

        // `whenIssuanceOpen` is a modifier, so while issuance is closed every mint reverts
        // with `EnforcedPause` before the body's own checks are reached -- no actor holds the
        // pause exemption. That case is already asserted in `_opMint`; here it would just mask
        // the guard under test.
        if (mPaused && pick <= 3) return;

        if (pick == 0) {
            vm.expectRevert(IIAIVault.ZeroAmount.selector);
            vm.prank(a);
            vault.mint(0, type(uint256).max, block.timestamp);
        } else if (pick == 1) {
            // One wei past the ceiling. With the cap below the live supply there is no
            // headroom to overshoot -- a single wei is already too much -- so the amount is
            // relative to whichever side of the supply the cap currently sits on.
            uint256 tooMuch = mCap > mSupply ? mCap - mSupply + 1 : 1;
            vm.expectRevert(
                abi.encodeWithSelector(IIAIVault.CapExceeded.selector, mSupply + tooMuch, mCap)
            );
            vm.prank(a);
            vault.mint(tooMuch, type(uint256).max, block.timestamp);
        } else if (pick == 2) {
            // A deadline in the past, whatever the amount.
            if (block.timestamp == 0) return;
            vm.expectRevert(
                abi.encodeWithSelector(IIAIVault.Expired.selector, block.timestamp - 1, block.timestamp)
            );
            vm.prank(a);
            vault.mint(1e18, type(uint256).max, block.timestamp - 1);
        } else if (pick == 3) {
            // Offering one wei less than the curve asks for. The headroom guard has to cover
            // the whole amount: with less than 1e18 left, `mint` hits its cap check -- which
            // precedes the slippage check -- and the wrong error comes back.
            if (mSupply + 1e18 > mCap) return;
            uint256 needs = _shadowCeilDiv(_shadowCost(mSupply, 1e18) * WAD, vault.exchangeRate());
            if (needs == 0) return;
            a0g.faucetMint(a, needs);
            vm.expectRevert(abi.encodeWithSelector(IIAIVault.ExcessiveInput.selector, needs, needs - 1));
            vm.prank(a);
            vault.mint(1e18, needs - 1, block.timestamp);
        } else if (pick == 4) {
            // Redeeming more than the position holds -- the case a market buyer walks into.
            address owner = _pickWithPosition();
            if (owner == address(0)) return;
            uint256 outstanding = mOutstanding[owner];
            vm.expectRevert(
                abi.encodeWithSelector(IIAIVault.BurnExceedsPosition.selector, outstanding + 1, outstanding)
            );
            vm.prank(owner);
            vault.burn(outstanding + 1, block.timestamp);
        } else if (pick == 5) {
            // Withdrawing more than is staked.
            uint256 staked = mStaked[a];
            vm.expectRevert(
                abi.encodeWithSelector(ICreditRegistry.InsufficientStake.selector, staked + 1, staked)
            );
            vm.prank(a);
            registry.initiateUnstake(staked + 1);
        } else {
            // Claiming before the cooldown has run, or with nothing pending at all.
            if (mCooling[a] == 0) {
                vm.expectRevert(ICreditRegistry.NothingInCooldown.selector);
            } else if (block.timestamp < mCoolEnd[a]) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        ICreditRegistry.CooldownNotOver.selector, mCoolEnd[a], block.timestamp
                    )
                );
            } else {
                return; // it would legitimately succeed
            }
            vm.prank(a);
            registry.unstake();
        }

        nRejections++;
    }

    function _pickWithPosition() internal returns (address) {
        uint256 start = rng.next() % ACTORS;
        for (uint256 i = 0; i < ACTORS; i++) {
            address a = actors[(start + i) % ACTORS];
            if (mOutstanding[a] != 0) return a;
        }
        return address(0);
    }

    // -------------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------------

    function _assertState() internal view {
        uint256 sumLocked;
        uint256 sumOutstanding;
        uint256 sumRegistry;

        for (uint256 i = 0; i < ACTORS; i++) {
            address a = actors[i];

            (uint256 locked, uint256 outstanding, uint256 avgRate) = vault.positionOf(a);
            assertEq(locked, mLocked[a], "position.locked0G");
            assertEq(outstanding, mOutstanding[a], "position.iaiOutstanding");
            // F: a position is either fully open or fully closed, never half of each.
            assertEq(locked == 0, outstanding == 0, "F: no half-cleared position");
            if (outstanding != 0) {
                assertEq(avgRate, (locked * WAD) / outstanding, "average rate is derived");
            }
            sumLocked += locked;
            sumOutstanding += outstanding;

            ICreditRegistry.StakedInfo memory info = registry.stakedInfoOf(a);
            assertEq(info.amountStaked, mStaked[a], "stakedInfo.amountStaked");
            assertEq(info.coolDownAmount, mCooling[a], "stakedInfo.coolDownAmount");
            sumRegistry += info.amountStaked + info.coolDownAmount;
        }

        // A: positions reconcile against the running total.
        assertEq(sumLocked, vault.totalLocked0G(), "A: positions sum to totalLocked0G");
        assertEq(vault.totalLocked0G(), mTotalLocked, "A: total matches the model");

        // D: the vault's counter, the token's supply and the sum of positions all agree,
        // and the cap holds.
        assertEq(vault.supply(), mSupply, "D: supply matches the model");
        assertEq(vault.supply(), iai.totalSupply(), "D: vault and token supply agree");
        assertEq(sumOutstanding, mSupply, "D: outstanding sums to supply");

        // The two governance-adjustable knobs are part of the compared state, so a swap or a
        // resize that did not land is caught on the very next step. `supply <= cap` is
        // deliberately *not* asserted: lowering the cap below the live supply is a supported
        // operation, and `_opMint` pins the consequence -- which error comes back, with which
        // numbers -- rather than the state.
        assertEq(vault.cap(), mCap, "cap matches the model");
        assertEq(address(vault.curve()), mCurve, "the curve in force matches the model");

        // C: solvency. Independent of the curve by construction -- it is measured against
        // `totalLocked0G`, which accumulates what was actually collected.
        uint256 owed = _shadowCeilDiv(vault.totalLocked0G() * WAD, vault.exchangeRate());
        assertGe(a0g.balanceOf(address(vault)), owed, "C: vault covers its obligations");

        // I: the registry holds exactly what it accounts for.
        assertEq(sumRegistry, registry.totalStaked(), "I: buckets sum to totalStaked");
        assertEq(registry.totalStaked(), mTotalStaked, "I: total matches the model");
        assertEq(registry.totalStaked(), iai.balanceOf(address(registry)), "I: total equals holdings");
        assertEq(vault.paused(), mPaused, "pause state matches the model");
        assertEq(registry.paused(), mPaused, "registry pause state matches the model");
    }

    /// @dev A run that quietly stopped exercising an operation would still pass every
    ///      assertion while testing nothing. Fail loudly instead.
    function _assertCoverage() internal view {
        assertGt(nMints, 100, "coverage: mints");
        assertGt(nBurns, 100, "coverage: burns");
        assertGt(nHarvests, 100, "coverage: harvests");
        assertGt(nStakes, 100, "coverage: stakes");
        assertGt(nUnstakes, 10, "coverage: unstakes");
        assertGt(mHarvested, 0, "coverage: yield was actually swept");
        assertGt(nPauseToggles, 20, "coverage: pausing");
        assertGt(nBurnsWhilePaused, 10, "coverage: redemption while issuance is closed");
        assertGt(nRejections, 100, "coverage: rejected operations");
        assertGt(nCapChanges, 100, "coverage: cap changes");
        assertGt(nCurveSwaps, 50, "coverage: curve swaps");
        // Both shapes get real time in force: swaps to a table, and mints priced by one.
        assertGt(nStepSwaps, 25, "coverage: swaps to a step table");
        assertGt(nStepMints, 50, "coverage: mints priced by a step table");
        assertGt(nMintsRejectedByCap, 100, "coverage: mints refused by the cap");
        // These two are what make burn-only a run-time property rather than a claim: the
        // system spent real time with issuance closed by the cap, and redemption and the
        // sweep both kept working throughout.
        assertGt(nBurnsInBurnOnlyMode, 100, "coverage: redemption while the cap is below supply");
        assertGt(nHarvestsInBurnOnlyMode, 25, "coverage: harvest while the cap is below supply");
    }
}
