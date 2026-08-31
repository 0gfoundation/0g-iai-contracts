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

    /**
     * @notice Deposits iAI and starts earning immediately. Requires an iAI allowance.
     * @param amount Amount to stake, in wei-iAI.
     */
    function stake(uint256 amount) external;

    /**
     * @notice Begins withdrawing `amount`, which stops earning at once.
     * @param amount Amount to move into cooldown, in wei-iAI. Calling this again before
     *               claiming restarts the cooldown for the whole pending balance, not just
     *               the addition.
     */
    function initiateUnstake(uint256 amount) external;

    /// @notice Claims everything whose cooldown has elapsed. Takes no amount, by design.
    function unstake() external;

    /**
     * @notice Changes the withdrawal delay. `DEFAULT_ADMIN_ROLE`.
     * @param newDuration New delay in seconds. Applies to withdrawals started after this
     *                    call; those already in flight keep the end time they were given.
     */
    function setCooldownDuration(uint256 newDuration) external;

    /**
     * @notice The amount currently earning. The single number the off-chain meter reads.
     * @param account Address to read.
     * @return Staked and earning, in wei-iAI. Excludes anything in cooldown.
     */
    function stakedOf(address account) external view returns (uint256);

    /**
     * @notice Full staking record, including any withdrawal in progress.
     * @param account Address to read.
     * @return The account's `amountStaked`, `coolDownAmount` and `coolDownEnd`.
     */
    function stakedInfoOf(address account) external view returns (StakedInfo memory);

    /// @return iAI held by this contract, in wei-iAI: everything staked plus everything in
    ///         cooldown but not yet claimed.
    function totalStaked() external view returns (uint256);

    /// @return Current withdrawal delay, in seconds.
    function cooldownDuration() external view returns (uint256);

    /// @return The iAI token accepted for staking.
    function iai() external view returns (IIAI);
}
