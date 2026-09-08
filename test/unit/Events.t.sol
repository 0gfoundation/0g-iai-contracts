// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Vm} from "forge-std/Vm.sol";

import {BaseTest} from "../Base.t.sol";
import {ICreditRegistry} from "../../src/interfaces/ICreditRegistry.sol";
import {IMintCurve} from "../../src/interfaces/IMintCurve.sol";
import {LinearMintCurve} from "../../src/curves/LinearMintCurve.sol";

/**
 * @title EventsTest
 * @notice Every event carries the state it left behind. This checks those fields against what
 *         the contracts actually hold afterwards.
 *
 * @dev The post-state fields exist so an indexer can rebuild the whole picture from the log
 *      stream without a single follow-up call, and can notice a dropped event by checking that
 *      the running totals stay continuous. That only works if the numbers are right, and
 *      nothing was checking them: `Burned.supplyAfter`, for one, is computed before the burn
 *      actually happens and merely happens to be correct.
 *
 *      Asserting against reads taken after the transaction, rather than against values the
 *      test computes itself, is deliberate — it states the property an indexer depends on
 *      instead of restating the implementation.
 */
contract EventsTest is BaseTest {
    bytes32 internal constant MINTED =
        keccak256("Minted(address,uint256,uint256,uint256,uint256,uint256,uint256)");
    bytes32 internal constant BURNED =
        keccak256("Burned(address,address,uint256,uint256,uint256,uint256,uint256,uint256)");
    bytes32 internal constant HARVESTED = keccak256("Harvested(address,uint256,uint256,uint256)");
    bytes32 internal constant STAKED = keccak256("Staked(address,uint256,uint256,uint256)");
    bytes32 internal constant UNSTAKE_INITIATED =
        keccak256("UnstakeInitiated(address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant UNSTAKED = keccak256("Unstaked(address,uint256,uint256)");
    bytes32 internal constant COOLDOWN_UPDATED = keccak256("CooldownDurationUpdated(uint256,uint256)");
    bytes32 internal constant CURVE_UPDATED = keccak256("CurveUpdated(address,address)");
    bytes32 internal constant CAP_UPDATED = keccak256("CapUpdated(uint256,uint256)");

    /// @param topic0 Signature hash of the event to find.
    /// @return log The single matching entry. Reverts the test if there is not exactly one.
    function _only(bytes32 topic0) internal returns (Vm.Log memory log) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic0) {
                log = logs[i];
                found++;
            }
        }
        assertEq(found, 1, "expected exactly one matching event");
    }

    function test_Minted_CarriesTheStateItLeft() public {
        (uint256 expectedDelta0G, uint256 expectedA0GIn) = vault.quoteMint(3e18);
        _fund(alice, 3e18);

        vm.recordLogs();
        vm.prank(alice);
        vault.mint(3e18, type(uint256).max, block.timestamp);
        Vm.Log memory log = _only(MINTED);

        assertEq(address(uint160(uint256(log.topics[1]))), alice, "indexed minter");
        (
            uint256 iaiOut,
            uint256 locked0G,
            uint256 a0GIn,
            uint256 exchangeRate,
            uint256 supplyAfter,
            uint256 totalLocked0GAfter
        ) = abi.decode(log.data, (uint256, uint256, uint256, uint256, uint256, uint256));

        assertEq(iaiOut, 3e18, "iaiOut");
        assertEq(locked0G, expectedDelta0G, "locked0G matches the quote");
        assertEq(a0GIn, expectedA0GIn, "a0GIn matches the quote");
        assertEq(exchangeRate, vault.exchangeRate(), "exchangeRate");

        // The point of the post-state fields: they must equal what an indexer would read.
        assertEq(supplyAfter, iai.totalSupply(), "supplyAfter equals the live supply");
        assertEq(totalLocked0GAfter, vault.totalLocked0G(), "totalLocked0GAfter equals storage");
        (uint256 locked,,) = vault.positionOf(alice);
        assertEq(locked, locked0G, "the position grew by exactly what was reported");
    }

    function test_Burned_CarriesTheStateItLeft() public {
        _mintFor(alice, 4e18);
        (uint256 expectedUnlock, uint256 expectedOut) = vault.quoteBurn(alice, 1e18);

        vm.recordLogs();
        vm.prank(alice);
        vault.burn(1e18, block.timestamp);
        Vm.Log memory log = _only(BURNED);

        assertEq(address(uint160(uint256(log.topics[1]))), alice, "indexed minter");
        assertEq(address(uint160(uint256(log.topics[2]))), alice, "indexed caller");
        (
            uint256 iaiIn,
            uint256 unlocked0G,
            uint256 a0GOut,
            uint256 exchangeRate,
            uint256 supplyAfter,
            uint256 totalLocked0GAfter
        ) = abi.decode(log.data, (uint256, uint256, uint256, uint256, uint256, uint256));

        assertEq(iaiIn, 1e18, "iaiIn");
        assertEq(unlocked0G, expectedUnlock, "unlocked0G matches the quote");
        assertEq(a0GOut, expectedOut, "a0GOut matches the quote");
        assertEq(exchangeRate, vault.exchangeRate(), "exchangeRate");

        // `supplyAfter` is computed before the burn call actually runs. It has to agree with
        // the supply the burn produced, and nothing else was checking that.
        assertEq(supplyAfter, iai.totalSupply(), "supplyAfter equals the live supply");
        assertEq(totalLocked0GAfter, vault.totalLocked0G(), "totalLocked0GAfter equals storage");
    }

    /// @dev A rescue must be distinguishable in an index, which is the only reason `caller` is
    ///      indexed separately from `minter`.
    function test_Burned_DistinguishesARescueFromASelfRedemption() public {
        _mintFor(alice, 2e18);
        vm.prank(alice);
        iai.transfer(rescuer, 2e18);

        vm.recordLogs();
        vm.prank(rescuer);
        vault.burnFor(alice, 2e18, block.timestamp);
        Vm.Log memory log = _only(BURNED);

        assertEq(address(uint160(uint256(log.topics[1]))), alice, "collateral owner");
        assertEq(address(uint160(uint256(log.topics[2]))), rescuer, "caller differs, so it is a rescue");
    }

    function test_Harvested_CarriesTheStateItLeft() public {
        _mintFor(alice, 5e18);
        vm.warp(block.timestamp + 30 days);
        uint256 expected = vault.pendingSurplus();
        assertGt(expected, 0, "there must be something to sweep");

        vm.recordLogs();
        vault.harvest();
        Vm.Log memory log = _only(HARVESTED);

        assertEq(address(uint160(uint256(log.topics[1]))), foundation, "indexed recipient");
        (uint256 surplus, uint256 exchangeRate, uint256 totalLocked0G) =
            abi.decode(log.data, (uint256, uint256, uint256));

        assertEq(surplus, expected, "swept what was pending");
        assertEq(surplus, a0g.balanceOf(foundation), "and the recipient received exactly that");
        assertEq(exchangeRate, vault.exchangeRate(), "exchangeRate");
        assertEq(totalLocked0G, vault.totalLocked0G(), "harvest does not move the obligation");
    }

    function test_Staked_CarriesTheStateItLeft() public {
        _mintFor(alice, 6e18);
        vm.prank(alice);
        iai.approve(address(registry), type(uint256).max);

        vm.recordLogs();
        vm.prank(alice);
        registry.stake(4e18);
        Vm.Log memory log = _only(STAKED);

        assertEq(address(uint160(uint256(log.topics[1]))), alice, "indexed user");
        (uint256 amount, uint256 amountStakedAfter, uint256 totalStakedAfter) =
            abi.decode(log.data, (uint256, uint256, uint256));

        assertEq(amount, 4e18, "amount");
        assertEq(amountStakedAfter, registry.stakedOf(alice), "amountStakedAfter equals storage");
        assertEq(totalStakedAfter, registry.totalStaked(), "totalStakedAfter equals storage");
        assertEq(totalStakedAfter, iai.balanceOf(address(registry)), "and equals what is held");
    }

    function test_UnstakeInitiated_CarriesTheStateItLeft() public {
        _mintFor(alice, 6e18);
        vm.prank(alice);
        iai.approve(address(registry), type(uint256).max);
        vm.prank(alice);
        registry.stake(4e18);

        vm.recordLogs();
        vm.prank(alice);
        registry.initiateUnstake(3e18);
        Vm.Log memory log = _only(UNSTAKE_INITIATED);

        assertEq(address(uint160(uint256(log.topics[1]))), alice, "indexed user");
        (uint256 amount, uint256 amountStakedAfter, uint256 coolDownAmountAfter, uint256 coolDownEnd) =
            abi.decode(log.data, (uint256, uint256, uint256, uint256));

        ICreditRegistry.StakedInfo memory info = registry.stakedInfoOf(alice);
        assertEq(amount, 3e18, "amount");
        assertEq(amountStakedAfter, info.amountStaked, "amountStakedAfter equals storage");
        assertEq(coolDownAmountAfter, info.coolDownAmount, "coolDownAmountAfter equals storage");
        // Emitted so a consumer knows the claim time without a follow-up read.
        assertEq(coolDownEnd, info.coolDownEnd, "coolDownEnd equals storage");
        assertEq(coolDownEnd, block.timestamp + registry.cooldownDuration(), "and is now + cooldown");
    }

    /// @dev A second initiation restarts the clock for the whole pending balance; the event
    ///      has to report the new end, or an indexer will release tokens early in its model.
    function test_UnstakeInitiated_ReportsTheRestartedClock() public {
        _mintFor(alice, 6e18);
        vm.prank(alice);
        iai.approve(address(registry), type(uint256).max);
        vm.prank(alice);
        registry.stake(4e18);
        vm.prank(alice);
        registry.initiateUnstake(1e18);

        vm.warp(block.timestamp + 12 hours);
        vm.recordLogs();
        vm.prank(alice);
        registry.initiateUnstake(1e18);
        Vm.Log memory log = _only(UNSTAKE_INITIATED);

        (,, uint256 coolDownAmountAfter, uint256 coolDownEnd) =
            abi.decode(log.data, (uint256, uint256, uint256, uint256));
        ICreditRegistry.StakedInfo memory info = registry.stakedInfoOf(alice);

        assertEq(coolDownAmountAfter, 2e18, "both amounts are cooling together");
        assertEq(coolDownAmountAfter, info.coolDownAmount);
        assertEq(coolDownEnd, info.coolDownEnd);
        assertEq(coolDownEnd, block.timestamp + registry.cooldownDuration(), "the clock restarted");
    }

    function test_Unstaked_CarriesTheStateItLeft() public {
        _mintFor(alice, 6e18);
        vm.prank(alice);
        iai.approve(address(registry), type(uint256).max);
        vm.prank(alice);
        registry.stake(4e18);
        vm.prank(alice);
        registry.initiateUnstake(4e18);
        vm.warp(block.timestamp + COOLDOWN);

        vm.recordLogs();
        vm.prank(alice);
        registry.unstake();
        Vm.Log memory log = _only(UNSTAKED);

        assertEq(address(uint160(uint256(log.topics[1]))), alice, "indexed user");
        (uint256 amount, uint256 totalStakedAfter) = abi.decode(log.data, (uint256, uint256));

        assertEq(amount, 4e18, "amount");
        assertEq(totalStakedAfter, registry.totalStaked(), "totalStakedAfter equals storage");
        assertEq(totalStakedAfter, iai.balanceOf(address(registry)), "and equals what is held");
    }

    function test_CooldownDurationUpdated_ReportsBothSides() public {
        uint256 previousValue = registry.cooldownDuration();

        vm.recordLogs();
        registry.setCooldownDuration(3 days);
        Vm.Log memory log = _only(COOLDOWN_UPDATED);

        (uint256 previous, uint256 current) = abi.decode(log.data, (uint256, uint256));
        assertEq(previous, previousValue, "previous");
        assertEq(current, 3 days, "current");
        assertEq(current, registry.cooldownDuration(), "and matches storage");
    }

    /**
     * @dev Both governance knobs report the value they replaced as well as the new one. That
     *      is the difference between a log an indexer can rebuild pricing history from and one
     *      it has to go and read the chain to interpret -- and for a curve swap it is the only
     *      record that the previous curve was ever in force at all, since nothing on chain
     *      keeps a list.
     */
    function test_CurveUpdated_ReportsBothSides() public {
        address previousValue = address(vault.curve());
        address next = address(new LinearMintCurve(R0 * 2, CAP, TARGET * 2));

        vm.recordLogs();
        vault.setCurve(IMintCurve(next));
        Vm.Log memory log = _only(CURVE_UPDATED);

        // Both addresses are indexed, so they arrive as topics rather than in the data.
        assertEq(address(uint160(uint256(log.topics[1]))), previousValue, "previous");
        assertEq(address(uint160(uint256(log.topics[2]))), next, "current");
        assertEq(next, address(vault.curve()), "and matches storage");
    }

    function test_CapUpdated_ReportsBothSides() public {
        uint256 previousValue = vault.cap();

        vm.recordLogs();
        vault.setCap(previousValue / 2);
        Vm.Log memory log = _only(CAP_UPDATED);

        (uint256 previous, uint256 current) = abi.decode(log.data, (uint256, uint256));
        assertEq(previous, previousValue, "previous");
        assertEq(current, previousValue / 2, "current");
        assertEq(current, vault.cap(), "and matches storage");
    }

    /// @dev The running totals have to stay continuous across a sequence, or an indexer cannot
    ///      use them to detect a dropped event.
    function test_TotalsAreContinuousAcrossASequence() public {
        vm.recordLogs();

        _mintFor(alice, 2e18);
        _mintFor(bob, 3e18);
        _burnFor(alice, 1e18);
        _mintFor(carol, 1e18);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 runningSupply;
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MINTED) {
                (uint256 iaiOut,,,, uint256 supplyAfter,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
                runningSupply += iaiOut;
                assertEq(supplyAfter, runningSupply, "a mint's supplyAfter is off the running total");
                seen++;
            } else if (logs[i].topics[0] == BURNED) {
                (uint256 iaiIn,,,, uint256 supplyAfter,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
                runningSupply -= iaiIn;
                assertEq(supplyAfter, runningSupply, "a burn's supplyAfter is off the running total");
                seen++;
            }
        }
        assertEq(seen, 4, "every operation logged");
        assertEq(runningSupply, iai.totalSupply(), "the log stream alone reconstructs the supply");
    }
}
