// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Math} from "./../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

import {BaseTest} from "../Base.t.sol";
import {IMintCurve} from "../../src/interfaces/IMintCurve.sol";
import {ExponentialMintCurve} from "../../src/curves/ExponentialMintCurve.sol";
import {ExponentialTable} from "../unit/curves/ExponentialTable.sol";

/**
 * @title SecurityBase
 * @notice Shared fixture for the security regression suite: the production curve, a
 *         step-wise oracle, and a model of the keeper that writes it.
 *
 * @dev Two things differ from `BaseTest`, and both are load-bearing.
 *
 *      **The curve is the shipped `ExponentialMintCurve`**, built from the same table
 *      `deployments/iai-example.json` carries (`ExponentialTable` is its Solidity mirror). The
 *      unit fixture stays on `LinearMintCurve` for reasons of its own (`CapChange.t.sol` raises
 *      the cap past the table's top); this suite is about what ships, so it repoints the vault
 *      before any position exists. The findings below hold on any `IMintCurve` -- the curve is a
 *      pure function of `(supply, amount)` and never sees the oracle -- but the numbers in the
 *      comments are the production table's, and the linear curve is retired.
 *
 *      **The rate only moves when somebody writes it.** `MockA0GOracle` accrues continuously by
 *      default, which is exactly why the 223-test unit suite and the 100k-op simulation cannot
 *      observe either finding: a continuous rate has no "just before" and "just after". In
 *      production the rate is written by `mellow-interop-bot` (commit 0a971f3) every
 *      `ORACLE_UPDATE_INTERVAL_SECONDS = 28800` from a persisted schedule, unconditionally, so
 *      it is a staircase with a public timetable. `setAutoAccrue(false)` makes the mock match.
 *
 *      **The keeper is modelled, not assumed.** The bot runs two guards before `setValue` and
 *      refuses -- raising a Telegram alert instead of writing -- when either fires
 *      (`src/web3_scripts/oracle_update.py`, `exceeds_deviation` / `is_decrease`):
 *
 *          deviation:  |new - old| * 10_000 > old * ORACLE_MAX_DEVIATION_BPS   (default 100 = 1%)
 *          decrease:   old - new > ORACLE_DECREASE_TOLERANCE_WEI               (default 1e9)
 *
 *      Those guards live in the bot process, not in `Oracle.setValue`, which still accepts any
 *      value from any `SET_VALUE_ROLE` holder. A value the bot refuses reaches the chain by the
 *      path the bot's own README documents: `cli.py oracle-propose` builds the transaction with
 *      `force=True` (no guards, optional `--value`) and posts it to the public Safe transaction
 *      service for signers. So there are two writers with different properties, and the helpers
 *      below name them: `_keeperWrite` asserts the bot would have let the value through;
 *      `_safeWrite` is the multisig path and takes anything. A test that uses `_safeWrite` is
 *      saying, in code, "this value could only have arrived by human approval, publicly queued".
 */
