// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IA0GOracle} from "../interfaces/external/IA0GOracle.sol";

/**
 * @title MockA0GOracle
 * @notice Stand-in for the a0G exchange-rate oracle. ABI-identical to the production one,
 *         including the staleness revert, so consumers cannot accidentally depend on
 *         behaviour that only the mock has.
 *
 * @dev Lives in `src/` rather than `test/` because it is genuinely deployed to the public
 *      testnet and verified there; artifacts under `test/` are excluded from verification
 *      and binding generation.
 *
 *      Two modes:
 *      - **Accruing** (default): the rate rises with wall-clock time, so a tester can watch
 *        yield appear and `harvest()` do something without anyone operating a keeper.
 *        Simple rather than compound interest — compounding on-chain needs either a loop or
 *        an exponent library, and monotonic growth is the only property under test.
 *      - **Manual**: behaves exactly like production, including going stale. This is the mode
 *        unit tests use when they need to pin an exact rate or exercise the stale path.
 */
contract MockA0GOracle is IA0GOracle, Ownable {
    uint256 private constant WAD = 1e18;
    uint256 private constant YEAR = 365 days;

    /// @notice Rate at `startTime`, before any accrual.
    uint256 public baseValue;
    /// @notice Timestamp accrual is measured from.
    uint256 public startTime;
    /// @notice Simple annual growth rate, 1e18 = 100%/year.
    uint256 public apr;
    /// @notice When false the rate only moves via `setValue`, exactly like production.
    bool public autoAccrue;

    uint256 private _manualLastUpdated;
    uint256 public maxAge;

    event ValueSet(uint256 indexed value, uint256 indexed timestamp);
    event MaxAgeSet(uint256 indexed maxAge);
    event AprSet(uint256 apr);
    event AutoAccrueSet(bool enabled);

    constructor(uint256 initialValue, uint256 apr_, uint256 maxAge_, address owner_) Ownable(owner_) {
        baseValue = initialValue;
        startTime = block.timestamp;
        apr = apr_;
        maxAge = maxAge_;
        autoAccrue = true;
        _manualLastUpdated = block.timestamp;
    }

    /// @inheritdoc IA0GOracle
    function value() public view returns (uint256) {
        if (!autoAccrue) return baseValue;
        uint256 elapsed = block.timestamp - startTime;
        return baseValue + Math.mulDiv(baseValue, apr * elapsed, WAD * YEAR);
    }

    /// @inheritdoc IA0GOracle
    /// @dev While accruing the rate is fresh by construction, so this can never go stale.
    ///      Switch to manual mode to exercise the stale path.
    function lastUpdated() public view returns (uint256) {
        return autoAccrue ? block.timestamp : _manualLastUpdated;
    }

    /// @inheritdoc IA0GOracle
    function getValue() external view returns (uint256) {
        // Same message and boundary as production: exactly at maxAge is still valid.
        require(lastUpdated() + maxAge >= block.timestamp, "Oracle: stale value");
        return value();
    }

    /**
     * @notice Sets the rate, mirroring a production oracle write.
     * @param newValue New exchange rate, 0G per a0G scaled by 1e18.
     *
     * @dev Re-anchors accrual on the new value; it does **not** stop it. Use
     *      `setAutoAccrue(false)` to hold the rate still, which is also how the stale path is
     *      reached: with accrual off, `lastUpdated` stops moving and `getValue` eventually
     *      reverts.
     */
    function setValue(uint256 newValue) external onlyOwner {
        baseValue = newValue;
        startTime = block.timestamp;
        _manualLastUpdated = block.timestamp;
        emit ValueSet(newValue, block.timestamp);
    }

    /**
     * @notice Changes the accrual rate.
     * @param newApr Simple annual rate, scaled by 1e18 (1e18 == 100%/year).
     */
    function setApr(uint256 newApr) external onlyOwner {
        // Re-anchor so changing the rate does not retroactively rewrite past accrual.
        baseValue = value();
        startTime = block.timestamp;
        apr = newApr;
        emit AprSet(newApr);
    }

    function setAutoAccrue(bool enabled) external onlyOwner {
        baseValue = value();
        startTime = block.timestamp;
        _manualLastUpdated = block.timestamp;
        autoAccrue = enabled;
        emit AutoAccrueSet(enabled);
    }

    function setMaxAge(uint256 newMaxAge) external onlyOwner {
        maxAge = newMaxAge;
        emit MaxAgeSet(newMaxAge);
    }
}
