// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

// ====================================================================
// |                        Plume stPlumeMinter                       |
// ====================================================================
// Extension of frxETHMinter that adds staking functionality

import "./frxETHMinter.sol";
import { IPlumeStaking } from "./interfaces/IPlumeStaking.sol";
import { PlumeStakingStorage } from "./interfaces/PlumeStakingStorage.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/access/AccessControl.sol";

/// @title stPlumeMinter - Enhanced frxETHMinter with staking capabilities
/// @notice Extends frxETHMinter to add unstaking, restaking, and reward management
contract stPlumeMinter is frxETHMinter, AccessControl {
    // Role definitions
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 public constant CLAIMER_ROLE = keccak256("CLAIMER_ROLE");
    uint256 public WITHHOLD_FEE = 100; // 1%
    uint256 public withHoldEth;
    
    struct WithdrawalRequest {
        uint256 amount;
        uint256 timestamp;
    }

    address nativeToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    mapping(address => WithdrawalRequest) public withdrawalRequests;
    IPlumeStaking plumeStaking;
    // Events
    event Unstaked(address indexed user, uint256 amount);
    event Restaked(address indexed user, uint16 indexed validatorId, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, address indexed token, uint256 amount);
    event AllRewardsClaimed(address indexed user, uint256 totalAmount);
    event ValidatorRewardClaimed(address indexed user, address indexed token, uint16 indexed validatorId, uint256 amount);

    constructor(
        address frxETHAddress, 
        address sfrxETHAddress, 
        address _owner, 
        address _timelock_address,
        address _plumeStaking
    ) frxETHMinter(address(0), frxETHAddress, sfrxETHAddress, _owner, _timelock_address) {
        plumeStaking = IPlumeStaking(_plumeStaking);

        _setupRole(DEFAULT_ADMIN_ROLE, _owner);
        _setupRole(REBALANCER_ROLE, _owner);
        _setupRole(CLAIMER_ROLE, _owner);
    }

    /// @notice Get the next validator to deposit to
    function getNextValidator(uint depositAmount) public returns (uint256 validatorId, uint256 capacity) {
        // Make sure there are free validators available
        uint numVals = numValidators();
        require(numVals != 0, "Validator stack is empty");

        for (uint256 i = 0; i < numVals; i++) {
            validatorId = validators[i].validatorId;
            if(validatorId == 0) break;
            (bool active, , , ) = plumeStaking.getValidatorStats(uint16(validatorId));

            if (!active) continue;
            (PlumeStakingStorage.ValidatorInfo memory info,uint256 totalStaked , ) = plumeStaking.getValidatorInfo(uint16(validatorId));
                
            if (info.maxCapacity != 0 || totalStaked < info.maxCapacity) {
                return (validatorId, info.maxCapacity - totalStaked);
            }

            if(info.maxCapacity == 0){
                return (validatorId, type(uint256).max-1);
            }
        }

        revert("No validator with sufficient capacity");
    }

    /// @notice Rebalance the contract
    function rebalance() external nonReentrant onlyRole(REBALANCER_ROLE)  {
        _rebalance();
    }

    /// @notice Unstake the specified amount from a validator
    function unstake(uint256 amount) external nonReentrant returns (uint256 amountUnstaked) {
        _rebalance();
        frxETHToken.minter_burn_from(msg.sender, amount);
        require(withdrawalRequests[msg.sender].amount == 0, "Withdrawal already requested");
        uint256 cooldownTimestamp;
    
        // Check if we can cover this with withheld ETH
        if (currentWithheldETH >= amount) {
            amountUnstaked = amount;
            cooldownTimestamp = block.timestamp + 1 days;
        }else{
            uint256 remainingToUnstake = amount;
            amountUnstaked = 0;
            if (currentWithheldETH > 0) {
                amountUnstaked = currentWithheldETH;
                remainingToUnstake -= currentWithheldETH;
                currentWithheldETH = 0;
            }

            uint16 validatorId = 1;
            uint numVals = numValidators();
            while (remainingToUnstake > 0 && validatorId <= numVals) {
                (bool active, ,uint256 stakedAmount,) = plumeStaking.getValidatorStats(uint16(validatorId));
                
                if (active && stakedAmount > 0) {
                    // Calculate how much to unstake from this validator
                    uint256 unstakeFromValidator = remainingToUnstake > stakedAmount ? stakedAmount : remainingToUnstake;
                    uint256 actualUnstaked = plumeStaking.unstake(validatorId, unstakeFromValidator);
                    amountUnstaked += actualUnstaked;
                    remainingToUnstake -= actualUnstaked;
                    if (remainingToUnstake == 0) break;
                }
                validatorId++;
                require(validatorId <= 10, "Too many validators checked");
            }
            cooldownTimestamp = plumeStaking.cooldownEndDate();
        }
        require(amountUnstaked > 0, "No funds were unstaked");
        require(amountUnstaked >= amount, "Not enough funds unstaked");
        withdrawalRequests[msg.sender] = WithdrawalRequest({
            amount: amountUnstaked,
            timestamp: cooldownTimestamp
        });
        
        emit Unstaked(msg.sender, amountUnstaked);
        return amountUnstaked;
    }

    /// @notice Restake from cooling/parked funds to a specific validator
    function restake(uint16 validatorId) external nonReentrant returns (uint256 amountRestaked) {
        _rebalance();
        (PlumeStakingStorage.StakeInfo memory info) = plumeStaking.stakeInfo(address(this));
        amountRestaked = plumeStaking.restake(validatorId, info.cooled + info.parked);
        
        emit Restaked(address(this), validatorId, amountRestaked);
        return amountRestaked;
    }

    /// @notice Restake from cooling/parked funds to a specific validator
    function stakeWitheld(uint16 validatorId, uint256 amount) external nonReentrant onlyRole(REBALANCER_ROLE) returns (uint256 amountRestaked) {
        _rebalance();
        currentWithheldETH -= amount;
        depositEther(amount);
        
        emit ETHSubmitted(address(this), address(this), amount, 0);
        return amount;
    }

    /// @notice Withdraw withheld ETH
    function withdrawFee() external nonReentrant onlyByOwnGov returns (uint256 amount) {
        _rebalance();
        address(owner).call{value: withHoldEth}("");
        amount = withHoldEth;
        withHoldEth = 0;
        return amount;
    }

    /// @notice Withdraw available funds that have completed cooling
    function withdraw(address recipient) external nonReentrant returns (uint256 amount) {
        _rebalance();
        WithdrawalRequest storage request = withdrawalRequests[msg.sender];
        uint256 totalWithdrawable = plumeStaking.amountWithdrawable() + currentWithheldETH;
        require(block.timestamp >= request.timestamp, "Cooldown not complete");
        require(totalWithdrawable > 0, "Withdrawal not available yet");

        amount = request.amount;
        uint256 withdrawn;
        request.amount = 0;
        request.timestamp = 0;

        if(amount > currentWithheldETH ){
            withdrawn = plumeStaking.withdraw();
            currentWithheldETH = 0;
        } else {
            withdrawn = amount;
            currentWithheldETH -= amount;
        }

        withdrawn = withdrawn>amount ? withdrawn :amount; //fees could be taken by staker contract so that less than requested amount is sent
        uint256 withholdFee = amount * WITHHOLD_FEE / 10000;
        currentWithheldETH += withdrawn - amount ; //keep the rest of the funds for the rest of users that might have unstaked to avoid gas loss to unstake, withdraw but fees are taken by staker too so recognize that
        uint256 cachedAmount = withdrawn>amount ? amount :withdrawn;
        amount -= withholdFee;
        withHoldEth += cachedAmount - amount;

        address(recipient).call{value: amount}(""); //send amount to user
        emit Withdrawn(msg.sender, amount);
        return amount;
    }

    /// @notice Set the withhold fee
    function setWithholdFee(uint256 _withholdFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        WITHHOLD_FEE = _withholdFee;
    }

    /// @notice Get global staking information
    function stakingInfo() external view returns (uint256 totalStaked, uint256 totalCooling, uint256 totalWithdrawable, uint256 minStakeAmount, address[] memory rewardTokens) {
        return plumeStaking.stakingInfo();
    }

    /// @notice Get stake information for a specific user
    function stakeInfo() external view returns (PlumeStakingStorage.StakeInfo memory) {
        return plumeStaking.stakeInfo(address(this));
    }

    /// @notice Get the total amount claimable across all users for a specific token
    function totalAmountClaimable() external view returns (uint256 amount) {
        return plumeStaking.totalAmountClaimable(nativeToken);
    }

    /// @notice Get the reward rate for a specific token
    function getRewardRate() external view returns (uint256 rate) {
        return plumeStaking.getRewardRate(nativeToken);
    }

    /// @notice Get the claimable reward amount for a user and token
    function getClaimableReward() external view returns (uint256 amount) {
        return plumeStaking.getClaimableReward(address(this), nativeToken);
    }

    /// @notice Claim rewards for a specific token from a specific validator
    function claim(uint16 validatorId) external nonReentrant onlyRole(CLAIMER_ROLE)  returns (uint256 amount) {
        amount = plumeStaking.claim(nativeToken, validatorId);
        currentWithheldETH += amount;
        
        emit ValidatorRewardClaimed(address(this), nativeToken, validatorId, amount);
        return amount;
    }

    /// @notice Claim all available rewards from all tokens and validators
    function claimAll() external nonReentrant onlyRole(CLAIMER_ROLE)  returns (uint256 totalAmount) {
        uint256 amounts = plumeStaking.claimAll();
        currentWithheldETH += amounts;
        
        emit AllRewardsClaimed(address(this), totalAmount);
        return totalAmount;
    }

    /// @notice Get validator statistics
    function getValidatorStats(uint16 validatorId) external view returns (bool active, uint256 commission, uint256 totalStaked, uint256 stakersCount) {
        return plumeStaking.getValidatorStats(validatorId);
    }

    /// @notice Get the list of validators a user has staked with
    function getUserValidators(address user) external view returns (uint16[] memory validatorIds) {
        return plumeStaking.getUserValidators(user);
    }

    //// internal functions

    /// @notice Deposit ETH to validators, splitting across multiple if needed
    function depositEther(uint256 _amount) internal returns (uint256 depositedAmount) {
        // Initial pause check
        require(!depositEtherPaused, "Depositing ETH is paused");
        require(_amount > 0, "Amount must be greater than 0");
        uint256 remainingAmount = _amount;
        depositedAmount = 0;

        if(remainingAmount < plumeStaking.getMinStakeAmount()){
            currentWithheldETH += remainingAmount;
            return 0;
        }
    
        while (remainingAmount > 0) {
            uint256 depositSize = remainingAmount;
            (uint256 validatorId, uint256 capacity) = getNextValidator(remainingAmount);

            if(capacity < depositSize) {
                depositSize = capacity;
            }
            
            plumeStaking.stake{value: depositSize}(uint16(validatorId));
            remainingAmount -= depositSize;
            depositedAmount += depositSize;
            
            emit DepositSent(uint16(validatorId));
        }
        
        return depositedAmount;
    }

    /// @notice Rebalance the contract
    function _rebalance() internal {
        uint256 amount = _claim();
        frxETHToken.minter_mint(address(this), amount);
        frxETHToken.transfer(address(sfrxETHToken), amount);
        depositEther(address(this).balance);
    }

    /// @notice Submit ETH to the contract
    function _submit(address recipient) internal override returns (uint256 amount) {
        amount = super._submit(recipient);
        depositEther(amount);
    }

    /// @notice Claim rewards for a specific token across all validators
    function _claim() internal returns (uint256 amount) {
        amount = plumeStaking.claim(nativeToken);
        
        emit RewardClaimed(address(this), nativeToken, amount);
        return amount;
    }

    receive() external payable override {
        if(msg.sender != address(plumeStaking)) {
            _submit(msg.sender);
        }
    }
}