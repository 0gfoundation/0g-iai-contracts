// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMintCurve} from "../interfaces/IMintCurve.sol";

/**
 * @title ExponentialMintCurve
 * @notice The exponential bonding curve, charged as a step table.
 *
 * @dev Formula:
 *
 *          rate(s) = base * e^(exponent * s / target)         (0G per iAI)
 *
 *      Buckets: supply is cut into buckets of `bucketWidth` iAI. Bucket `i` covers
 *      `[i * bucketWidth, (i + 1) * bucketWidth)` and is priced flat at `prices[i]`, the
 *      formula's value at the bucket's upper bound, rounded up to the wei. The table is
 *      computed off chain (`script/curve/gen_exponential_table.py`) and is immutable: written
 *      once by the constructor, no setter, no owner, no proxy.
 *
 *      Cap: `top` is the supply ceiling, `maxSafeSupply()`. It is a constructor argument,
 *      not derived from the table, so it need not be a multiple of `bucketWidth`. The table
 *      must cover it (`top <= bucketCount * bucketWidth`) and may run less than one whole
 *      bucket past it. `cost` reverts past `top`; `quoteForValue` saturates at it.
 *
 *      `base`, `exponent` and `target` record how the table was derived. Nothing here reads
 *      them and nothing constrains them; lowering `top` does not require touching them.
 */
