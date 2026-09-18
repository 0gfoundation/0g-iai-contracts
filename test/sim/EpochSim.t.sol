// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

import {EpochMath} from "../../src/EpochMath.sol";
import {Prng} from "./Prng.sol";

/**
 * @title EpochSimTest
 * @notice A seeded, deterministic long run over the split's arithmetic.
 *
 * @dev The property suite in `test/unit/EpochMath.t.sol` is Foundry fuzz: a thousand runs per
 *      property, on a seed that changes from run to run. Good for discovery, and useless for
 *      reproduction -- a failure found on CI cannot be re-derived locally from anything but the
 *      persisted counterexample. Everything else demanding in this repository is checked the
 *      other way, by a fixed seed consumed strictly in order, and this is the piece that was
 *      missing it.
 *
 *      The shape is `RandomSim`'s, minus the chain. Eight positions and one growing history of
 *      the split; every step either opens an epoch, settles a position, or replaces one. The
 *      library is pure, so a step costs nothing and a hundred thousand of them run in seconds.
 *
 *      **What it checks that fuzzing does not.** Fuzz draws an epoch chain and a position
 *      independently, so a position is never older than the chain it was drawn against and the
 *      two never interleave. Here they do: a position opened at epoch 3 may be settled at epoch
 *      9, replaced, settled again at epoch 40, and so on for as long as the run lasts. That is
 *      the sequence redemption actually walks, and it is where a compression that is subtly
 *      wrong about *where* a position started would show up.
 *
 *      Four things are asserted at every step:
 *
 *        - the one-step settlement agrees with replaying each missed change in turn;
 *        - a settlement neither creates value nor destroys more than the flooring costs;
 *        - the minter captures exactly `1 - share` of the appreciation that follows;
 *        - the totals, restated once and rounded up, stay at or above the sum of the positions,
 *          each restated separately and rounded down -- the property that keeps `_settle`'s
 *          subtractions from underflowing.
 */
