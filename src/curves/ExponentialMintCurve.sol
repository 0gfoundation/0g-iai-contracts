// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMintCurve} from "../interfaces/IMintCurve.sol";

/**
 * @title ExponentialMintCurve
 * @notice The exponential bonding curve, as a table of bucket prices.
 *
 * @dev The curve the product publishes is
 *
 *          rate(s) = base * e^(exponent * (s / target)^3)         (0G per iAI)
 *
 *      There is no closed form for its integral and no `exp` on chain. Instead, supply is
 *      cut into buckets of `bucketWidth` iAI and each bucket is priced **flat, at the value
 *      the smooth formula takes at the bucket's upper bound**. The table is computed off
 *      chain by `script/curve/gen_exponential_table.py`, every price rounded up to the wei,
 *      and handed to the constructor. Pricing at the upper bound means the step function
 *      never sits below the smooth curve anywhere in a bucket; the table's total therefore
 *      slightly exceeds the smooth integral, in the vault's favour.
 *
 *      **The table is storage, written once in the constructor, and nothing can write it
 *      again.** There is no setter, no owner and no proxy. That is the same immutability
 *      `LinearMintCurve` gets from `immutable` fields -- Solidity has no immutable arrays --
 *      and it is verifiable from the ABI: no non-view function exists. `base`, `exponent`
 *      and `target` are recorded for provenance only; they are how the table was derived,
 *      and nothing here reads them to make a decision. The vault's cap is a separate,
 *      adjustable number and is deliberately unrelated to the table's top.
 *
 *      Changing the curve -- a higher target, a new base -- means generating a new table,
 *      deploying a new instance and pointing the vault at it. Venice's DIEM does the same
 *      thing by rewriting a table inside an upgradeable contract; here the rewrite is a new
 *      address, so history keeps every table that ever priced a mint.
 *
 *      **Rounding: `cost` takes a single ceiling over the exact bucket sum.** It sums
 *      `price_i * overlap_i` exactly and divides by 1e18 once, rounding up. One ceiling
 *      rather than one per bucket is what makes the three conformance properties hold at the
 *      wei: the exact sum is non-decreasing in `supply` because prices are, and `ceil` keeps
 *      it so (monotonic); `ceil(a) + ceil(b) >= ceil(a + b)` (splitting never cheaper); the
 *      first price is non-zero so the sum is positive and its ceiling at least one wei (never
 *      zero). With per-bucket ceilings the *number* of ceilings would change as `supply`
 *      crossed a boundary, and `cost(s, d)` could fall by a wei as `s` rose by one.
 *
 *      Gas is linear in the buckets a mint touches: one packed storage read covers two
 *      buckets, so an ordinary mint reads one or two slots and a mint across the whole table
 *      reads about two hundred. The bucket index is arithmetic (`supply / bucketWidth`), so
 *      nothing scans from the bottom of the table as the supply grows.
 */
