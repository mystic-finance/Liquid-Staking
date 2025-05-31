// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { IPlumeStaking } from "./IPlumeStaking.sol";
import { PlumeStakingStorage } from "./PlumeStakingStorage.sol";

/// @title IstPlumeMinter - Interface for stPlumeMinter contract
/// @notice Interface for the stPlumeMinter contract which extends frxETHMinter with staking capabilities
interface IstPlumeMinter {
    // Constants and Public Variables
    function YIELD_FEE() external view returns (uint256);
    function REDEMPTION_FEE() external view returns (uint256);
    function INSTANT_REDEMPTION_FEE() external view returns (uint256);
    function withHoldEth() external view returns (uint256);
    function yieldEth() external view returns (uint256);
    function rewardsEth() external view returns (uint256);
    function rewardsCycleLength() external view returns (uint32);
    function lastSync() external view returns (uint32);
    function rewardsCycleEnd() external view returns (uint32);
    function lastRewardAmount() external view returns (uint192);
    function minStake() external view returns (uint256);
    // function cycleRewards(uint256 index) external view returns (CycleRewards memory);
    // function withdrawalRequests(address user) external view returns (WithdrawalRequest memory);
    // function userRewards(address user) external view returns (UserRewards memory);
    function maxValidatorPercentage(uint16 validatorId) external view returns (uint256);

    // External Functions
    function submitForValidator(uint16 validatorId) external payable;
    function getNextValidator(uint256 depositAmount, uint16 validatorId) external view returns (uint256 validatorId_, uint256 capacity_);
    function rebalance() external;
    function unstake(uint256 amount) external returns (uint256 amountUnstaked);
    function unstakeFromValidator(uint256 amount, uint16 validatorId) external returns (uint256 amountUnstaked);
    function restake(uint16 validatorId) external returns (uint256 amountRestaked);
    function unstakeGov(uint16 validatorId, uint256 amount) external returns (uint256 amountRestaked);
    function withdrawGov(uint256 amount) external returns (uint256 amountRestaked);
    function stakeWitheld(uint256 amount) external returns (uint256 amountRestaked);
    function withdrawFee() external returns (uint256 amount);
    function withdraw(address recipient) external returns (uint256 amount);
    function stakeInfo() external view returns (PlumeStakingStorage.StakeInfo memory);
    function totalAmountClaimable() external view returns (uint256 amount);
    function getRewardRate() external view returns (uint256 rate);
    function getClaimableReward() external view returns (uint256 amount);
    function claim(uint16 validatorId) external returns (uint256 amount);
    function loadRewards() external payable returns (uint256 amount);
    function claimAll() external returns (uint256 amount);
    function handleTokenTransfer(address user) external;
    function getUserRewards(address user) external view returns (uint256 yield);
    function unstakeRewards() external returns (uint256 yield);
    function getYield() external view returns (uint256);
    function normalizedAmount(address user, uint256 amount) external view returns (uint256);
    function getValidatorStats(uint16 validatorId) external view returns (bool active, uint256 commission, uint256 totalStaked, uint256 stakersCount);
    function getUserValidators(address user) external view returns (uint16[] memory validatorIds);
    function syncRewards() external;
    function setYieldFee(uint256 newFee) external;
    function setRedemptionFees(uint256 newInstantFee, uint256 newStandardFee) external;
    function setRewardsCycleLength(uint32 newLength) external;
    function setMinStake(uint256 _minStake) external;
    function setMaxValidatorPercentage(uint256 _validatorId, uint256 _maxPercentage) external;
}