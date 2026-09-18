// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {EpochMath} from "../../src/EpochMath.sol";

/**
 * @title EpochMathTest
 * @notice The split-history arithmetic, checked against a replay of every change.
 *
 * @dev `EpochMath.sync` reaches the current epoch in one step, by a ratio of running products.
 *      `_replay` below reaches it the obvious way, applying each missed change in turn. The
 *      two are independent pieces of code -- the shortcut exists only in `src/`, the replay
 *      only here -- so agreement between them is evidence rather than a tautology.
 *
 *      They do not agree to the wei, and cannot: the replay floors two buckets at every step
 *      and so bleeds value as it goes, while the shortcut floors once at the end and instead
 *      carries the drift of a running product. `_tolerance` states the bound that follows from
 *      those two facts. Any real disagreement is orders of magnitude larger.
 *
 *      Where one change separates the position from the present the shortcut degenerates into
 *      exactly one replay step, and there the test demands bit equality.
 */
contract EpochMathTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    // -------------------------------------------------------------------------
    // Reference implementation
    // -------------------------------------------------------------------------

    /// @dev Replays every change the position missed, one at a time, straight from the
    ///      definition: value it at the rate of the change, then re-split it by the new share.
    function _replay(uint256 claim0G, uint256 claimA0G, EpochMath.Epoch[] memory eps, uint256 from)
        internal
        pure
        returns (uint256, uint256)
    {
        for (uint256 i = from + 1; i < eps.length; i++) {
            uint256 v = claim0G + Math.mulDiv(claimA0G, eps[i].rate, WAD);
            claim0G = Math.mulDiv(v, eps[i].share, WAD);
            claimA0G = Math.mulDiv(v, WAD - eps[i].share, eps[i].rate);
        }
        return (claim0G, claimA0G);
    }

    function _oneShot(uint256 claim0G, uint256 claimA0G, EpochMath.Epoch[] memory eps, uint256 from)
        internal
        pure
        returns (uint256, uint256)
    {
        return EpochMath.sync(claim0G, claimA0G, eps[from + 1], eps[eps.length - 1]);
    }

    /// @dev Bound for comparing the raw buckets, which are 0G-denominated and so carry the
    ///      rate-multiplied form of the error. Each replay step can lose a wei flooring the 0G
    ///      bucket and one share flooring the other, and a share is `rate / WAD` in 0G. The
    ///      shortcut's own loss -- a wei at each of three `mulDiv`s, plus the running product's
    ///      drift of under `1e-27` per change -- sits well inside the same envelope.
    function _tolerance(EpochMath.Epoch[] memory eps, uint256 from) internal pure returns (uint256) {
        uint256 steps = eps.length - 1 - from;
        uint256 maxRate = eps[eps.length - 1].rate;
        return steps * (4 + maxRate / WAD) + 16;
    }

    // -------------------------------------------------------------------------
    // Builders
    // -------------------------------------------------------------------------

    function _chain(uint256[] memory rates, uint256[] memory shares)
        internal
        pure
        returns (EpochMath.Epoch[] memory eps)
    {
        eps = new EpochMath.Epoch[](rates.length);
        eps[0] = EpochMath.genesis(rates[0], shares[0]);
        for (uint256 i = 1; i < rates.length; i++) {
            eps[i] = EpochMath.next(eps[i - 1], rates[i], shares[i]);
        }
    }

    /// @dev The worked chain used by the golden vectors: rates 1, 2, 4, 5, 10 and shares
    ///      50%, 80%, 0%, 100%, 60%. The two extremes sit in the middle on purpose.
    function _workedChain() internal pure returns (EpochMath.Epoch[] memory) {
        uint256[] memory rates = new uint256[](5);
        uint256[] memory shares = new uint256[](5);
        (rates[0], shares[0]) = (1e18, 0.5e18);
        (rates[1], shares[1]) = (2e18, 0.8e18);
        (rates[2], shares[2]) = (4e18, 0);
        (rates[3], shares[3]) = (5e18, 1e18);
        (rates[4], shares[4]) = (10e18, 0.6e18);
        return _chain(rates, shares);
    }

    // -------------------------------------------------------------------------
    // Golden vectors
    // -------------------------------------------------------------------------

    /// @dev Hand-computed. g = 1.5, 1.2, 1.25, 1.0 so cumG = 1, 1.5, 1.8, 2.25, 2.25.
    function test_Golden_CumulativeFactors() public pure {
        EpochMath.Epoch[] memory eps = _workedChain();
        assertEq(eps[0].cumG, RAY, "cumG[0]");
        assertEq(eps[1].cumG, 1.5e27, "cumG[1]");
        assertEq(eps[2].cumG, 1.8e27, "cumG[2]");
        assertEq(eps[3].cumG, 2.25e27, "cumG[3]");
        assertEq(eps[4].cumG, 2.25e27, "cumG[4]: a 100% share freezes the value");
    }

    /// @dev Minted in epoch 0 at rate 1.0: 100 0G of curve price, 100 a0G collected, split
    ///      50/50. Value 150 at the first change, 225 at the last.
    function test_Golden_PositionFromGenesisEpoch() public pure {
        EpochMath.Epoch[] memory eps = _workedChain();
        (uint256 c, uint256 a) = _oneShot(50e18, 50e18, eps, 0);
        assertEq(c, 135e18, "claim0G");
        assertEq(a, 9e18, "claimA0G");
        assertEq(EpochMath.value0G(c, a, 10e18), 225e18, "value at the closing rate");
    }

    /// @dev Minted in epoch 1 at rate 3.0, a rate that appears nowhere in the chain: 60 0G of
    ///      curve price, 20 a0G collected, split 80/20.
    function test_Golden_PositionFromMidChain() public pure {
        EpochMath.Epoch[] memory eps = _workedChain();
        assertEq(EpochMath.value0G(48e18, 4e18, 3e18), 60e18, "the mint is worth what it cost");

        (uint256 c, uint256 a) = _oneShot(48e18, 4e18, eps, 1);
        assertEq(c, 48e18, "claim0G");
        assertEq(a, 3.2e18, "claimA0G");
        assertEq(EpochMath.value0G(c, a, 10e18), 80e18, "value at the closing rate");
    }

    function test_Golden_ReplayAgrees() public pure {
        EpochMath.Epoch[] memory eps = _workedChain();
        (uint256 c, uint256 a) = _replay(50e18, 50e18, eps, 0);
        assertEq(c, 135e18, "replay claim0G");
        assertEq(a, 9e18, "replay claimA0G");
    }

    // -------------------------------------------------------------------------
    // One-shot against replay
    // -------------------------------------------------------------------------

    /// @dev One missed change reduces the shortcut to a single replay step, with no running
    ///      product in the way. Nothing here may differ by even a wei.
    function testFuzz_OneMissedChange_IsExact(uint256 claim0G, uint256 claimA0G, uint256 rateSeed, uint256 shareSeed)
        public
        pure
    {
        claim0G = bound(claim0G, 0, 1e26);
        claimA0G = bound(claimA0G, 0, 1e26);

        EpochMath.Epoch[] memory eps = _pair(rateSeed, shareSeed);
        (uint256 c1, uint256 a1) = _oneShot(claim0G, claimA0G, eps, 0);
        (uint256 c2, uint256 a2) = _replay(claim0G, claimA0G, eps, 0);

        assertEq(c1, c2, "claim0G");
        assertEq(a1, a2, "claimA0G");
    }

    function testFuzz_OneShotMatchesReplay(uint256 claim0G, uint256 claimA0G, uint256 seed, uint8 countSeed, uint8 fromSeed)
        public
        pure
    {
        claim0G = bound(claim0G, 0, 1e26);
        claimA0G = bound(claimA0G, 0, 1e26);
        uint256 count = bound(countSeed, 2, 40);
        EpochMath.Epoch[] memory eps = _randomChain(seed, count);
        uint256 from = bound(fromSeed, 0, count - 2);

        (uint256 c1, uint256 a1) = _oneShot(claim0G, claimA0G, eps, from);
        (uint256 c2, uint256 a2) = _replay(claim0G, claimA0G, eps, from);

        uint256 rate = eps[count - 1].rate;
        uint256 steps = count - 1 - from;
        assertApproxEqAbs(
            EpochMath.payout(c1, a1, rate),
            EpochMath.payout(c2, a2, rate),
            steps * 8 + 16,
            "what the position redeems for"
        );

        uint256 tol = _tolerance(eps, from);
        assertApproxEqAbs(c1, c2, tol, "claim0G");
        assertApproxEqAbs(a1, a2, tol, "claimA0G");
    }

    /// @dev Settling in stages must land where settling in one go does. This is the property
    ///      that lets a position be brought up to date lazily, whenever it is next touched,
    ///      rather than at the moment of every change.
    function testFuzz_SettlingInStagesIsTheSame(uint256 claim0G, uint256 claimA0G, uint256 seed, uint8 stopSeed)
        public
        pure
    {
        claim0G = bound(claim0G, 0, 1e26);
        claimA0G = bound(claimA0G, 0, 1e26);
        EpochMath.Epoch[] memory eps = _randomChain(seed, 12);
        uint256 stop = bound(stopSeed, 1, 10);

        (uint256 cDirect, uint256 aDirect) = EpochMath.sync(claim0G, claimA0G, eps[1], eps[11]);
        (uint256 cPart, uint256 aPart) = EpochMath.sync(claim0G, claimA0G, eps[1], eps[stop]);
        (uint256 cStaged, uint256 aStaged) = EpochMath.sync(cPart, aPart, eps[stop + 1], eps[11]);

        uint256 rate = eps[11].rate;
        assertApproxEqAbs(
            EpochMath.payout(cStaged, aStaged, rate),
            EpochMath.payout(cDirect, aDirect, rate),
            16,
            "staged settlement must not drift from direct"
        );
    }

    // -------------------------------------------------------------------------
    // The two properties the split has to have
    // -------------------------------------------------------------------------

    /// @dev A change of split moves nothing. If it did, whoever chose the moment would be
    ///      choosing who gains -- which is exactly the timing game this design exists to avoid.
    ///
    ///      Stated in a0G, not in 0G. The two are the same statement, but a 0G reading
    ///      multiplies a one-share flooring loss by the rate, so at a rate of 575 a wholly
    ///      correct re-split looks 575 wei out. What the holder is owed is a number of shares,
    ///      and in shares the loss is the handful of units the flooring actually costs.
    function testFuzz_AChangePreservesValue(uint256 claim0G, uint256 claimA0G, uint256 rateSeed, uint256 shareSeed)
        public
        pure
    {
        claim0G = bound(claim0G, 0, 1e26);
        claimA0G = bound(claimA0G, 0, 1e26);

        EpochMath.Epoch[] memory eps = _pair(rateSeed, shareSeed);
        uint256 rate = eps[1].rate;
        uint256 before = EpochMath.payout(claim0G, claimA0G, rate);
        (uint256 c, uint256 a) = _oneShot(claim0G, claimA0G, eps, 0);
        uint256 afterwards = EpochMath.payout(c, a, rate);

        // Two of the four floorings land on a 0G quantity that is then converted back into
        // shares, so each costs `WAD / rate` shares rather than one; the other two cost a unit
        // apiece. Hard-coding a constant here silently assumes a rate near one.
        uint256 tol = 2 * Math.ceilDiv(WAD, rate) + 4;

        assertLe(afterwards, before, "a change may not create value");
        assertApproxEqAbs(afterwards, before, tol, "a change may not destroy value");
    }

    /// @dev Once settled, the minter captures `1 - share` of every further increment.
    ///
    ///      Stated in shares rather than as a ratio. The position's value moves by
    ///      `claimA0G * d(rate)` while its whole backing moves by `payout * d(rate)`, so the
    ///      slice captured is `claimA0G / payout` -- but dividing two floored share counts
    ///      magnifies a one-unit loss into whatever `WAD / payout` happens to be. Comparing
    ///      `claimA0G` against its share of the backing keeps the error at the few units the
    ///      flooring actually costs, whatever the rate.
    function testFuzz_MarginalCaptureIsOneMinusShare(uint256 value, uint256 rateSeed, uint256 shareSeed) public pure {
        value = bound(value, 1e18, 1e26);
        uint256 rate = bound(rateSeed, 0.5e18, 1e21);
        uint256 share = bound(shareSeed, 0, WAD);

        uint256 claim0G = Math.mulDiv(value, share, WAD);
        uint256 claimA0G = Math.mulDiv(value, WAD - share, rate);
        uint256 backing = EpochMath.payout(claim0G, claimA0G, rate);

        assertApproxEqAbs(
            claimA0G, Math.mulDiv(backing, WAD - share, WAD), 4, "minter's slice of the next increment"
        );
    }

    // -------------------------------------------------------------------------
    // Guards
    // -------------------------------------------------------------------------

    /// @dev EpochMath is an internal library, so its bodies are inlined and `vm.expectRevert`
    ///      has no call frame to latch onto. Route through a harness.
    function test_Guards_RejectMalformedEpochs() public {
        EpochMathHarness h = new EpochMathHarness();
        EpochMath.Epoch memory e0 = EpochMath.genesis(2e18, 0.5e18);

        vm.expectRevert(EpochMath.ZeroRate.selector);
        h.genesis(0, 0.5e18);

        vm.expectRevert(abi.encodeWithSelector(EpochMath.ShareAboveOne.selector, WAD + 1));
        h.genesis(1e18, WAD + 1);

        vm.expectRevert(abi.encodeWithSelector(EpochMath.RateWentBackwards.selector, 2e18 - 1, 2e18));
        h.next(e0, 2e18 - 1, 0.5e18);

        vm.expectRevert(abi.encodeWithSelector(EpochMath.ShareAboveOne.selector, WAD + 1));
        h.next(e0, 2e18, WAD + 1);
    }

    function test_Next_AcceptsAnUnchangedRate() public pure {
        EpochMath.Epoch memory e0 = EpochMath.genesis(2e18, 0.5e18);
        EpochMath.Epoch memory e1 = EpochMath.next(e0, 2e18, 0.25e18);
        assertEq(e1.cumG, RAY, "a flat rate grows nothing");
    }

    /// @dev The property the monotonicity rule exists for: `cumG` is a divisor in every later
    ///      settlement, and it sits in front of redemption, so a zero there would be permanent.
    function testFuzz_CumulativeFactorNeverShrinks(uint256 seed, uint8 countSeed) public pure {
        uint256 count = bound(countSeed, 2, 60);
        EpochMath.Epoch[] memory eps = _randomChain(seed, count);
        for (uint256 i = 1; i < count; i++) {
            assertGe(eps[i].cumG, eps[i - 1].cumG, "cumG must never fall");
            assertGe(eps[i].cumG, RAY, "cumG must never fall below its starting value");
        }
    }

    // -------------------------------------------------------------------------
    // Obligation and payout must stay mirror images
    // -------------------------------------------------------------------------

    function testFuzz_OwedCoversPayout(uint256 claim0G, uint256 claimA0G, uint256 rateSeed) public pure {
        claim0G = bound(claim0G, 0, 1e26);
        claimA0G = bound(claimA0G, 0, 1e26);
        uint256 rate = bound(rateSeed, 0.5e18, 1e21);

        assertGe(
            EpochMath.owed(claim0G, claimA0G, rate),
            EpochMath.payout(claim0G, claimA0G, rate),
            "the vault must never owe less than it pays"
        );
    }

    function testFuzz_SplitNeverRecordsMoreThanWasCollected(uint256 delta0G, uint256 rateSeed, uint256 shareSeed)
        public
        pure
    {
        delta0G = bound(delta0G, 1, 1e26);
        uint256 rate = bound(rateSeed, 0.5e18, 1e21);
        uint256 share = bound(shareSeed, 0, WAD);

        uint256 a0GIn = Math.mulDiv(delta0G, WAD, rate, Math.Rounding.Ceil);
        (uint256 claim0G, uint256 claimA0G) = EpochMath.split(delta0G, a0GIn, share);

        assertLe(
            EpochMath.payout(claim0G, claimA0G, rate), a0GIn, "a mint may not claim back more than it paid"
        );
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev A two-epoch chain: one change, drawn from the seeds.
    function _pair(uint256 rateSeed, uint256 shareSeed) internal pure returns (EpochMath.Epoch[] memory) {
        uint256[] memory rates = new uint256[](2);
        uint256[] memory shares = new uint256[](2);
        rates[0] = bound(rateSeed, 0.5e18, 1e21);
        rates[1] = rates[0] + bound(rateSeed >> 128, 0, 1e21);
        shares[0] = bound(shareSeed, 0, WAD);
        shares[1] = bound(shareSeed >> 128, 0, WAD);
        return _chain(rates, shares);
    }

    /// @dev Monotone rates, shares drawn across the whole range including both extremes.
    function _randomChain(uint256 seed, uint256 count) internal pure returns (EpochMath.Epoch[] memory) {
        uint256[] memory rates = new uint256[](count);
        uint256[] memory shares = new uint256[](count);
        rates[0] = 0.5e18 + (uint256(keccak256(abi.encode(seed, "r", uint256(0)))) % 1e21);
        shares[0] = _drawShare(seed, 0);
        for (uint256 i = 1; i < count; i++) {
            rates[i] = rates[i - 1] + (uint256(keccak256(abi.encode(seed, "r", i))) % 1e21);
            shares[i] = _drawShare(seed, i);
        }
        return _chain(rates, shares);
    }

    /// @dev One draw in six is an extreme, so `share == 0` and `share == WAD` are exercised
    ///      inside long chains rather than only in tests written for them.
    function _drawShare(uint256 seed, uint256 i) private pure returns (uint256) {
        uint256 x = uint256(keccak256(abi.encode(seed, "s", i)));
        if (x % 6 == 0) return 0;
        if (x % 6 == 1) return WAD;
        return x % (WAD + 1);
    }
}

contract EpochMathHarness {
    function genesis(uint256 rate, uint256 share) external pure returns (EpochMath.Epoch memory) {
        return EpochMath.genesis(rate, share);
    }

    function next(EpochMath.Epoch memory prev, uint256 rate, uint256 share)
        external
        pure
        returns (EpochMath.Epoch memory)
    {
        return EpochMath.next(prev, rate, share);
    }
}
