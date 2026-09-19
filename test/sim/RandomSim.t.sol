// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "../Base.t.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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
    /// The running product's fixed-point scale, mirrored from `EpochMath`.
    uint256 internal constant RAY = 1e27;
    uint256 internal constant ACTORS = 8;

    Prng.State internal rng;
    address[ACTORS] internal actors;

    // --- shadow model ---
    // A claim is held in two denominations and the proportion is the foundation's share, so
    // the shadow tracks both halves and the epoch each position was last restated under.
    mapping(address => uint256) internal mClaim0G;
    mapping(address => uint256) internal mClaimA0G;
    mapping(address => uint256) internal mEpoch;
    mapping(address => uint256) internal mOutstanding;
    uint256 internal mTotalClaim0G;
    uint256 internal mTotalClaimA0G;
    uint256 internal mSupply;

    // The history of the split, mirrored. Plain arrays rather than the contract's struct, so
    // the shadow shares no type with what it is checking.
    uint256[] internal mEpochRate;
    uint256[] internal mEpochShare;
    uint256[] internal mEpochCumG;

    mapping(address => uint256) internal mStaked;
    mapping(address => uint256) internal mCooling;
    mapping(address => uint256) internal mCoolEnd;
    uint256 internal mTotalStaked;

    uint256 internal mHarvested;
    bool internal mPaused;

    // The pricing surface, adjustable by governance mid-run, and the ceiling, which is the
    // curve's and moves with it. Two shapes of curve alternate; `mKind` says which set of
    // shadow parameters is live.
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

    /// @dev The simulation's step tables are coarse: 500 iAI per bucket, and a full-size table
    ///      of 38 buckets reaches 19,000 iAI, just over twice the fixture's anchor. A swap that
    ///      is meant to close issuance draws fewer buckets, so the top lands below the supply.
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
    uint256 internal nCurveSwaps;
    uint256 internal nNarrowingSwaps;
    uint256 internal nShareChanges;
    uint256 internal nExtremeShares;
    uint256 internal nShareChangesWitnessed;
    uint256 internal nBurnsAcrossAShareChange;
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
        mEpochRate.push(ER0);
        mEpochShare.push(HARVEST_SHARE);
        mEpochCumG.push(RAY);
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

    /**
     * @dev The epoch arithmetic, restated in plain checked arithmetic instead of `Math.mulDiv`
     *      and `EpochMath`. Same formulas, same flooring, different code -- so a regression in
     *      the production rounding shows up as a disagreement here, exactly as it does for the
     *      curve. What is *not* rechecked here is that the running product is a valid shortcut
     *      for replaying every change one at a time; that belongs in `EpochMath.t.sol`, which
     *      holds the shortcut against an independent replay over fuzzed epoch chains.
     */
    function _shadowSync(address a) internal view returns (uint256 c, uint256 ca) {
        c = mClaim0G[a];
        ca = mClaimA0G[a];
        uint256 n = mEpochRate.length - 1;
        uint256 j = mEpoch[a];
        if (j == n) return (c, ca);

        uint256 v = c + (ca * mEpochRate[j + 1]) / WAD;
        if (mEpochCumG[n] != mEpochCumG[j + 1]) v = (v * mEpochCumG[n]) / mEpochCumG[j + 1];

        uint256 share = mEpochShare[n];
        c = (v * share) / WAD;
        ca = (v * (WAD - share)) / mEpochRate[n];
    }

    /// @dev Brings a position up to date in the shadow's own storage, mirroring the lazy
    ///      settlement the vault performs whenever it touches one.
    function _shadowSettle(address a) internal {
        (uint256 c, uint256 ca) = _shadowSync(a);
        mClaim0G[a] = c;
        mClaimA0G[a] = ca;
        mEpoch[a] = mEpochRate.length - 1;
    }

    function _shadowPayout(uint256 c, uint256 ca, uint256 er) internal pure returns (uint256) {
        return (c * WAD) / er + ca;
    }

    function _shadowOwed() internal view returns (uint256) {
        return _shadowCeilDiv(mTotalClaim0G * WAD, vault.exchangeRate()) + mTotalClaimA0G;
    }

    function _shadowValue0G(uint256 c, uint256 ca, uint256 er) internal pure returns (uint256) {
        return c + (ca * er) / WAD;
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
        } else if (roll < 95) {
            _opSetCurve();
        } else if (roll < 97) {
            _opSetHarvestShare();
        } else {
            _opRejection();
        }
    }

    function _actor() internal returns (address) {
        return actors[rng.next() % ACTORS];
    }

    // --- operations ---

    /**
     * @dev The amount is drawn without reference to the ceiling, so whether this mint is
     *      allowed is a question the shadow answers rather than one the sampler avoids. Both
     *      outcomes are asserted: a rejection has to come back as `CapExceeded` with the exact
     *      pair of numbers, from whatever state the run has reached. That is a stronger
     *      statement than a `supply <= cap` assertion, which could not survive a curve swapped
     *      in below the live supply -- the very mode this simulation spends time in.
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

        _shadowSettle(a);
        uint256 share = mEpochShare[mEpochShare.length - 1];
        uint256 addedClaim0G = (expectedDelta * share) / WAD;
        uint256 addedClaimA0G = (expectedIn * (WAD - share)) / WAD;
        mClaim0G[a] += addedClaim0G;
        mClaimA0G[a] += addedClaimA0G;
        mOutstanding[a] += d;
        mTotalClaim0G += addedClaim0G;
        mTotalClaimA0G += addedClaimA0G;
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

        // A redemption of a position that has sat through one or more changes of split is
        // the case the running product exists for; count them so the run cannot stop
        // exercising it unnoticed.
        if (mEpoch[a] != mEpochRate.length - 1) nBurnsAcrossAShareChange++;
        _shadowSettle(a);
        // Both halves are released in the same proportion, each floored on its own.
        uint256 unlocked0G = (mClaim0G[a] * b) / outstanding;
        uint256 unlockedA0G = (mClaimA0G[a] * b) / outstanding;
        // Redemption no longer takes a minimum-output bound, so the shadow checks the payout
        // instead of merely bounding it.
        uint256 expectedOut = _shadowPayout(unlocked0G, unlockedA0G, vault.exchangeRate());
        uint256 heldBefore = a0g.balanceOf(a);

        vm.prank(a);
        vault.burn(b, block.timestamp);

        assertEq(a0g.balanceOf(a) - heldBefore, expectedOut, "burn payout matches the shadow");
        // The promise that redemption is never gated, held as a running property rather than
        // a single test: this line executes with the vault paused many times per run.
        if (mPaused) nBurnsWhilePaused++;
        // The same promise against the other issuance switch: a curve whose top is below the
        // live supply closes minting, and redemption has to stay open through it.
        if (mSupply > mCap) nBurnsInBurnOnlyMode++;

        mClaim0G[a] -= unlocked0G;
        mClaimA0G[a] -= unlockedA0G;
        mOutstanding[a] -= b;
        mTotalClaim0G -= unlocked0G;
        mTotalClaimA0G -= unlockedA0G;
        mSupply -= b;
        nBurns++;
    }

    /**
     * @notice Governance swaps the pricing surface, in both directions -- and with it the
     *         ceiling, deliberately across the live supply.
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
     *
     *      The ceiling is the curve's, so this is also the operation that moves it. Two in
     *      five draws try to install a curve whose top is below the current supply -- about one
     *      swap in five actually does, since the draw needs a supply to be below -- which is
     *      the burn-only mode: `mint` refuses, everything else carries on. Sampling it this
     *      often is the point -- it is a state the system is expected to sit in during an
     *      emergency, so thousands of operations run from inside it rather than one test
     *      poking at it. `setCurve` deliberately has no `maxSafeSupply() >= supply` guard;
     *      adding one would make issuance un-closable exactly when it needs closing, so this
     *      operation exercises the case that guard would have blocked.
     *
     *      The shadow does not read the ceiling back off the curve. For a table it is
     *      the declared top, inside the last bucket; for the linear curve it is the anchor the
     *      constructor was handed. Both are asserted against the deployed curve, so a curve
     *      that reported something else would be caught here rather than mirrored.
     */
    function _opSetCurve() internal {
        // A ceiling below the live supply, when there is a supply to be below. The floor of
        // 100 iAI keeps the linear curve's slope in a range whose arithmetic is proven.
        bool narrow = rng.chance(40) && mSupply > 100e18 + SIM_WIDTH;

        if (nCurveSwaps % 2 == 0) {
            uint256 r0 = rng.range(1e21, 20e21);
            // The anchor is the ceiling. Wide swaps take it anywhere from the supply up to
            // twice the fixture's; narrow ones put it below the supply.
            uint256 anchor = narrow ? rng.range(100e18, mSupply - 1) : rng.range(mSupply, 2 * CAP);
            // Vary the curvature: `extra` is the 0G the sloped part accounts for on top of the
            // flat part, and it is what fixes the slope.
            uint256 flat = (r0 * anchor) / WAD;
            uint256 extra = rng.range(1e25, 3e26);

            LinearMintCurve c = new LinearMintCurve(r0, anchor, flat + extra);
            uint256 slope = _shadowSlope(r0, anchor, flat + extra);
            assertEq(c.slope(), slope, "the shadow derives the same slope the library does");
            assertEq(c.maxSafeSupply(), anchor, "the linear curve's ceiling is its anchor");

            vault.setCurve(IMintCurve(address(c)));

            mKind = CurveKind.Linear;
            mR0 = r0;
            mSlope = slope;
            mCap = anchor;
            mCurve = address(c);
        } else {
            // A narrow table ends below the supply; a wide one reaches 19,000 iAI, past any
            // ceiling a linear swap can set, so the supply can never outgrow the wide tables.
            uint256 buckets = narrow ? rng.range(1, (mSupply - 1) / SIM_WIDTH) : SIM_BUCKETS;
            uint128[] memory p = new uint128[](buckets);
            p[0] = uint128(rng.range(1e21, 20e21));
            for (uint256 i = 1; i < buckets; i++) {
                // Zero is a legal increment: flat runs of equal buckets are part of the mix.
                p[i] = p[i - 1] + uint128(rng.range(0, 3e21));
            }

            // The ceiling is declared, not derived: anywhere in the last bucket, so it is
            // usually not a multiple of the width and the clipped last bucket is exercised.
            uint256 top = buckets * SIM_WIDTH - rng.range(0, SIM_WIDTH / 2);
            ExponentialMintCurve c = new ExponentialMintCurve(SIM_WIDTH, p, top, p[0], 0, top);
            assertEq(c.maxSafeSupply(), top, "the curve's ceiling is the top it was given");
            if (!narrow) assertGe(top, 2 * CAP, "a wide table reaches past twice the anchor");

            vault.setCurve(IMintCurve(address(c)));

            mKind = CurveKind.Step;
            mWidth = SIM_WIDTH;
            mPrices = p;
            mCap = top;
            mCurve = address(c);
            nStepSwaps++;
        }
        if (mCap < mSupply) nNarrowingSwaps++;
        nCurveSwaps++;
    }

    /**
     * @notice Governance retunes the split, mid-run, in both directions and to both extremes.
     *
     * @dev The change must move nothing: every position is worth what it was worth a moment
     *      before, and so is the obligation the sweep is measured against. Both are asserted
     *      here, across the whole range of shares rather than at a chosen one.
     *
     *      Positions are deliberately *not* settled in the shadow. The vault leaves them for
     *      whenever each is next touched, and the per-step comparison then has to agree with
     *      that lazy settlement -- which is the property worth running thousands of times.
     */
    function _opSetHarvestShare() internal {
        uint256 roll = rng.next() % 10;
        uint256 newShare = roll == 0 ? 0 : (roll == 1 ? WAD : rng.next() % (WAD + 1));

        uint256 er = vault.exchangeRate();
        uint256 owedBefore = _shadowOwed();
        // Only a position already settled at the current epoch can be held to the strict
        // statement. For one that is several changes behind, the before and after readings are
        // two independent one-shot computations rather than one step applied to the other, so
        // their flooring is free to differ by a wei in either direction -- which says nothing
        // about whether the change itself moved anything. The lagging case is covered anyway:
        // every position is compared against the shadow after every step.
        address witness = _pickWithPosition();
        if (witness != address(0) && mEpoch[witness] != mEpochRate.length - 1) witness = address(0);
        uint256 valueBefore;
        if (witness != address(0)) {
            valueBefore = _shadowPayout(mClaim0G[witness], mClaimA0G[witness], er);
        }

        vault.setHarvestShare(newShare);

        uint256 prevRate = mEpochRate[mEpochRate.length - 1];
        uint256 prevShare = mEpochShare[mEpochShare.length - 1];
        uint256 g = (RAY * (prevShare * prevRate + (WAD - prevShare) * er)) / (WAD * prevRate);
        mEpochCumG.push((mEpochCumG[mEpochCumG.length - 1] * g) / RAY);
        mEpochRate.push(er);
        mEpochShare.push(newShare);

        // The totals move in one step and round up, where a position rounds down.
        uint256 v = mTotalClaim0G + _shadowCeilDiv(mTotalClaimA0G * er, WAD);
        mTotalClaim0G = _shadowCeilDiv(v * newShare, WAD);
        mTotalClaimA0G = _shadowCeilDiv(v * (WAD - newShare), er);

        assertGe(_shadowOwed(), owedBefore, "a change may not shrink the obligation");
        if (witness != address(0)) {
            (uint256 c2, uint256 ca2) = _shadowSync(witness);
            uint256 valueAfter = _shadowPayout(c2, ca2, er);
            assertLe(valueAfter, valueBefore, "a change may not create value");
            assertApproxEqAbs(valueAfter, valueBefore, 8, "a change may not destroy value");
            nShareChangesWitnessed++;
        }

        if (newShare == 0 || newShare == WAD) nExtremeShares++;
        nShareChanges++;
    }

    function _opHarvest() internal {
        if (mPaused) {
            vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
            vault.harvest();
            nRejections++;
            return;
        }

        uint256 held = a0g.balanceOf(address(vault));
        uint256 owed = _shadowOwed();
        uint256 expected = held > owed ? held - owed : 0;

        uint256 got = vault.harvest();
        assertEq(got, expected, "harvest must sweep exactly the surplus");
        mHarvested += got;
        nHarvests++;
        // `harvest` is gated by `pause`, not by the ceiling. A curve whose top is below the
        // supply therefore closes issuance while the sweep keeps running -- which is why the
        // documented way to wind the system down is `pause()`, not a narrower curve.
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
        _warp(rng.range(1 hours, 20 days));
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
        uint256 pick = rng.next() % 8;
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
            // One wei past the ceiling. With the ceiling below the live supply there is no
            // headroom to overshoot -- a single wei is already too much -- so the amount is
            // relative to whichever side of the supply the ceiling currently sits on.
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
            // the whole amount: with less than 1e18 left, `mint` hits its ceiling check --
            // which precedes the slippage check -- and the wrong error comes back.
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
            // A governance function from an ordinary wallet. Every other case here is a value
            // or state guard; without this one the run asserts nothing about the role gates.
            // `setCurve` is handed the curve already in force: the modifier fires before the
            // body, so the argument does not matter, and nothing changes if it somehow did.
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, a, bytes32(0)
                )
            );
            vm.prank(a);
            vault.setCurve(IMintCurve(mCurve));
        } else if (pick == 6) {
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
        uint256 sumPayable;
        uint256 er = vault.exchangeRate();

        for (uint256 i = 0; i < ACTORS; i++) {
            address a = actors[i];

            (uint256 locked, uint256 outstanding, uint256 avgRate) = vault.positionOf(a);
            assertEq(outstanding, mOutstanding[a], "position.iaiOutstanding");

            // Both halves separately: value shifted from one to the other leaves the combined
            // figure untouched, so comparing only `positionOf` would not see it.
            (uint256 claim0G, uint256 claimA0G, uint256 epoch) = vault.positionClaims(a);
            (uint256 mc, uint256 mca) = _shadowSync(a);
            assertEq(claim0G, mc, "position.claim0G");
            assertEq(claimA0G, mca, "position.claimA0G");
            sumPayable += _shadowPayout(claim0G, claimA0G, er);
            assertEq(epoch, mEpochRate.length - 1, "a read settles the position to the present");

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

        // A: positions reconcile against the running total. Not to the wei any more: a
        // change of split restates the totals rounded up and each position rounded down, so
        // the totals sit a little above the sum they stand for. The gap is bounded by a couple
        // of wei per position per change and is claimable by nobody -- it leaves as surplus.
        assertLe(sumLocked, vault.totalLocked0G(), "A: the total covers every position");
        assertApproxEqAbs(
            sumLocked, vault.totalLocked0G(), ACTORS * 8 * (nShareChanges + 1), "A: and by no more than dust"
        );
        assertEq(vault.totalClaim0G(), mTotalClaim0G, "A: the 0G half matches the model");
        assertEq(vault.totalClaimA0G(), mTotalClaimA0G, "A: the a0G half matches the model");

        // The split itself is compared state, so a change that did not land is caught on the
        // next step rather than showing up later as a mispriced redemption.
        assertEq(vault.harvestShare(), mEpochShare[mEpochShare.length - 1], "the split matches the model");
        assertEq(vault.currentEpoch(), mEpochRate.length - 1, "the epoch matches the model");

        // D: the vault's counter, the token's supply and the sum of positions all agree.
        assertEq(vault.supply(), mSupply, "D: supply matches the model");
        assertEq(vault.supply(), iai.totalSupply(), "D: vault and token supply agree");
        assertEq(sumOutstanding, mSupply, "D: outstanding sums to supply");

        // The curve in force and the ceiling it carries are part of the compared state, so a
        // swap that did not land is caught on the very next step. `supply <= cap` is
        // deliberately *not* asserted: a curve whose top is below the live supply is a
        // supported state, and `_opMint` pins the consequence -- which error comes back, with
        // which numbers -- rather than the state.
        assertEq(vault.cap(), mCap, "the ceiling matches the model");
        assertEq(address(vault.curve()), mCurve, "the curve in force matches the model");

        // C: solvency. Independent of the curve by construction -- it is measured against
        // `totalLocked0G`, which accumulates what was actually collected.
        // C: solvency. The promise is that every position can be paid, so that is what is
        // asserted, strictly. `_shadowOwed` is the vault's own figure and is a deliberate
        // ceiling -- the totals round up where positions round down -- so it is allowed to
        // sit a few wei above the balance, per change of split, without anyone being short.
        uint256 held = a0g.balanceOf(address(vault));
        assertGe(held, sumPayable, "C: vault can pay every position");
        assertLe(_shadowOwed(), held + 4 * (nShareChanges + 1), "C: the obligation is a ceiling");

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
        assertGt(nCurveSwaps, 100, "coverage: curve swaps");
        assertGt(nNarrowingSwaps, 50, "coverage: swaps that put the ceiling below the supply");
        // Both shapes get real time in force: swaps to a table, and mints priced by one.
        assertGt(nStepSwaps, 25, "coverage: swaps to a step table");
        assertGt(nStepMints, 50, "coverage: mints priced by a step table");
        assertGt(nMintsRejectedByCap, 100, "coverage: mints refused by the ceiling");
        // These two are what make burn-only a run-time property rather than a claim: the
        // system spent real time with issuance closed by the curve's top, and redemption and
        // the sweep both kept working throughout.
        assertGt(nBurnsInBurnOnlyMode, 100, "coverage: redemption while the ceiling is below supply");
        assertGt(nHarvestsInBurnOnlyMode, 25, "coverage: harvest while the ceiling is below supply");
        // The split is retuned throughout, to both extremes as well as between them, and
        // positions are redeemed that have sat through one or more of those changes -- which
        // is the case the running product exists to make cheap.
        assertGt(nShareChanges, 100, "coverage: changes of the harvest share");
        assertGt(nExtremeShares, 10, "coverage: shares of zero or one");
        assertGt(nShareChangesWitnessed, 50, "coverage: changes measured against a settled position");
        assertGt(nBurnsAcrossAShareChange, 200, "coverage: redemption after a change of share");
    }
}
