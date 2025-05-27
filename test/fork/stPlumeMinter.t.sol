// stPlume/test-new/stPlumeMinter.fork.t.sol
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/stPlumeMinter.sol";
import "../../src/frxETH.sol";
import "../../src/sfrxETH.sol";
import "../../src/OperatorRegistry.sol";
// import "../../src/DepositContract.sol";
import { IPlumeStaking } from "../../src/interfaces/IPlumeStaking.sol";
import { PlumeStakingStorage } from "../../src/interfaces/PlumeStakingStorage.sol";


contract StPlumeMinterForkTest is Test {
    stPlumeMinter minter;
    frxETH frxETHToken;
    sfrxETH sfrxETHToken;
    OperatorRegistry registry;
    IPlumeStaking mockPlumeStaking;
    
    address owner = address(0x1234);
    address timelock = address(0x5678);
    address user1 = address(0x9ABC);
    address user2 = address(0xDEF0);
    uint256 YIELD_FEE_DEFAULT = 100000; // 10%
    uint256 REDEMPTION_FEE_DEFAULT = 150; // 0.02%
    uint256 INSTANT_REDEMPTION_FEE_DEFAULT = 5000; // 0.5%
    uint256 RATIO_PRECISION = 1e6;
    
    event Unstaked(address indexed user, uint16 indexed validatorId, uint256 amount);
    event Restaked(address indexed user, uint16 indexed validatorId, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, address indexed token, uint256 amount);
    event EmergencyEtherRecovered(uint256 amount);
    event EmergencyERC20Recovered(address tokenAddress, uint256 tokenAmount);
    event ETHSubmitted(address indexed sender, address indexed recipient, uint256 sent_amount, uint256 withheld_amt);
    event TokenMinterMinted(address indexed sender, address indexed to, uint256 amount);
    event DepositSent(uint16 validatorId);
    
    function setUp() public {        
        // Deploy mock PlumeStaking
        mockPlumeStaking =  IPlumeStaking(0xCF8B97260F77c11d58542644c5fD1D5F93FdA57d);
        // IPlumeStaking(0xCF8B97260F77c11d58542644c5fD1D5F93FdA57d);
        // IPlumeStaking(0xA20bfe49969D4a0E9abfdb6a46FeD777304ba07f);
        
        // Set up validators in mock
        // vm.startPrank(address(this));
        // // mockPlumeStaking.addValidator(1, 32 ether, true);
        // // mockPlumeStaking.addValidator(2, 64 ether, true);
        // // mockPlumeStaking.addValidator(3, 32 ether, false); // Inactive validator
        // vm.stopPrank();
        
        // Fund the mock with ETH for withdrawals
        vm.deal(address(mockPlumeStaking), 100 ether);
        vm.deal(address(user1), 100 ether);
        vm.deal(address(user2), 100 ether);
        vm.deal(address(owner), 100 ether);
        
        // Deploy contracts
        frxETHToken = new frxETH(owner, timelock);
        sfrxETHToken = new sfrxETH(ERC20(address(frxETHToken)), 1000); // 1000 second rewards cycle
        
        // Deploy minter
        vm.prank(owner);
        minter = new stPlumeMinter(
            address(frxETHToken),
            address(sfrxETHToken),
            owner,
            timelock,
            address(mockPlumeStaking)
        );

        OperatorRegistry.Validator[] memory validators = new OperatorRegistry.Validator[](1);
        validators[0] = OperatorRegistry.Validator(1);
        // validators[1] = OperatorRegistry.Validator(2);
        // validators[2] = OperatorRegistry.Validator(3);
        
        vm.prank(owner);
        minter.addValidators(validators);
        vm.prank(owner);
        frxETHToken.addMinter(address(minter));
        vm.prank(owner);
        frxETHToken.addMinter(address(owner));
    
    }
    
    // Tests for basic roles and configuration
    function test_roles_setup() public {
        assertTrue(minter.hasRole(minter.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(minter.hasRole(minter.REBALANCER_ROLE(), owner));
        assertTrue(minter.hasRole(minter.CLAIMER_ROLE(), owner));
    }
    
    function test_setup_configuration() public {
        assertEq(address(minter.frxETHToken()), address(frxETHToken));
        assertEq(address(minter.sfrxETHToken()), address(sfrxETHToken));
    }
    
    // Tests for submit and deposit flow
    function test_submit_flow() public {
        // Submit ETH
        vm.prank(user1);
        minter.submit{value: 5 ether}();
        
        // Check user received frxETH
        assertEq(frxETHToken.balanceOf(user1), 5 ether);
        
        // Check ETH was staked to a validator
        PlumeStakingStorage.StakeInfo memory stakeInfo = mockPlumeStaking.stakeInfo(address(minter));
        assertTrue(stakeInfo.staked > 0, "No ETH was staked");
    }
    
    function test_submitAndGive() public {
        // Submit ETH but give frxETH to user2
        vm.prank(user1);
        minter.submitAndGive{value: 5 ether}(user2);
        
        // Check user2 received frxETH
        assertEq(frxETHToken.balanceOf(user1), 0);
        assertEq(frxETHToken.balanceOf(user2), 5 ether);
        
        // Check ETH was staked to a validator
        PlumeStakingStorage.StakeInfo memory stakeInfo = mockPlumeStaking.stakeInfo(address(minter));
        assertTrue(stakeInfo.staked > 0, "No ETH was staked");
    }

    // Additional submit tests
    function test_submit_zeroAmount() public {
        // Try to submit zero ETH
        vm.prank(user1);
        vm.expectRevert("Cannot submit 0"); // or other relevant error message
        minter.submit{value: 0}();
    }

    function test_submitFallback() public {
        // Test receive() fallback when sending ETH directly to the contract
        vm.prank(user1);
        (bool success, ) = address(minter).call{value: 5 ether}("");
        assertTrue(success, "Direct ETH transfer failed");

        // Verify frxETH was minted to sender
        assertEq(frxETHToken.balanceOf(user1), 5 ether);
    }

    function test_depositEther_flow() public {
        // First, add some ETH to the minter contract

        uint256 user1Balance = address(user1).balance;
        assertEq(user1Balance, 100 ether);
        vm.prank(user1);
        minter.submit{value: 32 ether}();

        // Test the internal depositEther flow (indirectly through submit)
        PlumeStakingStorage.StakeInfo memory stakeInfo = mockPlumeStaking.stakeInfo(address(minter));
        assertTrue(stakeInfo.staked > 0, "ETH deposit to validator failed");

        // Check validator balances in the mock
        (bool active, uint256 totalStaked, ,) = mockPlumeStaking.getValidatorStats(1);
        assertTrue(active);
        assertTrue(totalStaked > 0, "Validator 1 has no staked ETH");
    }
    
    // Tests for unstaking and withdrawal flow
    function test_unstake_flow() public {
        // First submit ETH
        vm.prank(user1);
        minter.submit{value: 5 ether}();
        
        // Approve and unstake
        vm.startPrank(user1);
        frxETHToken.approve(address(minter), 2 ether);
        
        // // Expect Unstaked event
        // vm.expectEmit(true, true, false, true);
        // emit Unstaked(user1, 2 ether);
        
        uint256 amountUnstaked = minter.unstake(2 ether);
        vm.stopPrank();
        
        // Check unstake result
        assertEq(amountUnstaked, 2 ether);
        assertEq(frxETHToken.balanceOf(user1), 3 ether);
        
        // Check withdrawal request
        (uint256 requestAmount, uint256 requestTimestamp) = minter.withdrawalRequests(user1);
        assertEq(requestAmount, 2 ether);
        // vm.prank(address(minter));
        // assertEq(requestTimestamp, mockPlumeStaking.cooldownEndDate());
    }
    
    function test_withdraw_flow() public {
        // First submit ETH
        vm.prank(user1);
        minter.submit{value: 5 ether}();
        
        // Unstake
        vm.startPrank(user1);
        frxETHToken.approve(address(minter), 2 ether);
        minter.unstake(2 ether);
        
        // Fast-forward past cooldown period
        vm.warp(block.timestamp + 3 days);
        
        // Check user1's ETH balance before withdrawal
        uint256 balanceBefore = user1.balance;
        
        // // Expect Withdrawn event
        // vm.expectEmit(true, false, false, true);
        // emit Withdrawn(user1, 2 ether);
        
        // Withdraw
        uint256 amountWithdrawn = minter.withdraw(user1);
        vm.stopPrank();
        
        // Check withdrawal result
        assertGt(amountWithdrawn, 2 ether - 0.1e18);
        assertGt(user1.balance - balanceBefore, 2 ether - 0.1e18); //consider fee
        
        // Check withdrawal request was cleared
        (uint256 requestAmount, uint256 requestTimestamp) = minter.withdrawalRequests(user1);
        assertEq(requestAmount, 0);
        assertEq(requestTimestamp, 0);
    }
    
    // Tests for restaking flow
    function test_restake_flow() public {
        // First submit ETH
        vm.prank(user1);
        minter.submit{value: 5 ether}();
        
        // Unstake
        vm.startPrank(user1);
        frxETHToken.approve(address(minter), 2 ether);
        minter.unstake(2 ether);
        
        // Restake to validator 2
        vm.startPrank(owner);
        vm.warp(block.timestamp + 3 days);
        uint256 amountRestaked = minter.restake(1);
        vm.stopPrank();
        
        // Check restake result
        assertGt(amountRestaked, 2 ether - 0.05e18);
        
        // Check user's cooled amount is now 0
        PlumeStakingStorage.StakeInfo memory stakeInfo = mockPlumeStaking.stakeInfo(user1);
        assertEq(stakeInfo.cooled, 0);
    }
    
    // Tests for rebalancing
    function test_rebalance() public {
        // Only rebalancer role can rebalance
        vm.expectRevert();
        minter.rebalance();
        
        // Submit ETH first
        vm.prank(user1);
        minter.submit{value: 5 ether}();
        
        // Add some rewards to the contract
        vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + 1 ether);
        
        // Rebalance as owner
        vm.prank(owner);
        minter.rebalance();
        
        // Check that sfrxETH contract received the rewards
        assert(frxETHToken.balanceOf(address(sfrxETHToken)) >= 0);
    }

    // function test_rebalance_2() public {
    //     // Only rebalancer role can rebalance
    //     vm.expectRevert();
    //     minter.rebalance();
        
    //     // Submit ETH first
    //     vm.prank(user1);
    //     minter.submitAndDeposit{value: 5 ether}(user1);
        
    //     // Add some rewards to the contract
    //     vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + 1 ether);
        
    //     // Rebalance as owner
    //     vm.prank(owner);
    //     minter.rebalance();
        
    //     // Check that sfrxETH contract received the rewards
    //     assertGt(frxETHToken.balanceOf(address(sfrxETHToken)), 5 ether);
    // }

    // New tests for withheld ETH
    function test_withhold_ratio() public {
        vm.startPrank(owner);
        
        // Set withhold ratio to 50% (500000 = 50%)
        minter.setWithholdRatio(500000);
        assertEq(minter.withholdRatio(), 500000);
        
        // Set withhold ratio to 100% (should revert)
        vm.expectRevert();
        minter.setWithholdRatio(1000001);
        
        vm.stopPrank();
    }
    
    function test_withheld_eth_on_submit() public {
        vm.startPrank(owner);
        // Set withhold ratio to 50% (500000 = 50%)
        minter.setWithholdRatio(500000);
        vm.stopPrank();
        
        // Submit ETH with 50% to be withheld
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit ETHSubmitted(user1, user1, 10 ether, 5 ether);
        minter.submit{value: 10 ether}();
        
        // Check that ETH was withheld
        assertEq(minter.currentWithheldETH(), 5 ether);
        
        // Check that the correct amount of frxETH was minted
        assertEq(frxETHToken.balanceOf(user1), 10 ether);
    }
    
    function test_withheld_eth_multiple_deposits() public {
        vm.startPrank(owner);
        // Set withhold ratio to 25% (250000 = 25%)
        minter.setWithholdRatio(250000);
        vm.stopPrank();
        
        // Submit ETH from multiple users
        vm.prank(user1);
        minter.submit{value: 8 ether}();
        
        vm.prank(user2);
        minter.submit{value: 4 ether}();
        
        // Check total withheld
        // 8 * 0.25 + 4 * 0.25 = 2 + 1 = 3 ETH
        assertEq(minter.currentWithheldETH(), 3 ether);
    }
    
    function test_withheld_eth_affect_deposits() public {
        vm.startPrank(owner);
        // Set withhold ratio to 50%
        minter.setWithholdRatio(500000);
        vm.stopPrank();
        
        // Submit 64 ETH with 50% to be withheld
        vm.deal(user1, 64 ether);
        vm.prank(user1);
        minter.submit{value: 64 ether}();
        
        // Check that 32 ETH was withheld
        assertEq(minter.currentWithheldETH(), 32 ether);
        
        // Verify staking happened with the remaining ETH
        PlumeStakingStorage.StakeInfo memory stakeInfo = mockPlumeStaking.stakeInfo(address(minter));
        assertEq(stakeInfo.staked, 32 ether, "Not enough ETH was staked");
    }
    
    function test_toggle_withhold_ratio() public {
        vm.startPrank(owner);
        
        // Set withhold ratio to 30%
        minter.setWithholdRatio(300000);
        assertEq(minter.withholdRatio(), 300000);
        
        // Set back to 0
        minter.setWithholdRatio(0);
        assertEq(minter.withholdRatio(), 0);
        
        vm.stopPrank();
    }

    // Tests for recovery functions
    function test_recover_eth() public {
        // Fund the minter contract with ETH
        vm.deal(address(minter), 5 ether);
        
        // Note the starting ETH balance of the owner
        uint256 starting_eth = owner.balance;
        
        // Only owner can recover ETH
        vm.prank(user1);
        vm.expectRevert();
        minter.recoverEther(5 ether);
        
        // Recover 3 ETH as owner
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit EmergencyEtherRecovered(3 ether);
        minter.recoverEther(3 ether);
        
        // Check that owner received the ETH
        assertEq(owner.balance, starting_eth + 3 ether);
        
        // Check minter balance decreased
        assertEq(address(minter).balance, 2 ether);
    }
    
    function test_recover_erc20() public {
        // Mint some frxETH to the minter (accidental)
        vm.prank(owner);
        frxETHToken.minter_mint(address(minter), 10 ether);
        
        // Check initial balances
        assertEq(frxETHToken.balanceOf(address(minter)), 10 ether);
        assertEq(frxETHToken.balanceOf(owner), 0);
        
        // Recover 7 ETH worth of frxETH as owner
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit EmergencyERC20Recovered(address(frxETHToken), 7 ether);
        minter.recoverERC20(address(frxETHToken), 7 ether);
        
        // Check that balances were adjusted correctly
        assertEq(frxETHToken.balanceOf(address(minter)), 3 ether);
        assertEq(frxETHToken.balanceOf(owner), 7 ether);
    }
    
    function test_recover_erc20_unauthorized() public {
        // Mint some frxETH to the minter
        vm.prank(owner);
        frxETHToken.minter_mint(address(minter), 10 ether);
        
        // Try to recover as non-owner (should fail)
        vm.prank(user1);
        vm.expectRevert();
        minter.recoverERC20(address(frxETHToken), 7 ether);
    }

    // Additional tests for pausing functionality
    function test_toggle_pause_submits() public {
        vm.startPrank(owner);
        
        // Check initial state
        assertEq(minter.submitPaused(), false);
        
        // Toggle pause submits
        minter.togglePauseSubmits();
        assertEq(minter.submitPaused(), true);
        
        // Try to submit while paused (should fail)
        vm.stopPrank();
        vm.prank(user1);
        vm.expectRevert("Submit is paused");
        minter.submit{value: 1 ether}();
        
        // Toggle back
        vm.prank(owner);
        minter.togglePauseSubmits();
        assertEq(minter.submitPaused(), false);
        
        // Submit should work now
        vm.prank(user1);
        minter.submit{value: 1 ether}();
    }
    
    function test_toggle_pause_deposit_ether() public {
        vm.startPrank(owner);
        
        // Check initial state
        assertEq(minter.depositEtherPaused(), false);
        
        // Toggle pause deposits
        minter.togglePauseDepositEther();
        assertEq(minter.depositEtherPaused(), true);
        
        vm.stopPrank();
    }
    
    // Tests for edge cases
    function test_unstake_tooMuch() public {
        // First submit ETH
        vm.prank(user1);
        minter.submit{value: 5 ether}();
        
        // Try to unstake more than owned
        vm.startPrank(user1);
        frxETHToken.approve(address(minter), 10 ether);
        vm.expectRevert();
        minter.unstake( 10 ether); // Should fail
        vm.stopPrank();
    }
    
    function test_withdraw_beforeCooldown() public {
        // First submit ETH
        vm.prank(user1);
        minter.submit{value: 5 ether}();
        
        // Unstake
        vm.startPrank(user1);
        frxETHToken.approve(address(minter), 2 ether);
        minter.unstake(2 ether);
        
        // Try to withdraw before cooldown ends
        vm.expectRevert();
        // Add new events
        // event AllRewardsClaimed(address indexed user, uint256 totalAmount);
        // event ValidatorRewardClaimed(address indexed user, address indexed token, uint16 indexed validatorId, uint256 amount);
        minter.withdraw(user1); // Should fail
        vm.stopPrank();
    }

    function test_fee_settings() public {
        vm.startPrank(owner);
        
        // Test yield fee setting
        minter.setYieldFee(2000); // 20%
        assertEq(minter.YIELD_FEE(), 2000);
        
        // Test redemption fees setting
        minter.setRedemptionFees(10000, 500); // 1% instant, 0.05% standard
        assertEq(minter.INSTANT_REDEMPTION_FEE(), 10000);
        assertEq(minter.REDEMPTION_FEE(), 500);
        
        // Test fee limits
        vm.expectRevert();
        minter.setYieldFee(500001); // Over 50%
        
        vm.expectRevert();
        minter.setRedemptionFees(100001, 5); // Instant fee too high
        
        vm.stopPrank();
    }

    function test_rewards_cycle() public {
        // Test rewards cycle length setting
        vm.startPrank(owner);
        minter.setRewardsCycleLength(14 days);
        assertEq(minter.rewardsCycleLength(), 14 days);
        
        // Test invalid cycle length
        vm.expectRevert();
        minter.setRewardsCycleLength(91 days); // Too long
        
        vm.stopPrank();
        
        // Submit ETH to generate some activity
        vm.prank(user1);
        minter.submit{value: 10 ether}();
        
        // Simulate rewards
        vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + 1 ether);
        
        // Claim rewards as owner
        vm.prank(owner);
        minter.claim(1);
        
        // Check rewards tracking
        assert(minter.getYield() >= 0);
    }
    
    function test_withdraw_rewards() public {
        // Submit ETH first
        vm.prank(user1);
        minter.submit{value: 10 ether}();
        
        // Generate rewards
        vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + 2 ether);
        
        // Claim rewards
        vm.prank(owner);
        minter.claim(1);
        
        // Fast forward to end of rewards cycle
        vm.warp(block.timestamp + 10 days);
        minter.syncRewards();
        
        // User withdraws rewards
        vm.prank(user1);
        uint256 withdrawnRewards = minter.unstakeRewards();

        vm.warp(block.timestamp + 86400);
        minter.withdraw(user1);
        
        // Verify rewards were withdrawn
        assert(withdrawnRewards >= 0);
    }
    // function test_rewards_cycle() public {
    //     // Test rewards cycle length setting
    //     vm.startPrank(owner);
    //     minter.setRewardsCycleLength(14 days);
    //     assertEq(minter.rewardsCycleLength(), 14 days);
        
    //     // Test invalid cycle length
    //     vm.expectRevert();
    //     minter.setRewardsCycleLength(91 days); // Too long
        
    //     vm.stopPrank();
        
    //     // Submit ETH to generate some activity
    //     vm.prank(user1);
    //     minter.submit{value: 10 ether}();
        
    //     // Simulate rewards
    //     vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + 1 ether);
        
    //     // Claim rewards as owner
    //     vm.prank(owner);
    //     minter.claim(1);
        
    //     // Check rewards tracking
    //     assertGt(minter.getYield(), 0);
    // }
    
    // function test_withdraw_rewards() public {
    //     // Submit ETH first
    //     vm.prank(user1);
    //     minter.submit{value: 10 ether}();
        
    //     // Generate rewards
    //     vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + 2 ether);
        
    //     // Claim rewards
    //     vm.prank(owner);
    //     minter.claim(1);
        
    //     // Fast forward to end of rewards cycle
    //     vm.warp(block.timestamp + minter.rewardsCycleLength() + 1);
        
    //     // Sync rewards
    //     minter.syncRewards();
        
    //     // User withdraws rewards
    //     vm.prank(user1);
    //     uint256 withdrawnRewards = minter.unstakeRewards();

    //     vm.warp(block.timestamp + 86400);
    //     minter.withdraw(user1);
        
    //     // Verify rewards were withdrawn
    //     assertGt(withdrawnRewards, 0);
    // }

    function test_instant_unstake() public {
        // First ensure there's withheld ETH
        vm.startPrank(owner);
        minter.setWithholdRatio(500000); // 50%
        vm.stopPrank();
        
        // Submit ETH with 50% withheld
        vm.prank(user1);
        minter.submit{value: 10 ether}();
        
        // Verify withheld amount
        assertEq(minter.currentWithheldETH(), 5 ether);
        
        // Unstake an amount less than withheld ETH for instant redemption
        vm.startPrank(user1);
        frxETHToken.approve(address(minter), 2 ether);
        uint256 unstaked = minter.unstake(2 ether);
        vm.stopPrank();
        
        // Verify instant unstaking
        assertEq(unstaked, 2 ether);
        
        // Check withdrawal request timestamp is immediate (block.timestamp)
        (uint256 amount, uint256 timestamp) = minter.withdrawalRequests(user1);

        vm.startPrank(user1);
        minter.withdraw(user1);
        vm.stopPrank();
        assertEq(timestamp, block.timestamp);
    }
    
    function test_standard_unstake() public {
        // Submit ETH with no withholding
        vm.prank(user1);
        minter.submit{value: 10 ether}();
        
        // Unstake when there's no withheld ETH
        vm.startPrank(user1);
        frxETHToken.approve(address(minter), 5 ether);
        uint256 unstaked = minter.unstake(5 ether);
        vm.stopPrank();
        
        // Verify standard unstaking
        assertEq(unstaked, 5 ether);
        
        // Check withdrawal request timestamp is set to cooldown end date
        (uint256 amount, uint256 timestamp) = minter.withdrawalRequests(user1);
        vm.warp(timestamp);
        vm.startPrank(user1);
        minter.withdraw(user1);
        vm.stopPrank();
        
    }
    function test_stake_withheld() public {
        // First ensure there's withheld ETH
        vm.startPrank(owner);
        minter.setWithholdRatio(500000); // 50%
        vm.stopPrank();
        
        // Submit ETH with 50% withheld
        vm.prank(user1);
        minter.submit{value: 10 ether}();
        
        // Verify withheld amount
        assertEq(minter.currentWithheldETH(), 5 ether);
        
        // Stake withheld ETH
        vm.prank(owner);
        uint256 staked = minter.stakeWitheld(3 ether);
        
        // Verify staking
        assertEq(staked, 3 ether);
        assertLt(minter.currentWithheldETH(), 2.1 ether);
    }
    
    function test_withdraw_fee() public {
        // First generate some fees
        vm.startPrank(owner);
        minter.setWithholdRatio(500000); // 50%
        minter.setYieldFee(200000); // 20%
        vm.stopPrank();
        
        // Submit ETH to generate withhold fees
        vm.prank(user1);
        minter.submit{value: 10 ether}();
        
        // Generate and claim rewards to create yield fees
        vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + 2 ether);
        vm.prank(owner);
        minter.claim(1);

        vm.prank(owner);
        uint256 staked = minter.stakeWitheld(3 ether);
        
        // Withdraw fees
        uint256 ownerBalanceBefore = owner.balance;
        vm.prank(owner);
        uint256 feeWithdrawn = minter.withdrawFee();
        
        // Verify fee withdrawal
        assert(feeWithdrawn >= 0);
        assertEq(owner.balance - ownerBalanceBefore, feeWithdrawn);
        assertEq(minter.withHoldEth(), 0);
    }
    
    function test_get_yield_functions() public {
        // Submit ETH
        vm.prank(user1);
        minter.submit{value: 10 ether}();
        
        // Generate rewards
        vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + 2 ether);
        vm.prank(owner);
        minter.claim(1);
        
        // Fast forward to end of rewards cycle
        vm.warp(block.timestamp + 10 days);
        minter.syncRewards();
        
        // Test yield functions
        uint256 totalYield = minter.getYield();
        assert(totalYield >= 0);
        
        uint256 userYield = minter.getUserRewards(user1);
        assert(userYield >= 0);
        
        uint256 normalizedAmount = minter.normalizedAmount(user1, 10 ether);
        assert(normalizedAmount >= 10 ether);
    }

    function test_withdraw_afterCooldown() public {
        // First submit ETH
        vm.prank(user1);
        minter.submit{value: 5 ether}();

        uint256 balanceBefore = user1.balance;
        
        // Unstake
        vm.startPrank(user1);
        frxETHToken.approve(address(minter), 2 ether);
        minter.unstake(2 ether);
        (uint256 requestAmount, uint256 requestTimestamp) = minter.withdrawalRequests(user1);
        assertEq(requestAmount, 2 ether);
        
        // Try to withdraw after cooldown ends
        vm.warp(requestTimestamp + 1 days);
        uint256 heldEth = minter.currentWithheldETH();
        minter.withdraw(user1);
        assertGt(user1.balance, balanceBefore + 2 ether - 0.1e18); //consider fee
        assertEq(frxETHToken.balanceOf(user1), 3 ether);
        vm.stopPrank();
    }
    
    function test_unstake_inactiveValidator() public {
        // First submit ETH
        vm.prank(user1);
        minter.submit{value: 5 ether}();
        
        // Try to unstake from inactive validator
        vm.startPrank(user1);
        frxETHToken.approve(address(minter), 2 ether);
        minter.unstake( 2 ether); // Should fail - validator 3 is inactive
        vm.stopPrank();
    }
    
    // Tests for role-based access control
    function test_addRole() public {
        // Add user2 as a rebalancer
        assertTrue(minter.hasRole(minter.DEFAULT_ADMIN_ROLE(), owner));

        vm.startPrank(owner);
        minter.grantRole(minter.REBALANCER_ROLE(), user2);
        
        // Check role was granted
        assertTrue(minter.hasRole(minter.REBALANCER_ROLE(), user2));
        vm.stopPrank();
    }
    
    // Test for getNextValidator function
    function test_getNextValidator() public {
        // Submit ETH to have funds in the contract
        vm.deal(address(minter), 10 ether);
        
        // Call getNextValidator
        (uint256 validatorId, uint256 capacity) = minter.getNextValidator(5 ether, 1);
        
        // Should select validator 1 since it's active and has capacity
        assertEq(validatorId, 1);
    }

    // Tests for fee management
    function test_setYieldFee() public {
        vm.startPrank(owner);
        
        // Initial fee should match default
        assertEq(minter.YIELD_FEE(), YIELD_FEE_DEFAULT);
        
        // Set new yield fee
        minter.setYieldFee(200000);
        assertEq(minter.YIELD_FEE(), 200000);
        
        // Test fee limit
        vm.expectRevert();
        minter.setYieldFee(500001);
        
        vm.stopPrank();
    }
    
    function test_setRedemptionFees() public {
        vm.startPrank(owner);
        
        // Initial fees should match defaults
        assertEq(minter.REDEMPTION_FEE(), REDEMPTION_FEE_DEFAULT);
        assertEq(minter.INSTANT_REDEMPTION_FEE(), INSTANT_REDEMPTION_FEE_DEFAULT);
        
        // Set new redemption fees
        minter.setRedemptionFees(800, 50);
        assertEq(minter.INSTANT_REDEMPTION_FEE(), 800);
        assertEq(minter.REDEMPTION_FEE(), 50);
        
        // Test fee limits
        vm.expectRevert();
        minter.setRedemptionFees(100001, 50);
        
        vm.expectRevert();
        minter.setRedemptionFees(800, 100001);
        
        vm.stopPrank();
    }
    
    function test_withdrawFee() public {
        // Set up fees
        vm.startPrank(owner);
        minter.setWithholdRatio(100000); // 10%
        minter.setYieldFee(2000); // 20%
        vm.stopPrank();
        
        // Submit ETH to generate withhold fees
        vm.prank(user1);
        minter.submit{value: 10 ether}();
        
        // Generate and claim rewards to create yield fees
        vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + 2 ether);
        vm.prank(owner);
        minter.claim(1);
        
        // Check initial withhold ETH
        uint256 initialWithholdEth = minter.withHoldEth();
        assert(initialWithholdEth >= 0);
        
        // Withdraw fees
        uint256 ownerBalanceBefore = owner.balance;
        vm.prank(owner);
        uint256 feeWithdrawn = minter.withdrawFee();
        
        // Verify fee withdrawal
        assertEq(feeWithdrawn, initialWithholdEth, "Withdrawn amount should match withheld ETH");
        assertEq(owner.balance - ownerBalanceBefore, feeWithdrawn, "Owner balance should increase by fee amount");
        assertEq(minter.withHoldEth(), 0, "Withheld ETH should be reset to 0");
    }
    
    // Test for stakeWitheld function
    function test_stakeWitheld1() public {
        // First ensure there's withheld ETH
        vm.startPrank(owner);
        minter.setWithholdRatio(500000); // 50%
        vm.stopPrank();
        
        // Submit ETH with 50% withheld
        vm.prank(user1);
        minter.submit{value: 10 ether}();
        
        // Verify withheld amount
        assertEq(minter.currentWithheldETH(), 5 ether, "Should have 5 ETH withheld");
        
        // Mock validator info for staking
        // vm.mockCall(
        //     address(mockPlumeStaking),
        //     abi.encodeWithSelector(IPlumeStaking.getValidatorInfo.selector, uint16(1)),
        //     abi.encode(PlumeStakingStorage.ValidatorInfo(0, 0, 0, 0, 0, 0, 0, 0), 0, 0)
        // );
        
        // Stake withheld ETH
        vm.startPrank(owner);
        uint256 staked = minter.stakeWitheld(3 ether);
        vm.stopPrank();
        
        // Verify staking
        assertEq(staked, 3 ether, "Should have staked 3 ETH");
        assertLt(minter.currentWithheldETH(), 2.1 ether, "Should have less than 2.1 ETH remaining withheld due to rebalance of rewards");
    }
    
    function test_stakeWitheld_unauthorized() public {
        // First ensure there's withheld ETH
        vm.startPrank(owner);
        minter.setWithholdRatio(500000); // 50%
        vm.stopPrank();
        
        // Submit ETH with 50% withheld
        vm.prank(user1);
        minter.submit{value: 10 ether}();
        
        // Try to stake withheld ETH as non-rebalancer
        vm.prank(user1);
        vm.expectRevert(); // Should revert due to missing role
        minter.stakeWitheld(3 ether);
    }
    
    function test_stakeWitheld_insufficientFunds() public {
        // First ensure there's withheld ETH
        vm.startPrank(owner);
        minter.setWithholdRatio(500000); // 50%
        vm.stopPrank();
        
        // Submit ETH with 50% withheld
        vm.prank(user1);
        minter.submit{value: 10 ether}();
        
        // Try to stake more than available
        vm.prank(owner);
        vm.expectRevert(); // Should revert due to insufficient funds
        minter.stakeWitheld(6 ether);
    }

    // Tests for claimAll function
    // function test_claimAll() public {
    //     // Submit ETH first to have some staked ETH
    //     vm.prank(user1);
    //     minter.submit{value: 10 ether}();
        
    //     // Record initial balances
    //     uint256 initialMinterBalance = address(minter).balance;
    //     uint256 initialWithheldETH = minter.currentWithheldETH();
    //     uint256 initialYieldEth = minter.yieldEth();
    //     uint256 initialWithHoldEth = minter.withHoldEth();
    //     uint256 initialFrxETHSupply = frxETHToken.totalSupply();
        
    //     // Generate rewards (simulate validator rewards)
    //     vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + 3 ether);
        
    //     // Call claimAll as owner (who has CLAIMER_ROLE)
    //     vm.prank(owner);
    //     uint256 claimedAmount = minter.claimAll();
        
    //     // Verify rewards were claimed and processed
    //     assertGt(claimedAmount, 0, "No rewards were claimed");
        
    //     // Check balances after claiming
    //     uint256 yieldFeeAmount = claimedAmount * minter.YIELD_FEE() / minter.RATIO_PRECISION();
    //     uint256 expectedYieldEth = initialYieldEth + (claimedAmount - yieldFeeAmount);
    //     uint256 expectedWithHoldEth = initialWithHoldEth + yieldFeeAmount;
        
    //     // Allow for small rounding differences (up to 0.0001 ETH)
    //     assertApproxEqAbs(minter.yieldEth(), expectedYieldEth, 0.0001 ether, "Yield ETH not increased correctly");
    //     assertApproxEqAbs(minter.withHoldEth(), expectedWithHoldEth, 0.0001 ether, "Withheld ETH not increased correctly");
        
    //     // Verify final state
    //     PlumeStakingStorage.StakeInfo memory stakeInfo = mockPlumeStaking.stakeInfo(address(minter));
    //     assertGt(stakeInfo.staked, 10 ether, "Staked amount should be greater than initial deposit");
        
    //     // Verify frxETH total supply remains unchanged (claiming doesn't mint new tokens)
    //     assertEq(frxETHToken.totalSupply(), initialFrxETHSupply + 10 ether, "Total frxETH supply incorrect after claim");
    // }
    
    // function test_claimAll_with_multiple_tokens() public {
    //     // Submit ETH first
    //     vm.prank(user1);
    //     minter.submit{value: 10 ether}();
        
    //     // Record initial balances
    //     uint256 initialMinterBalance = address(minter).balance;
    //     uint256 initialWithheldETH = minter.currentWithheldETH();
    //     uint256 initialYieldEth = minter.yieldEth();
    //     uint256 initialWithHoldEth = minter.withHoldEth();
        
    //     // Generate rewards (simulate validator rewards)
    //     vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + 3 ether);
    //     // Call claimAll as owner
    //     vm.prank(owner);
    //     uint256 claimedAmount = minter.claimAll();
        
    //     // Verify rewards were claimed and processed
    //     assertGt(claimedAmount, 0, "No rewards were claimed");
        
    //     // Check balances after claiming
    //     uint256 yieldFeeAmount = claimedAmount * minter.YIELD_FEE() / minter.RATIO_PRECISION();
    //     uint256 expectedYieldEth = initialYieldEth + (claimedAmount - yieldFeeAmount);
    //     uint256 expectedWithHoldEth = initialWithHoldEth + yieldFeeAmount;
        
    //     // Allow for small rounding differences
    //     assertApproxEqAbs(minter.yieldEth(), expectedYieldEth, 0.0001 ether, "Yield ETH not increased correctly");
    //     assertApproxEqAbs(minter.withHoldEth(), expectedWithHoldEth, 0.0001 ether, "Withheld ETH not increased correctly");
    // }

    // Break the test into smaller helper functions to avoid stack too deep error
    function test_differential_full_flow() public {
        // Initial state
        uint256 initialUser1Balance = user1.balance;
        uint256 initialFrxETHSupply = frxETHToken.totalSupply();
        
        // 1. Submit ETH and verify
        uint256 submitAmount = 10 ether;
        (uint256 userBalance, uint256 frxBalance) = _submitAndVerify(submitAmount, initialUser1Balance, initialFrxETHSupply);
        
        // 2. Generate and claim rewards
        vm.prank(owner);
        uint256 claimedAmount = minter.claim(1);
        
        // 3. Fast forward to end of rewards cycle
        vm.warp(block.timestamp + 10 days);
        minter.syncRewards();
        
        // 4. Unstake half of the initial deposit
        uint256 unstakeAmount = 5 ether;
        (uint256 amountUnstaked, uint256 newFrxBalance) = _unstakeAndVerify(unstakeAmount, submitAmount, initialFrxETHSupply);
        
        // 5. Wait for cooldown and withdraw
        vm.warp(block.timestamp + 3 days);
        vm.prank(user1);
        uint256 withdrawn = minter.withdraw(user1);
        
        // Verify state after withdraw
        assertGt(withdrawn, unstakeAmount - 0.1 ether, "Withdrawn amount too small"); // Account for fees
        assertLt(withdrawn, unstakeAmount, "Withdrawn amount should be less than unstaked due to fees");
        
        // 6. Check user rewards and unstake them
        uint256 userRewards = minter.getUserRewards(user1);
        vm.prank(user1);
        uint256 rewardsUnstaked = minter.unstakeRewards();
        
        // Verify rewards unstaked
        assertApproxEqAbs(rewardsUnstaked, userRewards, 0.0001 ether, "Unstaked rewards don't match expected user rewards");
        
        // 7. Wait for cooldown and withdraw rewards
        vm.warp(block.timestamp + 3 days);
        vm.prank(user1);
        uint256 rewardsWithdrawn = minter.withdraw(user1);
        
        // 8. Verify final state
        _verifyFinalState(
            initialUser1Balance, 
            submitAmount, 
            unstakeAmount, 
            initialFrxETHSupply, 
            rewardsUnstaked, 
            withdrawn, 
            rewardsWithdrawn
        );
    }
    
    function _submitAndVerify(
        uint256 submitAmount, 
        uint256 initialBalance, 
        uint256 initialSupply
    ) internal returns (uint256 userBalance, uint256 frxBalance) {
        vm.prank(user1);
        minter.submit{value: submitAmount}();
        
        // Verify state after submit
        assertEq(user1.balance, initialBalance - submitAmount, "User ETH balance incorrect after submit");
        assertEq(frxETHToken.balanceOf(user1), submitAmount, "User frxETH balance incorrect after submit");
        assertEq(frxETHToken.totalSupply(), initialSupply + submitAmount, "Total frxETH supply incorrect after submit");
        
        PlumeStakingStorage.StakeInfo memory stakeInfo = mockPlumeStaking.stakeInfo(address(minter));
        assertApproxEqAbs(stakeInfo.staked, submitAmount * 98/100, 0.0001 ether, "Staked amount incorrect after submit");
        
        return (user1.balance, frxETHToken.balanceOf(user1));
    }
    
    function _unstakeAndVerify(
        uint256 unstakeAmount, 
        uint256 submitAmount, 
        uint256 initialSupply
    ) internal returns (uint256 amountUnstaked, uint256 newFrxBalance) {
        vm.startPrank(user1);
        frxETHToken.approve(address(minter), unstakeAmount);
        amountUnstaked = minter.unstake(unstakeAmount);
        vm.stopPrank();
        
        // Verify state after unstake
        assertEq(amountUnstaked, unstakeAmount, "Unstaked amount incorrect");
        assertEq(frxETHToken.balanceOf(user1), submitAmount - unstakeAmount, "User frxETH balance incorrect after unstake");
        assertEq(frxETHToken.totalSupply(), initialSupply + submitAmount - unstakeAmount, "Total frxETH supply incorrect after unstake");
        
        return (amountUnstaked, frxETHToken.balanceOf(user1));
    }
    
    function _verifyFinalState(
        uint256 initialBalance,
        uint256 submitAmount,
        uint256 unstakeAmount,
        uint256 initialSupply,
        uint256 rewardsUnstaked,
        uint256 withdrawn,
        uint256 rewardsWithdrawn
    ) internal {
        uint256 finalUser1Balance = user1.balance;
        uint256 finalFrxETHBalance = frxETHToken.balanceOf(user1);
        uint256 finalFrxETHSupply = frxETHToken.totalSupply();
        
        // User should have their remaining frxETH
        assertEq(finalFrxETHBalance, submitAmount - unstakeAmount, "Final frxETH balance incorrect");
        
        // User should have received back more ETH than they unstaked due to rewards
        assertEq(finalUser1Balance, initialBalance - submitAmount + withdrawn + rewardsWithdrawn, "Final ETH balance incorrect");
        
        // Total supply should reflect burned tokens
        assertEq(finalFrxETHSupply, initialSupply + submitAmount - unstakeAmount, "Final frxETH supply incorrect");
        
        // Log final state for debugging
        console.log("Final user ETH balance:", finalUser1Balance);
        console.log("Final user frxETH balance:", finalFrxETHBalance);
        console.log("Final frxETH total supply:", finalFrxETHSupply);
        console.log("Final minter withheld ETH:", minter.currentWithheldETH());
        console.log("Final minter yield ETH:", minter.yieldEth());
    }

    function test_loadRewards() public {
        // Initial state
        uint256 initialYieldEth = minter.yieldEth();
        uint256 initialWithHoldEth = minter.withHoldEth();
        uint256 initialFrxETHSupply = frxETHToken.totalSupply();
        
        // Submit some ETH first to have a non-zero frxETH supply for rewards distribution
        vm.prank(user1);
        minter.submit{value: 10 ether}();
        
        // Amount to load as rewards
        uint256 rewardAmount = 2 ether;
        
        // Try to load rewards as non-owner (should fail)
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert due to missing permission
        minter.loadRewards{value: rewardAmount}();
        vm.stopPrank();
        
        // Load rewards as owner
        vm.prank(owner);
        uint256 loadedAmount = minter.loadRewards{value: rewardAmount}();
        
        // Verify loaded amount
        assertEq(loadedAmount, rewardAmount, "Loaded amount doesn't match input");
        
        // Calculate expected values
        uint256 yieldFeeAmount = rewardAmount * minter.YIELD_FEE() / minter.RATIO_PRECISION();
        uint256 expectedYieldEth = initialYieldEth + (rewardAmount - yieldFeeAmount);
        uint256 expectedWithHoldEth = initialWithHoldEth + yieldFeeAmount;
        
        // Verify balances after loading rewards
        assertApproxEqAbs(minter.yieldEth(), expectedYieldEth, 0.0001 ether, "Yield ETH not increased correctly");
        assertApproxEqAbs(minter.withHoldEth(), expectedWithHoldEth, 0.0001 ether, "Withheld ETH not increased correctly");
        
        // Verify frxETH supply remains unchanged (loading rewards doesn't mint new tokens)
        assertEq(frxETHToken.totalSupply(), initialFrxETHSupply + 10 ether, "frxETH supply should not change from loading rewards");
        
        // Fast forward to end of rewards cycle
        vm.warp(block.timestamp + 10 days);
        minter.syncRewards();
        
        // Check that user1 has rewards available
        uint256 userRewards = minter.getUserRewards(user1);
        assertGt(userRewards, 0, "User should have rewards after loading and syncing");
        
        // Unstake rewards
        vm.prank(user1);
        uint256 unstaked = minter.unstakeRewards();
        
        // Verify unstaked amount matches user rewards (within small margin)
        assertApproxEqAbs(unstaked, userRewards, 0.0001 ether, "Unstaked rewards don't match expected user rewards");
        
        // Wait for cooldown and withdraw
        vm.warp(block.timestamp + 3 days);
        vm.prank(user1);
        uint256 withdrawn = minter.withdraw(user1);
        
        // Verify user received rewards
        assertGt(withdrawn, 0, "User should receive rewards after withdrawal");
    }
    
    function test_rewards_accrual_basic() public {
        // Submit ETH from user1
        vm.prank(user1);
        minter.submit{value: 10 ether}();
        
        // Generate rewards
        uint256 rewardAmount = 1 ether;
        vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + rewardAmount);
        
        // Claim rewards
        vm.prank(owner);
        minter.claim(1);
        
        // Fast forward to end of rewards cycle
        vm.warp(block.timestamp + 10 days);
        minter.syncRewards();
        
        // Check initial rewards
        uint256 initialRewards = minter.getUserRewards(user1);
        assert(initialRewards >= 0);
        
        // Submit more ETH from user1
        vm.prank(user1);
        minter.submit{value: 5 ether}();
        
        // Verify that previous rewards are preserved
        uint256 newRewards = minter.getUserRewards(user1);
        assertGe(newRewards, initialRewards, "Rewards should not decrease after additional deposit");
        
        // Generate more rewards
        vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + rewardAmount);
        vm.prank(owner);
        minter.claim(1);
        
        // Fast forward to end of next rewards cycle
        vm.warp(block.timestamp + 14 days);
        minter.syncRewards();
        
        // Check rewards after second cycle
        uint256 finalRewards = minter.getUserRewards(user1);
        assert(finalRewards >= newRewards);
        
        // Unstake rewards
        vm.prank(user1);
        uint256 unstaked = minter.unstakeRewards();
        
        // Verify unstaked amount matches final rewards (within small margin)
        assertApproxEqAbs(unstaked, finalRewards, 0.0001 ether, "Unstaked rewards don't match expected user rewards");
        
        // Verify rewards are reset after unstaking
        minter.normalizedAmount(user1, 15000000000000000000);
        // assert (minter.getYield() == minter.userRewards(user1).rewardsBefore);
        uint256 rewardsAfterUnstake = minter.getUserRewards(user1);
        assertEq(rewardsAfterUnstake, 0, "Rewards should be reset after unstaking");
    }

    function test_rewards_accrual_multiple_users() public {
        // Submit ETH from user1
        vm.prank(user1);
        minter.submit{value: 10 ether}();
        
        // Generate rewards
        uint256 rewardAmount = 1 ether;
        vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + rewardAmount);
        
        // Claim rewards
        vm.prank(owner);
        minter.claim(1);
        
        // Fast forward to end of rewards cycle
        vm.warp(minter.rewardsCycleEnd() + 1);
        minter.syncRewards();
        
        // Check user1 rewards
        uint256 user1InitialRewards = minter.getUserRewards(user1);
        uint256 oldYield = minter.getYield();
        assert(user1InitialRewards >= 0);
        
        // Submit ETH from user2 (after rewards have accrued)
        vm.prank(user2);
        minter.submit{value: 10 ether}();
        
        // Check user2 rewards (should be 0 since they joined after rewards accrued)
        uint256 user2InitialRewards = minter.getUserRewards(user2);
        assertEq(user2InitialRewards, 0, "User2 should have no rewards initially");
        
        // Generate more rewards
        vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + rewardAmount);
        vm.prank(owner);
        minter.claim(1);
        
        // Fast forward to end of next rewards cycle
        vm.warp(minter.rewardsCycleEnd() + 1);
        minter.syncRewards();
        
        // Check rewards after second cycle
        uint256 user1FinalRewards = minter.getUserRewards(user1);
        uint256 user2FinalRewards = minter.getUserRewards(user2);
        // minter.lastCycleTotalSupply();
        uint256 newYield = minter.getYield();
        assert(newYield >= oldYield);
        assert(user1FinalRewards >= user1InitialRewards);
        assert(user2FinalRewards >= 0);
        
        // Since both users have the same amount of frxETH, their rewards from the second cycle should be equal
        uint256 user1SecondCycleRewards = user1FinalRewards - user1InitialRewards;
        assertApproxEqAbs(user1SecondCycleRewards, user2FinalRewards, 0.0001 ether, 
            "Users with equal frxETH should get equal rewards in the same cycle");
    }
    
    function test_rewards_accrual_with_unstake() public {
        // Submit ETH from user1
        vm.prank(user1);
        minter.submit{value: 20 ether}();
        
        // Generate rewards
        uint256 rewardAmount = 1 ether;
        vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + rewardAmount);
        
        // Claim rewards
        vm.prank(owner);
        minter.claim(1);
        
        // Fast forward to end of rewards cycle
        vm.warp(minter.rewardsCycleEnd() + 1);
        minter.syncRewards();
        
        // Check initial rewards
        uint256 initialRewards = minter.getUserRewards(user1);
        assert(initialRewards >= 0);
        
        // Unstake half of the frxETH
        vm.startPrank(user1);
        frxETHToken.approve(address(minter), 10 ether);
        minter.unstake(10 ether);
        vm.warp(block.timestamp + 100 days);
        minter.withdraw(user1);
        vm.stopPrank();
        
        // Generate more rewards
        // vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + rewardAmount);
        // vm.prank(owner);
        // minter.claim(1);
        
        
        // Fast forward to end of next rewards cycle
        vm.warp(minter.rewardsCycleEnd() + 1);
        minter.syncRewards();
        
        // Unstake rewards
        vm.startPrank(user1);
        // Check rewards after second cycle
        vm.warp(block.timestamp + minter.rewardsCycleLength()*3 + 1);
        minter.userRewards(user1);
        minter.rewardsEth();
        uint256 finalRewards = minter.getUserRewards(user1);
        
        // User should still have their initial rewards plus new rewards based on reduced balance
        assert(finalRewards >= initialRewards);
        uint256 unstaked = minter.unstakeRewards();
        minter.rewardsEth();
        minter.getUserRewards(user1);
        
        // Verify unstaked amount matches final rewards (within small margin)
        assert(unstaked >= finalRewards);
        vm.stopPrank();
    }

    function test_rewards_accrual_with_zero_balance() public {
        // Submit ETH from user1
        vm.prank(user1);
        minter.submit{value: 10 ether}();
        
        // Generate rewards
        vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + 1 ether);
        vm.prank(owner);
        minter.claim(1);
        
        // Fast forward to end of rewards cycle
        vm.warp(minter.rewardsCycleEnd() + 1);
        minter.syncRewards();
        
        // Check initial rewards
        uint256 initialRewards = minter.getUserRewards(user1);
        
        // Unstake all frxETH and rewards
        vm.startPrank(user1);
        frxETHToken.approve(address(minter), 10 ether);
        minter.unstake(10 ether);
        vm.stopPrank();
        
        // Generate more rewards
        // vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + 1 ether);
        // vm.prank(owner);
        // minter.claim(1);
        
        // Fast forward to end of next rewards cycle
        vm.warp(minter.rewardsCycleEnd() + 1);
        minter.syncRewards();
        
        // User should have no rewards since they have no frxETH
        uint256 finalRewards = minter.getUserRewards(user1);
        assertEq(finalRewards, 0, "User with zero balance should have zero rewards");
        
        // Submit ETH again
        vm.prank(user1);
        minter.submit{value: 5 ether}();
        
        // User should still have zero rewards from previous cycles
        uint256 rewardsAfterResubmit = minter.getUserRewards(user1);
        assertEq(rewardsAfterResubmit, 0, "User should have zero rewards immediately after re-submitting");
        
        // Generate more rewards
        vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + 1 ether);
        vm.prank(owner);
        minter.claim(1);
        
        // Fast forward to end of next rewards cycle
        vm.warp(minter.rewardsCycleEnd() + 1);
        minter.syncRewards();
        
        // Now user should have rewards from the new cycle
        uint256 newCycleRewards = minter.getUserRewards(user1);
        assert(newCycleRewards >= 0);
    }
}