contract ExponentialMintCurve is IMintCurve {
    uint256 private constant WAD = 1e18;
    /// @dev The vault's own absolute supply bound.
    uint256 private constant ABSOLUTE_SUPPLY_BOUND = 2 ** 127;

    /// @notice Width of every bucket, in wei-iAI.
    uint256 public immutable bucketWidth;
    /// @notice Number of buckets in the table.
    uint256 public immutable bucketCount;
    /// @notice The supply ceiling, in wei-iAI. Also `maxSafeSupply()`.
    uint256 public immutable top;
    /// @notice `base` of the formula, in wei-0G per iAI. Provenance only.
    uint256 public immutable base;
    /// @notice `exponent` of the formula, scaled by 1e18. Provenance only.
    uint256 public immutable exponent;
    /// @notice `target` of the formula, in wei-iAI. Provenance only.
    uint256 public immutable target;

    /// @dev Price of each bucket in wei-0G per iAI. Written by the constructor only.
    uint128[] private _prices;

    error EmptyTable();
    error ZeroBucketWidth();
    error ZeroCeiling();
    /// @notice A first price of zero would hand out free iAI.
    error CurveChargesNothing();
    /// @notice Prices must never fall as supply rises.
    error TableNotMonotonic(uint256 index);
    error BucketTooWide(uint256 width);
    /// @notice `top` exceeds the vault's absolute supply bound of 2^127.
    error CeilingTooTall(uint256 top);
    /// @notice The table ends below `top`, so part of the issuable supply has no price.
    error CeilingBeyondTable(uint256 top, uint256 tableEnd);
    /// @notice The table runs a whole bucket or more past `top`: buckets nothing can ever reach.
    error TableLongerThanCeiling(uint256 top, uint256 tableEnd);
    /// @notice The requested slice ends past `top`.
    error SupplyOutOfDomain(uint256 supplyAfter, uint256 top);
    /// @notice The requested bucket lies past the last one in the table.
    error BucketOutOfRange(uint256 index, uint256 bucketCount);

    /**
     * @param bucketWidth_ Width of every bucket, in wei-iAI.
     * @param prices_      One price per bucket, in wei-0G per iAI, in supply order.
     * @param top_         The supply ceiling, in wei-iAI. Must satisfy
     *                     `tableEnd - bucketWidth < top <= tableEnd`, `tableEnd = prices.length * bucketWidth`.
     * @param base_        Formula `base`. Provenance.
     * @param exponent_    Formula `exponent`, scaled by 1e18. Provenance.
     * @param target_      Formula `target`, in wei-iAI. Provenance.
     */
    constructor(
        uint256 bucketWidth_,
        uint128[] memory prices_,
        uint256 top_,
        uint256 base_,
        uint256 exponent_,
        uint256 target_
    ) {
        if (prices_.length == 0) revert EmptyTable();
        if (bucketWidth_ == 0) revert ZeroBucketWidth();
        if (top_ == 0) revert ZeroCeiling();
        if (prices_[0] == 0) revert CurveChargesNothing();
        for (uint256 i = 1; i < prices_.length; i++) {
            if (prices_[i] < prices_[i - 1]) revert TableNotMonotonic(i);
        }
        // Keeps `prices_.length * bucketWidth_` below checked-arithmetic overflow.
        if (bucketWidth_ > ABSOLUTE_SUPPLY_BOUND) revert BucketTooWide(bucketWidth_);
        if (top_ > ABSOLUTE_SUPPLY_BOUND) revert CeilingTooTall(top_);
        uint256 tableEnd = prices_.length * bucketWidth_;
        if (top_ > tableEnd) revert CeilingBeyondTable(top_, tableEnd);
        if (tableEnd - top_ >= bucketWidth_) revert TableLongerThanCeiling(top_, tableEnd);

        bucketWidth = bucketWidth_;
        bucketCount = prices_.length;
        top = top_;
        base = base_;
        exponent = exponent_;
        target = target_;
        _prices = prices_;
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

    /// @inheritdoc IMintCurve
    function maxSafeSupply() external view returns (uint256) {
        return top;
    }

    // -------------------------------------------------------------------------
    // Views for tooling, charts and the deployment checker. Not on IMintCurve.
    // -------------------------------------------------------------------------

    /// @notice Price of bucket `index`, in wei-0G per iAI.
    function priceAt(
        uint256 index
    ) external view returns (uint256) {
        if (index >= bucketCount) revert BucketOutOfRange(index, bucketCount);
        return _prices[index];
    }

    /// @notice The whole table, in bucket order.
    function prices() external view returns (uint128[] memory) {
        return _prices;
    }

    /// @notice The bucket a given supply falls in. `supply` must be below `top`.
    function bucketOf(
        uint256 supply
    ) external view returns (uint256) {
        if (supply >= top) revert SupplyOutOfDomain(supply, top);
        return supply / bucketWidth;
    }

    /// @notice Marginal price of the next wei of iAI at `supply`. `supply` must be below `top`.
    function rateAt(
        uint256 supply
    ) external view returns (uint256) {
        if (supply >= top) revert SupplyOutOfDomain(supply, top);
        return _prices[supply / bucketWidth];
    }

    /// @notice Total 0G the table accounts for at `supply` (at most `top`), rounded **down**.
    ///         Views and reconciliation only; `cost` rounds up.
    function lockedAt(
        uint256 supply
    ) external view returns (uint256) {
        if (supply > top) revert SupplyOutOfDomain(supply, top);
        return _exactSum(0, supply) / WAD;
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @dev Exact bucket sum over `[supply, supply + amount)`, one ceiling at the end. A single
    ///      ceiling keeps `cost` monotonic in `supply` and makes splitting a mint never cheaper.
    function _cost(uint256 supply, uint256 amount) private view returns (uint256) {
        if (amount == 0) return 0;
        uint256 end = supply + amount;
        if (end > top) revert SupplyOutOfDomain(end, top);
        return Math.ceilDiv(_exactSum(supply, end), WAD);
    }

    /// @dev Walks buckets from `supply`, taking whole buckets while the budget covers them and
    ///      flooring inside the first it does not -- rounding against the buyer, so the quote is
    ///      always affordable. Saturates at `top`; the last bucket is clipped to `top` so a
    ///      large budget never buys past the ceiling.
    function _quote(uint256 supply, uint256 delta0G) private view returns (uint256 amount) {
        if (supply >= top || delta0G == 0) return 0;
        if (delta0G > type(uint256).max / WAD) return top - supply;

        uint256 remaining = delta0G * WAD;
        uint256 cursor = supply;
        while (cursor < top) {
            uint256 index = cursor / bucketWidth;
            uint256 price = _prices[index];
            uint256 upper = (index + 1) * bucketWidth;
            if (upper > top) upper = top;
            uint256 available = upper - cursor;
            uint256 wholeBucket = price * available;
            if (wholeBucket <= remaining) {
                remaining -= wholeBucket;
                cursor += available;
            } else {
                cursor += remaining / price;
                break;
            }
        }
        amount = cursor - supply;
    }

    /// @dev `sum of price_i * overlap_i` over `[from, to)`, `to <= top`, in wei-0G times 1e18.
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
