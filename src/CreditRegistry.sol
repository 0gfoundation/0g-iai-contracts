// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICreditRegistry} from "./interfaces/ICreditRegistry.sol";
import {IIAI} from "./interfaces/IIAI.sol";

/**
 * @title CreditRegistry
 * @notice Staking of iAI for compute entitlement. The contract's only job is to make
 *         "who is staked, for how much" unambiguous and cheaply indexable.
 *
 * @dev Staking is opt-in on purpose. It separates holders who intend to consume compute
 *      from tokens sitting idle in pools and exchanges, which is what keeps aggregate
 *      utilisation below the level the program is funded for. Reading balances directly
 *      would erase that distinction.
 *
 *      Withdrawal is two-step. `initiateUnstake` stops the entitlement **immediately**,
 *      before the cooldown elapses — otherwise a holder could stake just before an
 *      off-chain snapshot, unstake just after, and collect a full period's entitlement
 *      while keeping the token liquid the rest of the time.
 *
 *      Adding to a withdrawal already in flight restarts the clock on the whole amount.
 *      That keeps the per-user record to one slot instead of an unbounded queue; the cost
 *      is a UX detail that has to be surfaced, not a correctness one.
 *
 *      Zero coupling to the vault: this contract only ever touches the iAI token. It can be
 *      paused, upgraded or replaced without any effect on collateral.
 */
contract CreditRegistry is
    ICreditRegistry,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice May pause staking. Cannot block withdrawal.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @custom:storage-location erc7201:0g.iai.CreditRegistry
    struct RegistryStorage {
        IIAI iai;
        uint256 cooldownDuration;
        uint256 totalStaked;
        mapping(address => StakedInfo) stakedInfos;
    }

    // keccak256(abi.encode(uint256(keccak256("0g.iai.CreditRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RegistryStorageLocation =
        0xdd975a1acc8e4f2cae212131a7e17d45a4b87285048f005d84010e8696a62200;

    function _s() private pure returns (RegistryStorage storage $) {
        assembly {
            $.slot := RegistryStorageLocation
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Wires the registry to its token and sets the unstaking delay.
     * @param iai_              The iAI token accepted for staking. Must be non-zero.
     * @param cooldownDuration_ Delay between `initiateUnstake` and `unstake`, in seconds.
     *
     * @dev Starts open. There is nothing to gate: staking cannot begin before the vault is
     *      unpaused and iAI exists, and `PAUSER_ROLE` can close it at any time.
     */
    function initialize(address iai_, uint256 cooldownDuration_) external initializer {
        if (iai_ == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        RegistryStorage storage $ = _s();
        $.iai = IIAI(iai_);
        $.cooldownDuration = cooldownDuration_;
    }

    /// @inheritdoc ICreditRegistry
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        RegistryStorage storage $ = _s();
        StakedInfo storage info = $.stakedInfos[_msgSender()];

        uint256 stakedAfter = info.amountStaked + amount;
        uint256 totalAfter = $.totalStaked + amount;
        info.amountStaked = stakedAfter;
        $.totalStaked = totalAfter;

        IERC20(address($.iai)).safeTransferFrom(_msgSender(), address(this), amount);

        emit Staked(_msgSender(), amount, stakedAfter, totalAfter);
    }

    /**
     * @inheritdoc ICreditRegistry
     * @dev Not pausable. `totalStaked` is unchanged here — the tokens are still held by this
     *      contract, just no longer earning — so it stays equal to the contract's iAI balance.
     */
    function initiateUnstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        RegistryStorage storage $ = _s();
        StakedInfo storage info = $.stakedInfos[_msgSender()];
        if (amount > info.amountStaked) revert InsufficientStake(amount, info.amountStaked);

        uint256 stakedAfter = info.amountStaked - amount;
        uint256 coolingAfter = info.coolDownAmount + amount;
        uint256 endsAt = block.timestamp + $.cooldownDuration;

        info.amountStaked = stakedAfter;
        info.coolDownAmount = coolingAfter;
        info.coolDownEnd = endsAt;

        emit UnstakeInitiated(_msgSender(), amount, stakedAfter, coolingAfter, endsAt);
    }

    /// @notice Withdraws the entire matured amount. Not pausable.
    function unstake() external nonReentrant {
        RegistryStorage storage $ = _s();
        StakedInfo storage info = $.stakedInfos[_msgSender()];

        uint256 amount = info.coolDownAmount;
        if (amount == 0) revert NothingInCooldown();
        if (block.timestamp < info.coolDownEnd) revert CooldownNotOver(info.coolDownEnd, block.timestamp);

        // Clear before transferring; leaving this set would allow a second withdrawal.
        info.coolDownAmount = 0;
        info.coolDownEnd = 0;
        uint256 totalAfter = $.totalStaked - amount;
        $.totalStaked = totalAfter;

        IERC20(address($.iai)).safeTransfer(_msgSender(), amount);

        emit Unstaked(_msgSender(), amount, totalAfter);
    }

    /// @inheritdoc ICreditRegistry
    function setCooldownDuration(uint256 newDuration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RegistryStorage storage $ = _s();
        emit CooldownDurationUpdated($.cooldownDuration, newDuration);
        $.cooldownDuration = newDuration;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @inheritdoc ICreditRegistry
    function stakedOf(address account) external view returns (uint256) {
        return _s().stakedInfos[account].amountStaked;
    }

    function stakedInfoOf(address account) external view returns (StakedInfo memory) {
        return _s().stakedInfos[account];
    }

    function totalStaked() external view returns (uint256) {
        return _s().totalStaked;
    }

    function cooldownDuration() external view returns (uint256) {
        return _s().cooldownDuration;
    }

    function iai() external view returns (IIAI) {
        return _s().iai;
    }
}
