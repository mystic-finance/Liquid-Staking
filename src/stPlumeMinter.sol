// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

// ====================================================================
// |                        Plume stPlumeMinter                       |
// ====================================================================
// Extension of frxETHMinter that adds staking functionalit

import {frxETHMinter} from "./frxETHMinter.sol";
import {IstPlumeRewards} from "./interfaces/IstPlumeRewards.sol";
import { IPlumeStaking } from "./interfaces/IPlumeStaking.sol";
import { PlumeStakingStorage } from "./interfaces/PlumeStakingStorage.sol";
// import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol";
// import {IstPlumeMinter} from "./interfaces/IStPlumeMinter.sol";

/// @title stPlumeMinter - Enhanced frxETHMinter with staking capabilities
/// @notice Extends frxETHMinter to add unstaking, restaking, and reward management
contract stPlumeMinter is AccessControlUpgradeable, frxETHMinter {
    // Role definitions
    bytes32 constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 constant CLAIMER_ROLE = keccak256("CLAIMER_ROLE");
    bytes32 constant HANDLER_ROLE = keccak256("HANDLER_ROLE");
    uint256 public REDEMPTION_FEE; // 0.015%
    uint256 public INSTANT_REDEMPTION_FEE; // 0.5%
    uint256 public minStake;
    uint256 public withHoldEth;
    uint256 public withdrawalQueueThreshold;
    uint256 public batchUnstakeInterval;
    uint256 public totalInstantUnstaked;
    uint256 public totalUnstaked;

    struct WithdrawalRequest {
        uint256 amount;
        uint256 deficit;
        uint256 timestamp;
        uint256 createdTimestamp;
    }

    address public nativeToken;
    mapping(address => WithdrawalRequest) public withdrawalRequests;
    mapping (uint16 => uint256) public maxValidatorPercentage;
    mapping (uint16 => uint256) public totalQueuedWithdrawalsPerValidator;
    mapping (uint16 => uint256) public nextBatchUnstakeTimePerValidator;
    IPlumeStaking public plumeStaking;
    IstPlumeRewards stPlumeRewards;
    uint256[50] private __gap;
    
    // Events
    event Unstaked(address indexed user, uint256 amount);
    event Restaked(address indexed user, uint16 indexed validatorId, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, address indexed token, uint256 amount);
    event AllRewardsClaimed(address indexed user, uint256[] totalAmount);
    event ValidatorRewardClaimed(address indexed user, address indexed token, uint16 indexed validatorId, uint256 amount);
    
    constructor() frxETHMinter(address(0), address(0), address(0), address(0), address(0)) {
        _disableInitializers();
    }

    function initialize(address frxETHAddress, address _owner, address _timelock_address, address _plumeStaking) public initializer {
        __AccessControl_init();
        _frxethminter_init(address(0), frxETHAddress, address(0), _owner, _timelock_address);
        plumeStaking = IPlumeStaking(_plumeStaking);
        _setupRole(DEFAULT_ADMIN_ROLE, _owner);
        _setupRole(REBALANCER_ROLE, _owner);
        _setupRole(CLAIMER_ROLE, _owner);
        _setupRole(HANDLER_ROLE, frxETHAddress);

        // setting state
        REDEMPTION_FEE = 150; // 0.015%
        INSTANT_REDEMPTION_FEE = 5000; // 0.5%
        minStake = 1e17;
        withdrawalQueueThreshold = 100000 ether;
        batchUnstakeInterval = 21 days + 1 hours;
        nativeToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    }

    function addValidator(Validator calldata validator) public override onlyByOwnGov {
        require(!_checkValidator(uint256(validator.validatorId)), "Validator already exists");
        validators.push(validator);
        nextBatchUnstakeTimePerValidator[uint16(validator.validatorId)] = block.timestamp + plumeStaking.getCooldownInterval();
        emit ValidatorAdded(validator.validatorId, bytes(""));
    }

    function submitForValidator(uint16 validatorId) external payable {
        require(_checkValidator(uint256(validatorId)), "Validator does not exist");
        _submit(msg.sender, validatorId);
    }
    
    /// @notice Get the next validator to deposit to
    function getNextValidator(uint256 depositAmount, uint16 validatorId) internal view returns (uint256 validatorId_, uint256 capacity_) {
        require(validatorId != 0, "Validator does not exist");
        (bool active, , uint256 stakedAmount, ) = plumeStaking.getValidatorStats(uint16(validatorId));
        uint256 totalStaked = plumeStaking.totalAmountStaked();

        if (!active) return (validatorId, 0);
        (, capacity_) = _getValidatorInfo(uint16(validatorId));
        uint256 percentage = (stakedAmount + depositAmount) * RATIO_PRECISION / totalStaked;
        if(maxValidatorPercentage[validatorId]>0 && percentage > maxValidatorPercentage[validatorId]){
            return (validatorId, 0);
        }

        if(capacity_ > 0){
            return (validatorId, capacity_);
        }
        return (validatorId, 0);
    }

    /// @notice Rebalance the contract
    function rebalance() external nonReentrant onlyRole(REBALANCER_ROLE)  {
        _rebalance();
    }

    /// @notice Unstake the specified amount from a validator
    function unstake(uint256 amount) external nonReentrant returns (uint256 amountUnstaked) {
        amountUnstaked =  _unstakeFromValidator(amount, 0);
        return amountUnstaked;
    }

    function unstakeFromValidator(uint256 amount, uint16 validatorId) external nonReentrant returns (uint256 amountUnstaked) {
        require(_checkValidator(uint256(validatorId)), "Validator does not exist");
        amountUnstaked =  _unstakeFromValidator(amount, validatorId);
        return amountUnstaked;
    }

    function _unstakeFromValidator(uint256 amount, uint16 validatorId) internal returns (uint256 amountUnstaked) {
        _rebalance();
        require(amount >= minStake, "not enough to unstake");
        amountUnstaked =  _unstake(amount, false, validatorId);
        return amountUnstaked;
    }

    /// @notice Restake from cooling/parked funds to a specific validator
    function restake(uint16 validatorId) external nonReentrant onlyRole(REBALANCER_ROLE) returns (uint256 amountRestaked) {
        _rebalance();
        require(_checkValidator(uint256(validatorId)), "Validator does not exist");
        IPlumeStaking.CooldownView memory cooldown = _getCoolDownPerValidator(uint16(validatorId));
        if(cooldown.amount == 0){return 0;}
        plumeStaking.restake(validatorId, cooldown.amount);
        emit Restaked(address(this), validatorId, cooldown.amount);
        return cooldown.amount;
    }

    function unstakeGov(uint16 validatorId, uint256 amount) external nonReentrant onlyByOwnGov returns (uint256 amountRestaked) {
        _rebalance();
        (bool active, ,uint256 stakedAmount,) = plumeStaking.getValidatorStats(uint16(validatorId));
        
        if (active && stakedAmount > 0 && stakedAmount >= amount) {
            amountRestaked = plumeStaking.unstake(uint16(validatorId), amount);
        }
    }

    function withdrawGov() external nonReentrant onlyByOwnGov returns (uint256 amountWithdrawn) {
        _rebalance();
        uint256 balanceBefore = address(this).balance;
        plumeStaking.withdraw();
        uint256 balanceAfter = address(this).balance;
        currentWithheldETH += balanceAfter - balanceBefore;
        amountWithdrawn = balanceAfter - balanceBefore;
    }

    /// @notice Restake from withheld funds
    function stakeWitheld(uint256 amount) external nonReentrant onlyRole(REBALANCER_ROLE) returns (uint256 amountRestaked) {
        return _stakeWitheldForValidator(amount, 0);
    }

    function stakeWitheldForValidator(uint256 amount, uint16 validatorId) public nonReentrant onlyRole(REBALANCER_ROLE) returns (uint256 amountRestaked) {
        return _stakeWitheldForValidator(amount, validatorId);
    }

    function _stakeWitheldForValidator(uint256 amount, uint16 validatorId) internal returns (uint256 amountRestaked) {
        _rebalance();
        require(currentWithheldETH >= amount + totalInstantUnstaked, "Guardrails failed, not enough idle funds");
        currentWithheldETH -= amount;
        _depositEther(amount, validatorId);
        
        emit ETHSubmitted(address(this), address(this), amount, validatorId);
        return amount;
    }

    /// @notice Withdraw protocol fee
    function withdrawFee() external nonReentrant onlyByOwnGov returns (uint256 amount) {
        _rebalance();
        (bool success,) = address(owner).call{value: withHoldEth}("");
        require(success, "Withdrawal failed");
        amount = withHoldEth;
        withHoldEth = 0;
        return amount;
    }

    function withdraw(address recipient) external nonReentrant returns (uint256 amount) {
        _rebalance();
        WithdrawalRequest storage request = withdrawalRequests[msg.sender];
        require(block.timestamp >= request.timestamp, "Cooldown not complete");
        require(request.amount > 0, "Non Zero Amount for Withdrawal");

        if(request.timestamp == request.createdTimestamp){
            return _instantWithdraw(recipient);
        }else{
            return _withdraw(recipient);
        }
    }

    function _instantWithdraw(address recipient) internal returns (uint256 amount) {
        WithdrawalRequest storage request = withdrawalRequests[msg.sender];
        uint256 totalWithdrawable = currentWithheldETH;
        require(totalWithdrawable > 0, "Withdrawal not available yet");

        uint256 totalAmount = request.amount + request.deficit;
        require(totalAmount > 0, "Non Zero Amount for Instant Withdrawal");
        require(totalAmount <= totalWithdrawable, "Full withdrawal not available yet");
        require(totalAmount <= totalInstantUnstaked, "Full withdrawal not available yet");

        uint fee = totalAmount * INSTANT_REDEMPTION_FEE / RATIO_PRECISION;
        request.amount = 0; request.timestamp = 0; request.deficit = 0;
        totalInstantUnstaked -= totalAmount;
        currentWithheldETH -= totalAmount;
        totalUnstaked -= totalAmount;

        uint amountToWithdraw = totalAmount - fee;
        withHoldEth += fee;

        (bool success,) = address(recipient).call{value: amountToWithdraw}(""); //send amount to user
        require(success, "Withdrawal failed");
        emit Withdrawn(msg.sender, amountToWithdraw);
        return amountToWithdraw;
    }

    /// @notice Withdraw available funds that have completed cooling
    function _withdraw(address recipient) internal returns (uint256 amount) {
        WithdrawalRequest storage request = withdrawalRequests[msg.sender];
        uint256 totalWithdrawable = plumeStaking.amountWithdrawable();
        require(totalWithdrawable + totalInstantUnstaked > 0, "Withdrawal not available yet");

        amount = request.amount;
        uint withdrawn = 0;
        uint256 totalAmount = amount + request.deficit;
        require(totalAmount > 0, "Non Zero Amount for Withdrawal");
        require(totalAmount <= totalWithdrawable + totalInstantUnstaked, "Full withdrawal not available yet");
        uint fee = totalAmount * REDEMPTION_FEE / RATIO_PRECISION;
        request.amount = 0; request.timestamp = 0; request.deficit = 0;

        if(totalWithdrawable > 0){
            uint256 balanceBefore = address(this).balance;
            plumeStaking.withdraw();
            uint256 balanceAfter = address(this).balance;
            withdrawn = balanceAfter - balanceBefore;
        }
        withHoldEth += fee;
        currentWithheldETH += withdrawn;
        totalInstantUnstaked += withdrawn;
        
        if(withdrawn > 0 && withdrawn < amount){
            require(amount-withdrawn < fee, "Insufficient funds to cover deficit");
            currentWithheldETH += amount - withdrawn; // net must be > 0
            totalInstantUnstaked += amount - withdrawn; // fill up also to cover underflow
            withHoldEth -= amount - withdrawn; // reduce fee since some covered by withdrawal fee
        }
        // at this junture withdraw + x(extra fee) >= amount, deficit can only be taken from currentWithHeldEth
        require(totalInstantUnstaked >= totalAmount, "Not enough to fulfill withdrawal at the moment");
        require(totalInstantUnstaked <= currentWithheldETH, "Not enough to fulfill withdrawal at the moment");

        currentWithheldETH -= totalAmount;
        totalInstantUnstaked -= totalAmount;
        uint amountToWithdraw = totalAmount - fee;
        totalUnstaked -= totalAmount;

        (bool success,) = address(recipient).call{value: amountToWithdraw}(""); //send amount to user
        require(success, "Withdrawal failed");
        emit Withdrawn(msg.sender, amountToWithdraw);
        return amountToWithdraw;
    }

    /// @notice Get the claimable reward amount for a user and token
    function getClaimableReward() public returns (uint256 amount) {
        return plumeStaking.getClaimableReward(address(this), nativeToken);
    }

    /// @notice Claim rewards for a specific token from a specific validator
    function claim(uint16 validatorId) external nonReentrant onlyRole(CLAIMER_ROLE)  returns (uint256 amount) {
        if(getClaimableReward() == 0){return 0;}
        amount = plumeStaking.claim(nativeToken, validatorId);
        _loadRewards(amount);
        
        emit ValidatorRewardClaimed(address(this), nativeToken, validatorId, amount);
        return amount;
    }

    function loadRewards() payable external nonReentrant onlyByOwnGov returns (uint256 amount) {
        amount = msg.value;
        _loadRewards(amount);
        return amount;
    }

    function claimAll() external nonReentrant onlyRole(CLAIMER_ROLE)  returns (uint256[] memory amounts) {
        amounts = plumeStaking.claimAll();
        address[] memory tokens = plumeStaking.getRewardTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 amount = amounts[i];
            if(amount > 0 && token == nativeToken){
                _loadRewards(amount);
            }
            // otherwise, let the erc20 tokens go to the contract, we will withdraw with rescue token, convert to native token and load rewards
        }
        emit AllRewardsClaimed(address(this), amounts);
        return amounts;
    }

    /// @notice Unstake rewards
    function unstakeRewards() external nonReentrant returns (uint256 yield) {
        _rebalance();
        stPlumeRewards.syncUser(msg.sender); //sync rewards first
        yield = stPlumeRewards.getUserRewards(msg.sender);
        
        if(yield == 0){return 0;}
        _unstake(yield, true, 0);

        stPlumeRewards.resetUserRewardsAfterClaim(msg.sender);
        require(stPlumeRewards.getUserRewards(msg.sender) == 0, "Rewards should be reset after unstaking");
        return yield;
    }

    function processBatchUnstake() external {
        uint numVals = numValidators();
        uint256 index = 0;
        require(numVals != 0, "Validator stack is empty");
        while (index < numVals) {
            uint16 validatorId = uint16(validators[index].validatorId);
            if (totalQueuedWithdrawalsPerValidator[validatorId] >= withdrawalQueueThreshold || block.timestamp >= nextBatchUnstakeTimePerValidator[validatorId]) {
                _processBatchUnstake(validatorId);
            }
            index++;
        }
    }

    function _loadRewards (uint256 amount) internal {
        if(amount > 0){
            stPlumeRewards.loadRewards{value: amount}();
        }
    }

    function _getValidatorInfo(uint16 validatorId) internal view returns (uint256, uint256 capacity) {
        (PlumeStakingStorage.ValidatorInfo memory info,uint256 totalStaked , ) = plumeStaking.getValidatorInfo(uint16(validatorId));
        if(info.maxCapacity == 0){
            return (validatorId, type(uint256).max-1);
        }

        if (info.maxCapacity != 0 && totalStaked < info.maxCapacity) {
            uint remainingAmount = info.maxCapacity - totalStaked;
            if(remainingAmount >= minStake){ // the rewards is expected to be less than minStakeAmount, which means address(this).balance is added to currentWithheldETH, almost everytime
                return (validatorId, remainingAmount);
            }     
        }
        return (validatorId, 0);
    }

    //// internal functions
    /// @notice Deposit ETH to validators, splitting across multiple if needed
    function _depositEther(uint256 _amount, uint16 _validatorId) internal returns (uint256 depositedAmount) {
        // Initial pause check
        require(!depositEtherPaused, "Depositing ETH is paused");
        uint256 remainingAmount = _amount;
        uint256 minStakeAmount = minStake;
        depositedAmount = 0;

        if(remainingAmount < minStakeAmount){ // the rewards is expected to be less than minStakeAmount, which means address(this).balance is added to currentWithheldETH, almost everytime
            currentWithheldETH += remainingAmount;
            return 0;
        }

        if(_validatorId != 0){
            (uint256 validatorId, uint256 capacity) = _getValidatorInfo(_validatorId);
            if(capacity > 0){
                require(_amount <= capacity, "Validator capacity is not sufficient");
                plumeStaking.stake{value: _amount}(uint16(validatorId)); //stake stops 0 capacity from coming into here to cause infinite loops
                remainingAmount -= _amount;
                depositedAmount += _amount;
                emit DepositSent(uint16(validatorId));
            }
            require(remainingAmount == 0, "No validator with sufficient capacity to fulfill all deposit amount");
            return depositedAmount;
        }

        uint numVals = numValidators();
        uint256 index = 0;
        require(numVals != 0, "Validator stack is empty");
        while (remainingAmount > 0 && index < numVals) {
            uint256 depositSize = remainingAmount;
            _validatorId = uint16(validators[index].validatorId);
            (uint256 validatorId, uint256 capacity) = getNextValidator(remainingAmount, _validatorId);
            if(capacity == 0 || capacity < minStakeAmount) continue;
            
            if(capacity < depositSize) {
                depositSize = capacity;
            }

            if(depositSize < minStakeAmount){
                currentWithheldETH += remainingAmount; // depositSize should be from user dposit size here not capacity because it should have skipped if capacity < minstakeAmount
                return depositedAmount;
            }
            
            plumeStaking.stake{value: depositSize}(uint16(validatorId)); //stake stops 0 capacity from coming into here to cause infinite loops
            remainingAmount -= depositSize;
            depositedAmount += depositSize;
            index++;
            emit DepositSent(uint16(validatorId));
        }
        require(remainingAmount == 0, "No validator with sufficient capacity to fulfill all deposit amount");
        
        return depositedAmount;
    }

    function _getCoolDownPerValidator(uint16 validatorId) internal view returns (IPlumeStaking.CooldownView memory cooldown){
        IPlumeStaking.CooldownView[] memory cooldowns = plumeStaking.getUserCooldowns(address(this));
        for(uint256 i = 0; i < cooldowns.length; i++){
            if(cooldowns[i].validatorId == validatorId){
                cooldown = cooldowns[i];
                break;
            }
        }
        return cooldown;
    }

    function _unstake(uint256 amount, bool rewards, uint16 _validatorId) internal returns (uint256 amountUnstaked) {
        require(amount > 0, "Amount must be greater than 0");
        if(!rewards){
            frxETHToken.minter_burn_from(msg.sender, amount); //reduce burnt shares by yield available to claim
        }
        uint256 cooldownTimestamp;
        uint256 deficit;
        require(withdrawalRequests[msg.sender].amount == 0, "Withdrawal already requested");
    
        // Check if we can cover this with withheld ETH
        if (currentWithheldETH >= amount && currentWithheldETH >= amount + totalInstantUnstaked) { //instant redemption
            amountUnstaked = amount;
            cooldownTimestamp = block.timestamp;
            totalInstantUnstaked += amount;
        }else{
            uint256 remainingToUnstake = amount;
            amountUnstaked = 0;

            if(_validatorId != 0){
                (bool active, ,uint256 stakedAmount,) = plumeStaking.getValidatorStats(uint16(_validatorId));
                uint256 validatorStakedAmount = plumeStaking.getUserValidatorStake(address(this), uint16(_validatorId));
                uint256 remainingUnstaked = validatorStakedAmount - totalQueuedWithdrawalsPerValidator[_validatorId];
                require(active && stakedAmount >= validatorStakedAmount && remainingUnstaked + currentWithheldETH - totalInstantUnstaked >= remainingToUnstake, "Validator cannot fulfill the unstake request");
                
                uint256 unstakeAmountFromValidator = remainingToUnstake > remainingUnstaked ? remainingUnstaked : remainingToUnstake;
                totalQueuedWithdrawalsPerValidator[_validatorId] += unstakeAmountFromValidator; //new
                amountUnstaked += unstakeAmountFromValidator;
                remainingToUnstake -= unstakeAmountFromValidator;
                
                if (totalQueuedWithdrawalsPerValidator[_validatorId] >= withdrawalQueueThreshold || block.timestamp >= nextBatchUnstakeTimePerValidator[_validatorId]) {
                    _processBatchUnstake(_validatorId);
                }
                cooldownTimestamp = plumeStaking.getCooldownInterval() + nextBatchUnstakeTimePerValidator[_validatorId];
            }

            uint16 index = 0;
            uint numVals = numValidators();
            while (index < numVals && _validatorId == 0) {
                uint256 validatorId = validators[index].validatorId;
                require(validatorId > 0, "Validator does not exist");
                (bool active, ,uint256 stakedAmount,) = plumeStaking.getValidatorStats(uint16(validatorId));
                uint256 validatorStakedAmount = plumeStaking.getUserValidatorStake(address(this), uint16(validatorId));
                uint256 remainingUnstaked = validatorStakedAmount - totalQueuedWithdrawalsPerValidator[uint16(validatorId)];
                
                if (active && stakedAmount > 0 && validatorStakedAmount > 0 && validatorStakedAmount <= stakedAmount && remainingUnstaked > 0 ) {
                    // Calculate how much to unstake from this validator
                    uint256 unstakeAmountFromValidator = remainingToUnstake > remainingUnstaked ? remainingUnstaked : remainingToUnstake;
                    totalQueuedWithdrawalsPerValidator[uint16(validatorId)] += unstakeAmountFromValidator; //new
                    amountUnstaked += unstakeAmountFromValidator;
                    remainingToUnstake -= unstakeAmountFromValidator;

                    if (totalQueuedWithdrawalsPerValidator[uint16(validatorId)] >= withdrawalQueueThreshold || block.timestamp >= nextBatchUnstakeTimePerValidator[uint16(validatorId)]) {
                        _processBatchUnstake(uint16(validatorId));
                    }

                    uint256 endTime = plumeStaking.getCooldownInterval() + nextBatchUnstakeTimePerValidator[uint16(validatorId)];
                    if(endTime > cooldownTimestamp){ // use the max timestamp as the cooldown timestamp
                        cooldownTimestamp = endTime;
                    }
                    if (remainingToUnstake == 0) break;
                }
                index++;
                require(index <= numVals, "Too many validators checked");
            }
            
            if (currentWithheldETH > 0 && amountUnstaked < amount) {
                deficit = amount - amountUnstaked;
                // amountUnstaked += deficit;
                remainingToUnstake -= deficit;
                totalInstantUnstaked += deficit;
                require(totalInstantUnstaked <= currentWithheldETH, "Insufficient funds to cover deficit");
            }
            require(remainingToUnstake == 0, "Not enough funds unstaked");
        }

        require(amountUnstaked > 0, "No funds were unstaked");
        require(amountUnstaked + deficit >= amount, "Not enough funds unstaked");
        withdrawalRequests[msg.sender] = WithdrawalRequest({
            amount: amountUnstaked,
            deficit: deficit,
            timestamp: cooldownTimestamp,
            createdTimestamp: block.timestamp
        });
        
        emit Unstaked(msg.sender, amountUnstaked);
        totalUnstaked += amountUnstaked + deficit;
        return amountUnstaked;
    }

    function _processBatchUnstake(uint16 validatorId) internal {
        if (totalQueuedWithdrawalsPerValidator[validatorId] == 0) return;
        
        // Calculate how much to unstake from validators
        uint256 amountToUnstake = totalQueuedWithdrawalsPerValidator[validatorId];
        // Only unstake from validators if necessary
        if (amountToUnstake > 0) {
            // Unstake from validators
            plumeStaking.unstake(validatorId, amountToUnstake);
        }
        
        // Reset the queue counter and set next batch time
        totalQueuedWithdrawalsPerValidator[validatorId] = 0;
        nextBatchUnstakeTimePerValidator[validatorId] = block.timestamp + batchUnstakeInterval;
    }

    /// @notice Rebalance the contract
    function _rebalance() internal {
        uint256 amount = _claim();
        _loadRewards(amount);
    }

    /// @notice Submit ETH to the contract
    function _submit(address recipient) internal override returns (uint256 amount) {
        return _submit(recipient, 0);
    }

    function _submit(address recipient, uint16 validatorId) internal returns (uint256 amount) {
        amount = super._submit(recipient);
        require(amount >= minStake, "not enough to stake");
        _depositEther(amount, validatorId);
        return amount;
    }

    /// @notice Claim rewards for a specific token across all validators
    function _claim() internal returns (uint256 amount) {
        // claim can revert at anytime
        if(getClaimableReward() < minStake){return 0;}
        try plumeStaking.claim(nativeToken) returns (uint256 claimedAmount) {
            amount = claimedAmount;
            emit RewardClaimed(address(this), nativeToken, amount);
        } catch {
            // If the claim reverts, return 0 and continue execution
            amount = 0;
        }
        return amount;
    }

    function _checkValidator (uint256 validatorId) internal view returns (bool validatorExists) {
        uint numVals = numValidators();
        for (uint256 i = 0; i < numVals; i++) {
            if (validators[i].validatorId == validatorId) {
                return true;
            }
        }
        return false;
    }

    function addWithHoldFee() external payable {
        require(msg.sender == address(stPlumeRewards), "Unauthorized");
        withHoldEth += msg.value;
    }

    function setFees(
        uint256 newInstantFee, 
        uint256 newStandardFee
    ) external onlyByOwnGov {
        require(newInstantFee <= 1000000 && newStandardFee <= 1000000, "Fees too high");
        INSTANT_REDEMPTION_FEE = newInstantFee;
        REDEMPTION_FEE = newStandardFee;
    }

    function setMinStake( uint256 _minStake) external onlyByOwnGov {
        require(_minStake >0 && _minStake >= plumeStaking.getMinStakeAmount(), "minimum stake too low");
        minStake = _minStake;
    }

    function setMaxValidatorPercentage(uint256 _validatorId, uint256 _maxPercentage) external onlyByOwnGov {
        require(_maxPercentage <= RATIO_PRECISION, "Invalid max percentage");
        maxValidatorPercentage[uint16(_validatorId)] = _maxPercentage;
    }

    function setBatchUnstakeParams(uint256 _threshold, uint256 _interval) external onlyByOwnGov {
        require(_threshold >= 1 ether, "Threshold too low");
        require(_interval >= 1 hours && _interval <= 365 days, "Invalid interval");
        withdrawalQueueThreshold = _threshold;
        batchUnstakeInterval = _interval;
    }

    function setStPlumeRewards(address _stPlumeRewards) external onlyByOwnGov {
        stPlumeRewards = IstPlumeRewards(_stPlumeRewards);
    }

    receive() external payable override {
        if(msg.sender == address(stPlumeRewards)){
            _depositEther(msg.value, 0);
            return;
        }

        if(msg.sender != address(plumeStaking.getTreasury()) && msg.sender != address(plumeStaking)) {
            // treasury for rewards, plume staking for withdrawals
            _submit(msg.sender);
        }
    }
}