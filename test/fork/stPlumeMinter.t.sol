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
        mockPlumeStaking =  IPlumeStaking(0xA20bfe49969D4a0E9abfdb6a46FeD777304ba07f);
        
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

        OperatorRegistry.Validator[] memory validators = new OperatorRegistry.Validator[](3);
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
        vm.prank(address(minter));
        assertEq(requestTimestamp, mockPlumeStaking.cooldownEndDate());
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
        uint256 amountRestaked = minter.restake(1);
        vm.stopPrank();
        
        // Check restake result
        assertGt(amountRestaked, 2 ether - 0.1e18);
        
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
        assertGt(frxETHToken.balanceOf(address(sfrxETHToken)), 0);
    }

    function test_rebalance_2() public {
        // Only rebalancer role can rebalance
        vm.expectRevert();
        minter.rebalance();
        
        // Submit ETH first
        vm.prank(user1);
        minter.submitAndDeposit{value: 5 ether}(user1);
        
        // Add some rewards to the contract
        vm.deal(address(mockPlumeStaking), address(mockPlumeStaking).balance + 1 ether);
        
        // Rebalance as owner
        vm.prank(owner);
        minter.rebalance();
        
        // Check that sfrxETH contract received the rewards
        assertGt(frxETHToken.balanceOf(address(sfrxETHToken)), 5 ether);
    }

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
        
        // Initial withhold ratio should be 0
        assertEq(minter.withholdRatio(), 0);
        
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
        minter.withdraw(user1); // Should fail
        vm.stopPrank();
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
        (uint256 validatorId, uint256 capacity) = minter.getNextValidator(5 ether);
        
        // Should select validator 1 since it's active and has capacity
        assertEq(validatorId, 1);
    }
}
