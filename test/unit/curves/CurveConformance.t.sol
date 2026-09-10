// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {IMintCurve} from "../../../src/interfaces/IMintCurve.sol";

/**
 * @title CurveConformanceTest
 * @notice The behavioural contract of `IMintCurve`, as an executable suite.
 *
 * @dev A signature cannot say that `cost` rounds up, that splitting a mint is never cheaper,
 *      or that a quote is affordable — yet the vault's solvency rests on all three. This is
 *      where those live. **A curve is not fit to point the vault at until it inherits this
 *      contract and passes.** That is the entire mechanism turning `IMintCurve`'s NatSpec from
 *      a gentleman's agreement into something a reviewer can run.
 *
 *      Everything here is expressed through `cost`, `quoteForValue` and `maxSafeSupply` alone,
 *      never through a curve's own internals. So it applies unchanged to a curve with a
 *      completely different shape — a piecewise or tabulated exponential curve, say — and,
 *      more importantly, a curve cannot pass it by reporting figures that agree with each
 *      other while disagreeing with what it charges. `cost(s, quoteForValue(s, d)) <= d` is
 *      the load-bearing example: it plays the two functions off against one another rather
 *      than letting either grade its own work.
 *
 *      A subclass supplies the curve and a ladder of supply points to evaluate it at. Keep
 *      the ladder to the supplies the curve is meant to be used at plus its extremes; the
 *      cost is quadratic in its length.
 */
abstract contract CurveConformanceTest is Test {
    /// @return The curve under test.
    function _curve() internal virtual returns (IMintCurve);

    /// @return Supply points to evaluate at, in wei-iAI. Include 0 and the top of the range.
    function _supplies() internal virtual returns (uint256[] memory);

    /// @return Mint sizes to evaluate, in wei-iAI. Include 1 wei.
    function _amounts() internal virtual returns (uint256[] memory);

    /// @dev A curve that gives iAI away lets the recipient claim compute for nothing, and
    ///      permanently inflates the supply every later mint is priced against. The vault
    ///      refuses a zero price as well, so this is belt and braces — deliberately, because
    ///      the failure is silent and unrecoverable.
    function test_Conformance_CostIsNeverZero() public {
        IMintCurve c = _curve();
        uint256 top = c.maxSafeSupply();
        uint256[] memory s = _supplies();
        uint256[] memory d = _amounts();

        for (uint256 i = 0; i < s.length; i++) {
            for (uint256 j = 0; j < d.length; j++) {
                if (d[j] == 0 || s[i] + d[j] > top) continue;
                assertGt(c.cost(s[i], d[j]), 0, "a positive amount must cost something");
            }
        }
    }

    /// @dev The marginal price may never fall as supply rises. A curve that dipped would let
    ///      a minter wait for someone else to push the supply up and then pay less.
    ///
    ///      Pairs that end past `maxSafeSupply()` are skipped rather than evaluated: rule 6
    ///      scopes every promise to `[0, maxSafeSupply()]`, and a tabulated curve has a real
    ///      edge there where the linear curve's arithmetic bound never came into view.
    function test_Conformance_CostIsMonotonicInSupply() public {
        IMintCurve c = _curve();
        uint256 top = c.maxSafeSupply();
        uint256[] memory s = _supplies();
        uint256[] memory d = _amounts();

        for (uint256 j = 0; j < d.length; j++) {
            if (d[j] == 0) continue;
            bool seen;
            uint256 previous;
            for (uint256 i = 0; i < s.length; i++) {
                if (s[i] + d[j] > top) continue;
                uint256 current = c.cost(s[i], d[j]);
                if (seen) assertGe(current, previous, "cost fell as supply rose");
                previous = current;
                seen = true;
            }
        }
    }

    /// @dev Splitting a mint into pieces must never be cheaper than doing it at once,
    ///      otherwise a minter grinds a large mint into fragments and underpays. This is the
    ///      aggregate consequence of rounding every piece up, so a reversed rounding
    ///      direction fails here rather than being noticed years later on a chain.
    function test_Conformance_SplittingIsNeverCheaper() public {
        IMintCurve c = _curve();
        uint256 top = c.maxSafeSupply();
        uint256[] memory s = _supplies();
        uint256[] memory d = _amounts();

        for (uint256 i = 0; i < s.length; i++) {
            for (uint256 j = 0; j < d.length; j++) {
                for (uint256 k = 0; k < d.length; k++) {
                    uint256 a = d[j];
                    uint256 b = d[k];
                    if (a == 0 || b == 0) continue;
                    if (s[i] > type(uint256).max - a - b) continue;
                    if (s[i] + a + b > top) continue;

                    assertGe(
                        c.cost(s[i], a) + c.cost(s[i] + a, b),
                        c.cost(s[i], a + b),
                        "two mints came out cheaper than one"
                    );
                }
            }
        }
    }

    /// @dev The real cross-check between the two functions: whatever `quoteForValue` promises
    ///      for a given budget, `cost` has to actually sell for that budget or less. A curve
    ///      whose quote over-promises would produce quotes the vault then refuses.
    function test_Conformance_AQuoteIsAffordable() public {
        IMintCurve c = _curve();
        uint256[] memory s = _supplies();

        uint256[6] memory budgets =
            [uint256(1), 1e6, 1e18, 1_000e18, 1_000_000e18, 100_000_000e18];

        for (uint256 i = 0; i < s.length; i++) {
            for (uint256 j = 0; j < budgets.length; j++) {
                uint256 amount = c.quoteForValue(s[i], budgets[j]);
                if (amount == 0) continue; // the budget did not reach one wei of iAI
                assertLe(c.cost(s[i], amount), budgets[j], "the quote cannot be afforded");
            }
        }
    }

    /// @dev A budget of zero buys nothing. Trivial, and the one case where an off-by-one in a
    ///      root solver would hand out free iAI.
    function test_Conformance_AZeroBudgetBuysNothing() public {
        IMintCurve c = _curve();
        uint256[] memory s = _supplies();
        for (uint256 i = 0; i < s.length; i++) {
            assertEq(c.quoteForValue(s[i], 0), 0, "zero 0G bought iAI");
        }
    }

    /// @dev The domain the curve declares has to be a domain it actually survives. A curve
    ///      that reverts inside its own stated range would brick issuance at that supply,
    ///      with `setCurve` the only way out.
    function test_Conformance_EvaluableAcrossItsDeclaredDomain() public {
        IMintCurve c = _curve();
        uint256 top = c.maxSafeSupply();
        assertGt(top, 0, "a curve with an empty domain is unusable");

        c.cost(0, 1);
        c.cost(top - 1, 1);
        c.cost(top / 2, 1e18);
        c.quoteForValue(top - 1, 1e18);
        c.quoteForValue(0, type(uint128).max);
    }
}
