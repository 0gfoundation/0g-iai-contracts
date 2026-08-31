// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "../Base.t.sol";
import {Prng} from "./Prng.sol";
import {ICreditRegistry} from "../../src/interfaces/ICreditRegistry.sol";

/**
 * @title RandomSimTest
 * @notice Drives the system through tens of thousands of randomly chosen operations against
 *         a shadow model maintained in the test, comparing every field after every step.
 *
 * @dev Three deliberate choices:
 *
 *      1. **The shadow recomputes the curve independently.** It uses plain checked
 *         arithmetic with hand-written ceilings rather than the library's `Math.mulDiv`
 *         path. A shadow that called the same helper would only prove the code equals
 *         itself; this one can disagree, which is the entire point.
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

    // --- coverage counters, asserted at the end so a silently degenerate run is caught ---
    uint256 internal nMints;
    uint256 internal nBurns;
    uint256 internal nRescues;
    uint256 internal nHarvests;
    uint256 internal nStakes;
    uint256 internal nUnstakes;

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
        vault.grantRole(vault.RESCUE_ROLE(), address(this));
    }

    // -------------------------------------------------------------------------
    // Independent re-implementation of the curve, for the shadow model
    // -------------------------------------------------------------------------

    /// @dev Written without `Math.mulDiv` on purpose: hand-rolled ceilings over plain
    ///      checked arithmetic, so a rounding-direction change in the library shows up as
    ///      a disagreement rather than being silently mirrored.
    function _shadowCost(uint256 s, uint256 d) internal pure returns (uint256) {
        uint256 linear = (R0 * d + WAD - 1) / WAD;
        uint256 quadratic = (SLOPE * (d * (2 * s + d)) + (2 * WAD * WAD) - 1) / (2 * WAD * WAD);
        return linear + quadratic;
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

        if (roll < 30) {
            _opMint();
        } else if (roll < 52) {
            _opBurn();
        } else if (roll < 58) {
            _opRescue();
        } else if (roll < 66) {
            _opHarvest();
        } else if (roll < 76) {
            _opStake();
        } else if (roll < 84) {
            _opInitiateUnstake();
        } else if (roll < 90) {
            _opUnstake();
        } else if (roll < 96) {
            _opWarp();
        } else {
            _opTransfer();
        }
    }

    function _actor() internal returns (address) {
        return actors[rng.next() % ACTORS];
    }

    // --- operations ---

    function _opMint() internal {
        uint256 headroom = CAP - mSupply;
        if (headroom == 0) return;

        address a = _actor();
        uint256 d = rng.magnitude(1, headroom > 400e18 ? 400e18 : headroom);
        if (d == 0) return;

        uint256 expectedDelta = _shadowCost(mSupply, d);
        uint256 er = vault.exchangeRate();
        uint256 expectedIn = _shadowCeilDiv(expectedDelta * WAD, er);

        a0g.mint(a, expectedIn);
        vm.prank(a);
        vault.mint(d, expectedDelta, expectedIn, block.timestamp);

        mLocked[a] += expectedDelta;
        mOutstanding[a] += d;
        mTotalLocked += expectedDelta;
        mSupply += d;
        nMints++;
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
        uint256 expectedOut = (expectedUnlock * WAD) / vault.exchangeRate();

        vm.prank(a);
        vault.burn(b, expectedOut, block.timestamp);

        mLocked[a] -= expectedUnlock;
        mOutstanding[a] -= b;
        mTotalLocked -= expectedUnlock;
        mSupply -= b;
        nBurns++;
    }

    /**
     * @dev Models the real rescue: the role holder first acquires the stranded tokens from
     *      whoever ended up with them, then settles the original minter's position. The
     *      collateral must land on the minter, never on the caller — that is what makes the
     *      role safe to hold, so it is asserted on every single occurrence rather than once.
     */
    function _opRescue() internal {
        address owner = _pickWithPosition();
        if (owner == address(0)) return;
        address holder = _actor();
        uint256 outstanding = mOutstanding[owner];
        uint256 b = rng.magnitude(1, outstanding);
        if (b == 0 || iai.balanceOf(holder) < b) return;

        // The rescuer obtains the tokens; this test contract holds RESCUE_ROLE.
        vm.prank(holder);
        iai.transfer(address(this), b);

        uint256 expectedUnlock = (mLocked[owner] * b) / outstanding;
        uint256 expectedOut = (expectedUnlock * WAD) / vault.exchangeRate();
        uint256 rescuerBefore = a0g.balanceOf(address(this));
        uint256 ownerBefore = a0g.balanceOf(owner);

        vault.burnFor(owner, b, expectedOut, block.timestamp);

        assertEq(a0g.balanceOf(address(this)), rescuerBefore, "rescuer must never receive collateral");
        assertEq(a0g.balanceOf(owner) - ownerBefore, expectedOut, "collateral goes to the position owner");
        assertEq(iai.balanceOf(address(this)), 0, "rescuer supplied the tokens");

        mLocked[owner] -= expectedUnlock;
        mOutstanding[owner] -= b;
        mTotalLocked -= expectedUnlock;
        mSupply -= b;
        nRescues++;
    }

    function _opHarvest() internal {
        uint256 held = a0g.balanceOf(address(vault));
        uint256 owed = _shadowCeilDiv(mTotalLocked * WAD, vault.exchangeRate());
        uint256 expected = held > owed ? held - owed : 0;

        uint256 got = vault.harvest();
        assertEq(got, expected, "harvest must sweep exactly the surplus");
        mHarvested += got;
        nHarvests++;
    }

    function _opStake() internal {
        address a = _actor();
        uint256 bal = iai.balanceOf(a);
        if (bal == 0) return;
        uint256 amount = rng.magnitude(1, bal);
        if (amount == 0) return;

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
        assertLe(vault.supply(), CAP, "D: cap respected");

        // B: redemption returns the burner's average while the curve gives back the top
        // slice, so the aggregate can only sit at or above the curve, never below.
        assertGe(vault.totalLocked0G(), vault.lockedAt(vault.supply()), "B: total covers the curve");

        // C: solvency.
        uint256 owed = _shadowCeilDiv(vault.totalLocked0G() * WAD, vault.exchangeRate());
        assertGe(a0g.balanceOf(address(vault)), owed, "C: vault covers its obligations");

        // I: the registry holds exactly what it accounts for.
        assertEq(sumRegistry, registry.totalStaked(), "I: buckets sum to totalStaked");
        assertEq(registry.totalStaked(), mTotalStaked, "I: total matches the model");
        assertEq(registry.totalStaked(), iai.balanceOf(address(registry)), "I: total equals holdings");
    }

    /// @dev A run that quietly stopped exercising an operation would still pass every
    ///      assertion while testing nothing. Fail loudly instead.
    function _assertCoverage() internal view {
        assertGt(nMints, 100, "coverage: mints");
        assertGt(nBurns, 100, "coverage: burns");
        assertGt(nRescues, 10, "coverage: rescues");
        assertGt(nHarvests, 100, "coverage: harvests");
        assertGt(nStakes, 100, "coverage: stakes");
        assertGt(nUnstakes, 10, "coverage: unstakes");
        assertGt(mHarvested, 0, "coverage: yield was actually swept");
    }
}
