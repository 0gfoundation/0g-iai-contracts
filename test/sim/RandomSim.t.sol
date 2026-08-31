// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseTest} from "../Base.t.sol";
import {Prng} from "./Prng.sol";
import {ICreditRegistry} from "../../src/interfaces/ICreditRegistry.sol";
import {IIAIVault} from "../../src/interfaces/IIAIVault.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

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
 *         computed outside this codebase and asserted in `test/unit/MintCurve.t.sol`. Stating
 *         this plainly because "independent shadow" would overclaim what these steps prove.
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
    bool internal mPaused;

    // --- coverage counters, asserted at the end so a silently degenerate run is caught ---
    uint256 internal nMints;
    uint256 internal nBurns;
    uint256 internal nRescues;
    uint256 internal nHarvests;
    uint256 internal nStakes;
    uint256 internal nUnstakes;
    uint256 internal nPauseToggles;
    uint256 internal nBurnsWhilePaused;
    uint256 internal nRejections;

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

        if (roll < 27) {
            _opMint();
        } else if (roll < 47) {
            _opBurn();
        } else if (roll < 53) {
            _opRescue();
        } else if (roll < 60) {
            _opHarvest();
        } else if (roll < 69) {
            _opStake();
        } else if (roll < 76) {
            _opInitiateUnstake();
        } else if (roll < 81) {
            _opUnstake();
        } else if (roll < 86) {
            _opWarp();
        } else if (roll < 90) {
            _opTransfer();
        } else if (roll < 93) {
            _opTogglePause();
        } else {
            _opRejection();
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

        if (mPaused) {
            a0g.mint(a, expectedIn);
            vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
            vm.prank(a);
            vault.mint(d, expectedIn, block.timestamp);
            nRejections++;
            return;
        }

        // Funded with exactly the shadow's price, so the balance must come back to where it
        // started: a wei more and the transfer fails, a wei less and this assertion does.
        uint256 heldBefore = a0g.balanceOf(a);
        a0g.mint(a, expectedIn);
        vm.prank(a);
        vault.mint(d, expectedIn, block.timestamp);

        assertEq(a0g.balanceOf(a), heldBefore, "mint took exactly what the shadow priced");

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
        // Redemption no longer takes a minimum-output bound, so the shadow checks the payout
        // instead of merely bounding it.
        uint256 expectedOut = (expectedUnlock * WAD) / vault.exchangeRate();
        uint256 heldBefore = a0g.balanceOf(a);

        vm.prank(a);
        vault.burn(b, block.timestamp);

        assertEq(a0g.balanceOf(a) - heldBefore, expectedOut, "burn payout matches the shadow");
        // The promise that redemption is never gated, held as a running property rather than
        // a single test: this line executes with the vault paused many times per run.
        if (mPaused) nBurnsWhilePaused++;

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

        vault.burnFor(owner, b, block.timestamp);

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
        if (mPaused) {
            vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
            vault.harvest();
            nRejections++;
            return;
        }

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

        // `whenNotPaused` is a modifier, so while issuance is closed every mint reverts with
        // `EnforcedPause` before the body's own checks are reached. That case is already
        // asserted in `_opMint`; here it would just mask the guard under test.
        if (mPaused && pick <= 3) return;

        if (pick == 0) {
            vm.expectRevert(IIAIVault.ZeroAmount.selector);
            vm.prank(a);
            vault.mint(0, type(uint256).max, block.timestamp);
        } else if (pick == 1) {
            // One wei past the cap, priced from the live supply.
            uint256 tooMuch = CAP - mSupply + 1;
            vm.expectRevert(abi.encodeWithSelector(IIAIVault.CapExceeded.selector, CAP + 1, CAP));
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
            // Offering one wei less than the curve asks for.
            if (mSupply >= CAP) return;
            uint256 needs = _shadowCeilDiv(_shadowCost(mSupply, 1e18) * WAD, vault.exchangeRate());
            if (needs == 0) return;
            a0g.mint(a, needs);
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
            // The rescue path is role-gated; an ordinary actor must not reach it.
            address owner = _pickWithPosition();
            if (owner == address(0) || a == address(this)) return;
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, a, vault.RESCUE_ROLE()
                )
            );
            vm.prank(a);
            vault.burnFor(owner, 1, block.timestamp);
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
        assertEq(vault.paused(), mPaused, "pause state matches the model");
        assertEq(registry.paused(), mPaused, "registry pause state matches the model");
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
        assertGt(nPauseToggles, 20, "coverage: pausing");
        assertGt(nBurnsWhilePaused, 10, "coverage: redemption while issuance is closed");
        assertGt(nRejections, 100, "coverage: rejected operations");
    }
}
