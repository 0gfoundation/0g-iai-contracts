// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IMintCurve} from "../../../src/interfaces/IMintCurve.sol";

/**
 * @title NarrowCurve
 * @notice A curve that prices one 0G per iAI and declares whatever ceiling it is given.
 *
 * @dev The vault has no cap of its own: the ceiling is the curve's `maxSafeSupply()`, so a
 *      curve with a small top is how issuance is closed -- burn-only mode -- and a top of zero
 *      closes it to everyone. Tests that need that state install one of these rather than
 *      reaching for a setter the vault deliberately does not have.
 */
contract NarrowCurve is IMintCurve {
    uint256 private immutable top;

    /// @param top_ The ceiling to report, in wei-iAI.
    constructor(
        uint256 top_
    ) {
        top = top_;
    }

    function cost(uint256, uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function quoteForValue(uint256, uint256 delta0G) external pure returns (uint256) {
        return delta0G;
    }

    function maxSafeSupply() external view returns (uint256) {
        return top;
    }
}

/**
 * @title BreakableCurve
 * @notice A curve that answers normally until it is broken, standing in for one that stops
 *         working after it is already in service.
 *
 * @dev It has to break *after* installation rather than before, because `setCurve` probes the
 *      curve coming in -- a curve that reverts from the start simply cannot be installed. That
 *      is not a contrived shape either: a curve behind a proxy can be upgraded into this state,
 *      and the vault cannot tell a plain curve from a proxied one.
 */
contract BreakableCurve is IMintCurve {
    bool public broken;

    function breakIt() external {
        broken = true;
    }

    function cost(uint256, uint256 amount) external view returns (uint256) {
        require(!broken, "broken");
        return amount;
    }

    function quoteForValue(uint256, uint256 delta0G) external view returns (uint256) {
        require(!broken, "broken");
        return delta0G;
    }

    function maxSafeSupply() external view returns (uint256) {
        require(!broken, "broken");
        return 2 ** 127;
    }
}

/**
 * @title MutableCeilingCurve
 * @notice A curve whose ceiling can be moved after installation, at the same address.
 *
 * @dev The vault cannot tell a plain curve from a proxy in front of one, and a proxied curve can
 *      be upgraded underneath it. This is that shape in one contract: the ceiling moves while
 *      `IAIVault.curve()` still returns the same address, which is exactly the change a snapshot
 *      that compared only the curve address would miss.
 */
contract MutableCeilingCurve is IMintCurve {
    uint256 public top;

    /// @param top_ The ceiling to start with, in wei-iAI.
    constructor(
        uint256 top_
    ) {
        top = top_;
    }

    function setTop(
        uint256 top_
    ) external {
        top = top_;
    }

    function cost(uint256, uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function quoteForValue(uint256, uint256 delta0G) external pure returns (uint256) {
        return delta0G;
    }

    function maxSafeSupply() external view returns (uint256) {
        return top;
    }
}
