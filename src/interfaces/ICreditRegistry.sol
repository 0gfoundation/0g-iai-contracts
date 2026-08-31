// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IIAI} from "./IIAI.sol";

/**
 * @title ICreditRegistry
 * @notice On-chain proof of who has staked how much iAI. The compute entitlement itself is
 *         metered off-chain against this state; nothing about it lives here.
 */
interface ICreditRegistry {
    /**
     * @param amountStaked   Currently earning. The single number the off-chain meter reads.
     * @param coolDownAmount Withdrawal in progress. Already stopped earning.
     * @param coolDownEnd    When `coolDownAmount` becomes claimable.
     */
    struct StakedInfo {
        uint256 amountStaked;
        uint256 coolDownAmount;
        uint256 coolDownEnd;
    }

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientStake(uint256 requested, uint256 staked);
    error NothingInCooldown();
    error CooldownNotOver(uint256 coolDownEnd, uint256 nowTs);

    /// @dev Post-state is carried on every event so an indexer can rebuild the staking set
    ///      from logs alone and detect a missed event by checking the running total.
    event Staked(address indexed user, uint256 amount, uint256 amountStakedAfter, uint256 totalStakedAfter);

    /// @dev `coolDownEnd` is emitted so a consumer knows the claim time without a follow-up read.
    event UnstakeInitiated(
        address indexed user,
        uint256 amount,
        uint256 amountStakedAfter,
        uint256 coolDownAmountAfter,
        uint256 coolDownEnd
    );

    event Unstaked(address indexed user, uint256 amount, uint256 totalStakedAfter);

    event CooldownDurationUpdated(uint256 previous, uint256 current);

    function stake(uint256 amount) external;

    function initiateUnstake(uint256 amount) external;

    function unstake() external;

    function setCooldownDuration(uint256 newDuration) external;

    function stakedOf(address account) external view returns (uint256);

    function stakedInfoOf(address account) external view returns (StakedInfo memory);

    function totalStaked() external view returns (uint256);

    function cooldownDuration() external view returns (uint256);

    function iai() external view returns (IIAI);
}
