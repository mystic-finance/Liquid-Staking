// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";

// ====================================================================
// |                      Plume stPlumeRewards                        |
// ====================================================================
// Reward management for stPlumeMinter
//not in scope of audit
import { IPlumeStaking } from "../interfaces/IPlumeStaking.sol";
import { IstPlumeRewards } from "../interfaces/IstPlumeRewards.sol";
import { IstPlumeMinter } from "../interfaces/IstPlumeMinter.sol";
import { frxETH } from "../frxETH.sol";
import { AccessControlUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";

/// @title stPlumeRewards - Reward system for the stPlumeMinter contract
/// @notice Handles all reward-related functionality for frxETH token holders
contract stPlumeRewards is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, IstPlumeRewards {
    // Role definitions
    bytes32 public constant CLAIMER_ROLE = keccak256("CLAIMER_ROLE");
    bytes32 public constant HANDLER_ROLE = keccak256("HANDLER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    
    // Fees
    uint256 public YIELD_FEE; // 10%
    uint256 public constant RATIO_PRECISION = 1e6;
    
    // Reward state
    uint256 public rewardRate;
    uint256 public rewardPerTokenStored;
    uint256 public yieldEth; // reward accrued + future next rewards
    uint256 public rewardsEth; // current rewards across cycles
    uint32 public rewardsCycleLength; // reward cycle length
    uint32 public lastSync;
    uint32 public rewardsCycleEnd;
    uint256 public lastRewardAmount; // reward in this unfinished cycle
    uint256 __gap1;
    uint256 __gap2;
    uint256 __gap3;
    
    CycleRewards[] public cycleRewards;
    mapping(address => UserRewards) public userRewards;
    
    // Contract references
    frxETH public frxETHToken;
    address public stPlumeMinter;
    
    // Events
    event RewardClaimed(address indexed user, address indexed token, uint256 amount);
    event AllRewardsClaimed(address indexed user, uint256[] totalAmount);
    event ValidatorRewardClaimed(address indexed user, address indexed token, uint16 indexed validatorId, uint256 amount);
    
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _frxETHToken,
        address _stPlumeMinter,
        address _admin
    ) public initializer{
        __ReentrancyGuard_init();
        frxETHToken = frxETH(_frxETHToken);
        stPlumeMinter = _stPlumeMinter;
        
        rewardsCycleLength = 7 days;
        rewardsCycleEnd = uint32(block.timestamp + rewardsCycleLength);
        YIELD_FEE = 100000;
        
        _setupRole(DEFAULT_ADMIN_ROLE, _admin);
        _setupRole(MINTER_ROLE, _admin);
        _setupRole(MINTER_ROLE, _stPlumeMinter);
        _setupRole(HANDLER_ROLE, _frxETHToken);
    }
    
    modifier onlyMinter() {
        require(hasRole(MINTER_ROLE, msg.sender), "Caller is not a minter");
        _;
    }
    
    /// @notice Load rewards from external sources
    function loadRewards() external payable onlyMinter returns (uint256 amount) {
        amount = msg.value;
        _loadRewards(amount);
        return amount;
    }
    
    /// @notice Internal function to distribute rewards
    function _loadRewards(uint256 amount) internal {
        if (amount > 0) {
            uint256 yieldAmount = amount * YIELD_FEE / RATIO_PRECISION;
            yieldEth += amount - yieldAmount;
            // Return the fee amount to the minter
            if (amount > 0) {
                IstPlumeMinter(stPlumeMinter).addWithHoldFee{value: yieldAmount}(); //send fee to protocol
                (bool success,) = stPlumeMinter.call{value: amount - yieldAmount}(""); // send rewards to be staked to earn more rewards
                require(success, "Rewards transfer failed");
            }
        }
        
        syncRewards();
    }

    function adminSyncUserRewardsCycles(address user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _handleTokenTransfer(user);
    }
    
    /// @notice Handle token transfer to track user rewards
    function handleTokenTransfer(address user) public onlyRole(HANDLER_ROLE) {
        _handleTokenTransfer(user);
    }

    function _handleTokenTransfer(address user) internal {
        if (user != address(0)) {
            uint256 balance = frxETHToken.balanceOf(user);
            rewardPerTokenStored = getYield();     
            userRewards[user].rewardsAccrued = getUserRewards(user); //rewards[account]
            userRewards[user].rewardsBefore = rewardPerTokenStored; //  rewards per  token paid
            userRewards[user].rewardInCycle = rewardPerTokenStored;
            userRewards[user].lastCycleClaimed = lastTimeRewardApplicable();
        }
    }
    
    /// @notice Get current rewards for a user
    function getUserRewards(address user) public view returns (uint256 yield) {
        uint256 balance = frxETHToken.balanceOf(user);
        return balance * (getYield() - userRewards[user].rewardsBefore) / 1e18 + userRewards[user].rewardsAccrued;
    }
    
    /// @notice Reset user rewards after claim
    function resetUserRewardsAfterClaim(address user) external onlyMinter {
        userRewards[user].rewardsBefore = getYield();
        userRewards[user].rewardsAccrued = 0;
        userRewards[user].rewardInCycle = rewardPerTokenStored;
        userRewards[user].lastCycleClaimed = lastTimeRewardApplicable();
    }

    /// @notice Sync rewards at the end of a cycle
    function syncRewards() nonReentrant public {
        // uint256 timestamp = block.timestamp;
        // require(timestamp >= rewardsCycleEnd, "Not in rewards cycle");
        // require(yieldEth >= rewardsEth, "Negative rewards");
    
        uint256 nextRewards = yieldEth - rewardsEth;
        rewardsEth += nextRewards;
         if (block.timestamp >= rewardsCycleEnd) {
            rewardRate = nextRewards * 1e18 / rewardsCycleLength;
        } else {
            uint256 remaining = rewardsCycleEnd - block.timestamp;
            uint256 leftover = remaining * rewardRate / 1e18;
            rewardRate = (nextRewards + leftover) * 1e18 / rewardsCycleLength;
        }
        uint256 end = block.timestamp + rewardsCycleLength;
        lastRewardAmount = nextRewards;
        lastSync = uint32(block.timestamp);
        rewardsCycleEnd = uint32(end);
    }
    
    /// @notice Set yield fee percentage
    function setYieldFee(uint256 newYieldFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newYieldFee <= 500000, "Fees too high");
        YIELD_FEE = newYieldFee;
    }
    
    /// @notice Set rewards cycle length
    function setRewardsCycleLength(uint32 newLength) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newLength >= 1 days && newLength <= 365 days, "Invalid cycle length");
        rewardsCycleLength = newLength;
    }
    
    /// @notice Get current total yield
    function getYield() public view returns (uint256) {
        uint256 maxTime = rewardsCycleEnd > block.timestamp ? block.timestamp : rewardsCycleEnd;
        uint256 totalSupply = frxETHToken.totalSupply();
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }
        
        return rewardPerTokenStored + 
            ((maxTime - lastSync) * rewardRate / totalSupply);
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < rewardsCycleEnd ? block.timestamp : rewardsCycleEnd;
    }
    
    receive() external payable {
        // Only accept ETH from the minter
        require(
            msg.sender == stPlumeMinter,
            "Unauthorized sender"
        );
    }
}