contract ExponentialMintCurve is IMintCurve {
    uint256 private constant WAD = 1e18;

    /// @notice Width of every bucket, in wei-iAI.
    uint256 public immutable bucketWidth;
    /// @notice Number of buckets in the table.
    uint256 public immutable bucketCount;
    /// @notice `bucketCount * bucketWidth`: the supply the table prices up to, exclusive of nothing.
    ///         Also `maxSafeSupply()`.
    uint256 public immutable top;
    /// @notice Marginal price at supply zero the table was derived from, in wei-0G per iAI.
    ///         Provenance only.
    uint256 public immutable base;
    /// @notice Exponent coefficient the table was derived from, scaled by 1e18. Provenance only.
    uint256 public immutable exponent;
    /// @notice Supply the exponent is normalised against, in wei-iAI. Provenance only -- the
    ///         vault's cap is its own number.
    uint256 public immutable target;

    /// @dev Price of each bucket in wei-0G per iAI. Two entries share a storage slot. Written
    ///      by the constructor and by nothing else.
    uint128[] private _prices;

    /// @notice The table must have at least one bucket.
    error EmptyTable();
    /// @notice A bucket of zero width would price nothing.
    error ZeroBucketWidth();
    /// @notice A first price of zero would hand out free iAI.
    error CurveChargesNothing();
    /// @notice Prices must never fall as supply rises.
    error TableNotMonotonic(uint256 index);
    /// @notice A bucket wider than 2^127 wei-iAI cannot be part of any table the vault could use.
    error BucketTooWide(uint256 width);
    /// @notice The table's top, `bucketCount * bucketWidth`, reaches past the vault's absolute
    ///         supply bound of 2^127.
    error TableTooTall(uint256 top);
    /// @notice The provenance `target` lies beyond the table, so the table cannot be the one
    ///         derived for it.
    error TargetBeyondTable(uint256 target, uint256 top);
    /// @notice The requested slice ends past the last bucket.
    error SupplyOutOfDomain(uint256 supplyAfter, uint256 top);

    /**
     * @param bucketWidth_ Width of every bucket, in wei-iAI.
     * @param prices_      One price per bucket, in wei-0G per iAI, in supply order.
     * @param base_        Marginal price at zero supply the table was derived from. Provenance.
     * @param exponent_    Exponent coefficient the table was derived from, scaled by 1e18. Provenance.
     * @param target_      Supply the exponent is normalised against, in wei-iAI. Provenance.
     *
     * @dev **This is the last chance to validate anything.** What is checked is what the vault
     *      and the conformance suite rely on: a positive first price, prices that never fall,
     *      and a domain inside the vault's own hard bound. What cannot be checked here is that
     *      the prices are the formula's -- that is the generator's job, and `run.sh check`
     *      re-derives the table from the recorded parameters and compares it entry by entry.
     *
     *      `_prices = prices_` copies the whole array in one statement. A `push` loop would
     *      rewrite the length slot once per entry, about a million gas more for the
     *      production table. The initcode carries the table as constructor calldata: 371
     *      entries are about 12KB, well under EIP-3860's 49,152-byte limit, which is the
     *      bound a much finer table would eventually meet.
     */
    constructor(uint256 bucketWidth_, uint128[] memory prices_, uint256 base_, uint256 exponent_, uint256 target_) {
        if (prices_.length == 0) revert EmptyTable();
        if (bucketWidth_ == 0) revert ZeroBucketWidth();
        if (prices_[0] == 0) revert CurveChargesNothing();
        for (uint256 i = 1; i < prices_.length; i++) {
            if (prices_[i] < prices_[i - 1]) revert TableNotMonotonic(i);
        }
        // The width is bounded before multiplying so the product itself cannot overflow: a
        // memory array cannot have anywhere near 2^128 entries, so `length * width` then fits.
        if (bucketWidth_ > 2 ** 127) revert BucketTooWide(bucketWidth_);
        uint256 top_ = prices_.length * bucketWidth_;
        if (top_ > 2 ** 127) revert TableTooTall(top_);
        if (target_ > top_) revert TargetBeyondTable(target_, top_);

        bucketWidth = bucketWidth_;
        bucketCount = prices_.length;
        top = top_;
        base = base_;
        exponent = exponent_;
        target = target_;
        _prices = prices_;

        // Evaluable at the extremes, on both paths, once. Every price is below 2^128 and every
        // overlap at most `top` <= 2^127, so the exact sum is below 2^255 -- these calls prove
        // the arithmetic rather than the bound, which holds by construction.
        _cost(top_ - 1, 1);
        _quote(0, _cost(0, top_));
    }

    // -------------------------------------------------------------------------
    // IMintCurve
    // -------------------------------------------------------------------------

    /// @inheritdoc IMintCurve
    function cost(uint256 supply, uint256 amount) external view returns (uint256) {
        return _cost(supply, amount);
    }

    /// @inheritdoc IMintCurve
    function quoteForValue(uint256 supply, uint256 delta0G) external view returns (uint256) {
        return _quote(supply, delta0G);
    }

    /**
     * @inheritdoc IMintCurve
     * @dev The top of the table. Unlike the linear curve's arithmetic bound this is a real
     *      edge: `cost` reverts past it. The vault refuses a cap above it, so raising the cap
     *      past the table means deploying a taller table first -- deliberately, since a
     *      supply the table does not price is a supply nobody has decided a price for.
     */
    function maxSafeSupply() external view returns (uint256) {
        return top;
    }

    // -------------------------------------------------------------------------
    // Views for tooling, charts and the deployment checker. Not on IMintCurve.
    // -------------------------------------------------------------------------

    /// @notice Price of bucket `index`, in wei-0G per iAI.
    /// @param index Bucket index, `0 <= index < bucketCount`.
    function priceAt(
        uint256 index
    ) external view returns (uint256) {
        return _prices[index];
    }

    /// @notice The whole table, in bucket order.
    function prices() external view returns (uint128[] memory) {
        return _prices;
    }

    /// @notice The bucket a given supply falls in.
    /// @param supply Supply in wei-iAI; must be below `top`.
    function bucketOf(
        uint256 supply
    ) external view returns (uint256) {
        if (supply >= top) revert SupplyOutOfDomain(supply, top);
        return supply / bucketWidth;
    }

    /// @notice Marginal price of the next wei of iAI at `supply`, in wei-0G per iAI.
    /// @param supply Supply in wei-iAI; must be below `top`.
    function rateAt(
        uint256 supply
    ) external view returns (uint256) {
        if (supply >= top) revert SupplyOutOfDomain(supply, top);
        return _prices[supply / bucketWidth];
    }

    /**
     * @notice Total 0G this table accounts for at `supply` -- the area under the steps.
     * @param supply Supply to evaluate at, in wei-iAI; at most `top`.
     * @return 0G value in wei-0G, rounded **down**.
     *
     * @dev Views and reconciliation only, never the write path: `cost` rounds up, this rounds
     *      down, and the two must not be mixed. Like `LinearMintCurve.lockedAt` it describes
     *      the shape of this one curve, which after a swap is a different question from how
     *      much collateral the vault actually holds.
     */
    function lockedAt(
        uint256 supply
    ) external view returns (uint256) {
        if (supply > top) revert SupplyOutOfDomain(supply, top);
        return _exactSum(0, supply) / WAD;
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @dev `cost`, callable from the constructor (external calls to `this` are not).
    /// @param supply Current supply, wei-iAI.
    /// @param amount Amount being minted, wei-iAI.
    /// @return 0G value to lock, wei-0G, rounded up once over the exact bucket sum.
    function _cost(uint256 supply, uint256 amount) private view returns (uint256) {
        if (amount == 0) return 0;
        uint256 end = supply + amount;
        if (end > top) revert SupplyOutOfDomain(end, top);
        return Math.ceilDiv(_exactSum(supply, end), WAD);
    }

    /**
     * @dev `quoteForValue`, callable from the constructor. Walks buckets from `supply`,
     *      taking whole buckets while the budget covers them and flooring inside the first
     *      it does not. Works in numerator units (`delta0G * WAD`) so no division happens
     *      until the partial bucket, where it floors.
     *
     *      The result is affordable by construction: a whole bucket is taken only while the
     *      budget covers it, and the partial bucket's `floor(remaining / price)` units charge
     *      at most `remaining`, so the exact charge of everything taken is at most
     *      `delta0G * WAD` and its single ceiling at most `delta0G`. That invariant is asserted
     *      from the running total rather than re-checked by re-pricing the slice: a second walk
     *      would double the cost of every quote to guard a case that cannot occur, and an
     *      assertion that fires is a louder, more honest failure than a silent correction.
     *
     *      Saturates at `top`: a budget that covers the rest of the table buys exactly the
     *      rest of the table. A budget too large to scale by `WAD` covers it a fortiori.
     *
     * @param supply  Current supply, wei-iAI.
     * @param delta0G Budget, wei-0G.
     * @return amount Amount mintable for `delta0G`, wei-iAI, rounded down.
     */
    function _quote(uint256 supply, uint256 delta0G) private view returns (uint256 amount) {
        if (supply >= top || delta0G == 0) return 0;
        if (delta0G > type(uint256).max / WAD) return top - supply;

        uint256 budget = delta0G * WAD;
        uint256 remaining = budget;
        uint256 cursor = supply;
        while (cursor < top) {
            uint256 index = cursor / bucketWidth;
            uint256 price = _prices[index];
            uint256 available = (index + 1) * bucketWidth - cursor;
            uint256 wholeBucket = price * available;
            if (wholeBucket <= remaining) {
                remaining -= wholeBucket;
                cursor += available;
            } else {
                uint256 units = remaining / price;
                remaining -= units * price;
                cursor += units;
                break;
            }
        }
        amount = cursor - supply;

        // `budget - remaining` is the exact charge of `amount`; `cost` returns its ceiling.
        assert(Math.ceilDiv(budget - remaining, WAD) <= delta0G);
    }

    /// @dev `sum over buckets of price_i * overlap_i` for the slice `[from, to)`, in wei-0G
    ///      scaled by WAD. Exact; the caller decides the rounding.
    /// @param from Start of the slice, wei-iAI, inclusive.
    /// @param to   End of the slice, wei-iAI, exclusive; at most `top`.
    /// @return num The exact sum, wei-0G times 1e18.
    function _exactSum(uint256 from, uint256 to) private view returns (uint256 num) {
        uint256 cursor = from;
        while (cursor < to) {
            uint256 index = cursor / bucketWidth;
            uint256 upper = (index + 1) * bucketWidth;
            uint256 stop = to < upper ? to : upper;
            num += uint256(_prices[index]) * (stop - cursor);
            cursor = stop;
        }
    }
}