abstract contract SecurityBase is BaseTest {
    /// @dev `ORACLE_UPDATE_INTERVAL_SECONDS` in the bot's `config.json` / `docker-compose.yml`.
    uint256 internal constant KEEPER_INTERVAL = 28_800;
    /// @dev 365 days / 8 hours. The step size the model and the spreadsheet use.
    uint256 internal constant WRITES_PER_YEAR = 365 days / KEEPER_INTERVAL;
    /// @dev `ORACLE_MAX_DEVIATION_BPS`, the bot's default.
    uint256 internal constant BOT_MAX_DEVIATION_BPS = 100;
    /// @dev `ORACLE_DECREASE_TOLERANCE_WEI`, the bot's default.
    uint256 internal constant BOT_DECREASE_TOLERANCE_WEI = 1e9;
    uint256 private constant BPS = 10_000;

    ExponentialMintCurve internal exponential;

    function setUp() public virtual override {
        super.setUp();

        exponential = new ExponentialMintCurve(
            ExponentialTable.BUCKET_WIDTH,
            ExponentialTable.prices(),
            ExponentialTable.BASE,
            ExponentialTable.EXPONENT,
            ExponentialTable.TARGET
        );
        // `CAP` (9,270) sits under the table's top (9,275), so the domain check passes.
        vault.setCurve(IMintCurve(address(exponential)));

        oracle.setAutoAccrue(false);
    }

    // -------------------------------------------------------------------------
    // Keeper model
    // -------------------------------------------------------------------------

    /// @notice Mirrors `oracle_update.exceeds_deviation`: integer comparison, boundary allowed.
    function _botExceedsDeviation(uint256 oldValue, uint256 newValue) internal pure returns (bool) {
        if (oldValue == 0) return true;
        uint256 diff = newValue > oldValue ? newValue - oldValue : oldValue - newValue;
        return diff * BPS > oldValue * BOT_MAX_DEVIATION_BPS;
    }

    /// @notice Mirrors `oracle_update.is_decrease`: a fall larger than rounding noise.
    function _botIsDecrease(uint256 oldValue, uint256 newValue) internal pure returns (bool) {
        return oldValue > newValue && oldValue - newValue > BOT_DECREASE_TOLERANCE_WEI;
    }

    /// @notice Whether the automated keeper would refuse to write `newValue` over `oldValue`.
    function _botWouldRefuse(uint256 oldValue, uint256 newValue) internal pure returns (bool) {
        return _botExceedsDeviation(oldValue, newValue) || _botIsDecrease(oldValue, newValue);
    }

    /**
     * @notice The automated heartbeat: writes only what the bot's guards would let through.
     * @dev Fails the test if the value would have been refused -- a test that needs such a
     *      value must say so by calling `_safeWrite` instead.
     */
    function _keeperWrite(uint256 newValue) internal {
        uint256 oldValue = oracle.value();
        assertFalse(_botWouldRefuse(oldValue, newValue), "keeper model: the bot would refuse this write");
        oracle.setValue(newValue);
    }

    /**
     * @notice The multisig path (`cli.py oracle-propose`, `force=True`): any value, no guards.
     * @dev In production this transaction sits in the public Safe transaction service until
     *      signers approve it, so anyone can see it coming.
     */
    function _safeWrite(uint256 newValue) internal {
        oracle.setValue(newValue);
    }

    /// @notice The rate after one keeper write at `DEFAULT_APR`: er * (1 + APR / writes-per-year).
    function _afterOneStep(uint256 er) internal pure returns (uint256) {
        return er + Math.mulDiv(er, DEFAULT_APR / WRITES_PER_YEAR, WAD);
    }

    // -------------------------------------------------------------------------
    // Vault arithmetic, mirrored exactly
    // -------------------------------------------------------------------------

    /// @notice `mint`'s conversion: value in rounds up.
    function _a0GIn(uint256 value0G, uint256 er) internal pure returns (uint256) {
        return Math.mulDiv(value0G, WAD, er, Math.Rounding.Ceil);
    }

    /// @notice `_settle`'s conversion: value out rounds down.
    function _a0GOut(uint256 value0G, uint256 er) internal pure returns (uint256) {
        return Math.mulDiv(value0G, WAD, er, Math.Rounding.Floor);
    }

    /// @notice `harvest`'s obligation: rounds up, so the sweep is conservative.
    function _owed(uint256 er) internal view returns (uint256) {
        return Math.mulDiv(vault.totalLocked0G(), WAD, er, Math.Rounding.Ceil);
    }

    function _locked(address who) internal view returns (uint256 locked) {
        (locked,,) = vault.positionOf(who);
    }

    /// @notice Stakes the whole of `who`'s iAI balance in the registry.
    function _stakeAll(address who) internal {
        uint256 bal = iai.balanceOf(who);
        vm.startPrank(who);
        iai.approve(address(registry), bal);
        registry.stake(bal);
        vm.stopPrank();
    }
}