contract EpochSimTest is Test {
    using Prng for Prng.State;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant SEED = 0xE90C_45EED;
    uint256 internal constant POSITIONS = 8;

    Prng.State internal rng;

    EpochMath.Epoch[] internal epochs;

    struct Pos {
        uint256 claim0G;
        uint256 claimA0G;
        uint256 epoch;
        bool open;
    }

    Pos[POSITIONS] internal pos;

    // The totals, carried the way the vault carries them: restated eagerly at every change,
    // rounded up, never routed through the running product.
    uint256 internal total0G;
    uint256 internal totalA0G;

    uint256 internal nEpochs;
    uint256 internal nSettles;
    uint256 internal nStaleSettles;
    uint256 internal nDeepSettles;
    uint256 internal nOpens;
    uint256 internal nExtremeShares;
    uint256 internal maxLag;
    uint256 internal nOneStepSettles;

    function setUp() public {
        rng.value = SEED;
        epochs.push(EpochMath.genesis(1e18, 0.5e18));
    }

    function test_EpochSim_10k() public {
        _run(10_000);
    }

    /// @dev Long run, 100k steps. Gated like `RandomSim`'s so the default suite stays fast:
    ///      `SIM_LONG=1 forge test --match-test test_EpochSim_Long`.
    function test_EpochSim_Long() public {
        if (vm.envOr("SIM_LONG", uint256(0)) == 0) return;
        _run(vm.envOr("SIM_OPS", uint256(100_000)));
    }

    function _run(uint256 steps) internal {
        for (uint256 i = 0; i < steps; i++) {
            _step();
            _assertDominance();
        }
        _assertCoverage();
    }

    function _step() internal {
        uint256 roll = rng.next() % 100;
        if (roll < 25) {
            _opOpenEpoch();
        } else if (roll < 75) {
            _opSettle();
        } else {
            _opReplacePosition();
        }
    }

    // -------------------------------------------------------------------------
    // Operations
    // -------------------------------------------------------------------------

    /// @dev A change of split: a monotone rate, a share drawn across the whole range with both
    ///      extremes over-weighted, and the totals restated in one step, rounded up.
    function _opOpenEpoch() internal {
        EpochMath.Epoch memory prev = epochs[epochs.length - 1];
        uint256 rate = prev.rate + rng.magnitude(0, 2e20);
        uint256 share = _drawShare();

        epochs.push(EpochMath.next(prev, rate, share));
        (total0G, totalA0G) = EpochMath.resplitTotals(total0G, totalA0G, rate, share);

        if (share == 0 || share == WAD) nExtremeShares++;
        nEpochs++;
    }

    /**
     * @dev Settle one position, and hold the library's one-step answer against a replay of
     *      every change it missed. The replay is written out here, from the definition, and
     *      shares no code with `EpochMath` beyond the struct it reads.
     */
    function _opSettle() internal {
        uint256 i = rng.next() % POSITIONS;
        if (!pos[i].open) return;

        uint256 n = epochs.length - 1;
        uint256 from = pos[i].epoch;
        if (from == n) return;

        uint256 lag = n - from;
        if (lag > maxLag) maxLag = lag;

        uint256 rateBefore = epochs[from + 1].rate;
        uint256 payableBefore = EpochMath.payout(pos[i].claim0G, pos[i].claimA0G, rateBefore);

        (uint256 cOne, uint256 aOne) =
            EpochMath.sync(pos[i].claim0G, pos[i].claimA0G, epochs[from + 1], epochs[n]);
        (uint256 cRep, uint256 aRep) = _replay(pos[i].claim0G, pos[i].claimA0G, from);

        // Both routes must land in the same place, in the units the holder is paid in.
        uint256 rate = epochs[n].rate;
        assertApproxEqAbs(
            EpochMath.payout(cOne, aOne, rate),
            EpochMath.payout(cRep, aRep, rate),
            lag * 8 + 16,
            "one-step settlement must match the replay"
        );

        // A settlement may not mint value. Compared at the rate of the first change it missed,
        // where the first transform is value-preserving by construction.
        uint256 payableAfter = EpochMath.payout(cOne, aOne, rateBefore);
        if (lag == 1) {
            nOneStepSettles++;
            assertLe(payableAfter, payableBefore, "a settlement may not create value");
            assertApproxEqAbs(
                payableAfter, payableBefore, 2 * Math_ceilDiv(WAD, rateBefore) + 4, "nor destroy it"
            );
        }

        pos[i].claim0G = cOne;
        pos[i].claimA0G = aOne;
        pos[i].epoch = n;

        _assertMarginalCapture(cOne, aOne, epochs[n].share, rate);

        nSettles++;
        if (lag > 1) nStaleSettles++;
        if (lag > 8) nDeepSettles++;
    }

    /**
     * @dev Close a position and open a fresh one, the way a full redemption and a new mint do.
     *      Keeps the replay bounded and puts positions into the chain at staggered points --
     *      the state fuzzing cannot reach, because it draws the chain and the position
     *      independently.
     */
    function _opReplacePosition() internal {
        uint256 i = rng.next() % POSITIONS;
        uint256 n = epochs.length - 1;
        uint256 rate = epochs[n].rate;

        if (pos[i].open) {
            // Settle before removing, exactly as `_settle` does. Subtracting a position's
            // *stale* claims from totals that were restated at every change removes too
            // little, and the totals stop covering the positions within a few dozen steps --
            // this assertion caught that in an earlier draft of this file. It is the concrete
            // reason the vault reaches a position only through its settling accessor.
            (uint256 oldC, uint256 oldA) = pos[i].epoch == n
                ? (pos[i].claim0G, pos[i].claimA0G)
                : EpochMath.sync(pos[i].claim0G, pos[i].claimA0G, epochs[pos[i].epoch + 1], epochs[n]);
            total0G -= oldC;
            totalA0G -= oldA;
        }

        // A mint: a curve price, the a0G it converts to at a rate of the position's own, and
        // the split in force. The mint rate is drawn near but not equal to the epoch's, so
        // positions are not born in the canonical ratio -- which is the case the compression
        // cannot describe and has to step around.
        uint256 mintRate = rate + rng.magnitude(0, 1e19);
        uint256 delta0G = rng.magnitude(1e15, 1e24);
        uint256 a0GIn = Math_ceilDiv(delta0G * WAD, mintRate);
        (uint256 c, uint256 a) = EpochMath.split(delta0G, a0GIn, epochs[n].share);

        pos[i] = Pos({claim0G: c, claimA0G: a, epoch: n, open: true});
        total0G += c;
        totalA0G += a;

        nOpens++;
    }

    // -------------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------------

    /**
     * @dev The property that keeps the vault's `-=` from underflowing. The totals were restated
     *      once per change and rounded up; each position is restated separately and rounded
     *      down. Linearity says the two agree before rounding, so the totals must dominate --
     *      and every open position, settled or lagging, has to be counted at its settled value
     *      for the comparison to mean anything.
     */
    function _assertDominance() internal view {
        uint256 n = epochs.length - 1;
        uint256 sum0G;
        uint256 sumA0G;

        for (uint256 i = 0; i < POSITIONS; i++) {
            if (!pos[i].open) continue;
            uint256 c = pos[i].claim0G;
            uint256 a = pos[i].claimA0G;
            if (pos[i].epoch != n) {
                (c, a) = EpochMath.sync(c, a, epochs[pos[i].epoch + 1], epochs[n]);
            }
            sum0G += c;
            sumA0G += a;
        }

        assertLe(sum0G, total0G, "totals must cover the 0G halves");
        assertLe(sumA0G, totalA0G, "totals must cover the a0G halves");
    }

    /**
     * @dev What the split actually promises, stated without reference to how the position was
     *      built: move the rate, and the holder must capture `1 - share` of the appreciation on
     *      the a0G standing behind them.
     *
     *      Deliberately not the form `claimA0G / payout == 1 - share`. That reads as the same
     *      statement and is not one -- substitute the construction and it reduces to an
     *      identity of the test's own arithmetic, which is what the fuzz property it replaces
     *      was doing. Measuring an actual increment cannot collapse that way.
     */
    function _assertMarginalCapture(uint256 c, uint256 a, uint256 share, uint256 rate) internal pure {
        uint256 backing = EpochMath.payout(c, a, rate);
        uint256 higher = rate + rate / 10;
        uint256 gainToHolder = EpochMath.value0G(c, a, higher) - EpochMath.value0G(c, a, rate);
        uint256 expected = (((backing * (higher - rate)) / WAD) * (WAD - share)) / WAD;

        // Absolute, not relative: the flooring costs at most a share, worth a fixed
        // `(higher - rate) / WAD` in 0G, which is unboundedly large next to a slice taken at a
        // share close to one.
        assertApproxEqAbs(
            gainToHolder,
            expected,
            2 * ((higher - rate) / WAD) + 4,
            "the holder captures exactly their share of the next increment"
        );
    }

    function _assertCoverage() internal view {
        assertGt(nEpochs, 1_000, "coverage: changes of the split");
        assertGt(nSettles, 1_500, "coverage: settlements");
        // The strict "a change creates no value" assertion only applies one step at a time, so
        // a mix that stopped producing single-step settlements would quietly drop it.
        assertGt(nOneStepSettles, 300, "coverage: settlements exactly one change behind");
        assertGt(nStaleSettles, 1_000, "coverage: settlements more than one change behind");
        assertGt(nDeepSettles, 100, "coverage: settlements many changes behind");
        assertGt(nOpens, 1_000, "coverage: positions opened");
        assertGt(nExtremeShares, 300, "coverage: shares of zero or one");
        assertGt(maxLag, 15, "coverage: a position slept through a long stretch");
    }

    // -------------------------------------------------------------------------
    // Reference implementation and helpers
    // -------------------------------------------------------------------------

    /// @dev Every missed change, one at a time, straight from the definition.
    function _replay(uint256 c, uint256 a, uint256 from) internal view returns (uint256, uint256) {
        for (uint256 i = from + 1; i < epochs.length; i++) {
            uint256 v = c + (a * epochs[i].rate) / WAD;
            c = (v * epochs[i].share) / WAD;
            a = (v * (WAD - epochs[i].share)) / epochs[i].rate;
        }
        return (c, a);
    }

    /// @dev One draw in six is an extreme, so zero and one are exercised inside long chains
    ///      rather than only in tests written for them.
    function _drawShare() internal returns (uint256) {
        uint256 x = rng.next();
        if (x % 6 == 0) return 0;
        if (x % 6 == 1) return WAD;
        return x % (WAD + 1);
    }

    function Math_ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
