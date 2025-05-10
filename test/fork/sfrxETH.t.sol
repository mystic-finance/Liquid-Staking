// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/sfrxETH.sol";
import "../../src/frxETH.sol";
import { ERC20 } from "ERC4626/xERC4626.sol";
import { SigUtils } from "../../src/Utils/SigUtils.sol";

contract sfrxETHForkTest is Test {
    sfrxETH sfrxETHtoken;
    frxETH frxETHtoken;
    SigUtils internal sigUtils_frxETH;
    SigUtils internal sigUtils_sfrxETH;

    // Test accounts
    uint256 internal ownerPrivateKey;
    uint256 internal spenderPrivateKey;
    address payable internal owner;
    address internal spender;
    address public constant FRAX_TIMELOCK = address(0x8412ebf45bAC1B340BbE8F318b928C466c4E39CA);
    address public constant FRAX_COMPTROLLER = address(0xB1748C79709f4Ba2Dd82834B8c82D4a505003f27);

    function setUp() public {        
        // Set up test time (important for cycle-based rewards)
        vm.warp(1000);
        
        // Deploy contracts
        frxETHtoken = new frxETH(FRAX_COMPTROLLER, FRAX_TIMELOCK);
        sfrxETHtoken = new sfrxETH(ERC20(address(frxETHtoken)), 1000); // 1000 second rewards cycle

        // Add the FRAX comptroller as an EOA/Multisig frxETH minter
        vm.prank(FRAX_COMPTROLLER);
        frxETHtoken.addMinter(FRAX_COMPTROLLER);

        // For EIP-712 testing
        sigUtils_frxETH = new SigUtils(frxETHtoken.DOMAIN_SEPARATOR());
        sigUtils_sfrxETH = new SigUtils(sfrxETHtoken.DOMAIN_SEPARATOR());
        ownerPrivateKey = 0xA11CE;
        spenderPrivateKey = 0xB0B;
        owner = payable(vm.addr(ownerPrivateKey));
        spender = payable(vm.addr(spenderPrivateKey));
        
        // Mint some frxETH to the owner for testing
        vm.prank(FRAX_COMPTROLLER);
        frxETHtoken.minter_mint(owner, 10 ether);
    }

    function test_initialState() public {
        assertEq(address(sfrxETHtoken.asset()), address(frxETHtoken));
        assertEq(sfrxETHtoken.rewardsCycleLength(), 1000);
        assertEq(sfrxETHtoken.totalAssets(), 0);
    }

    function test_deposit() public {
        // Approve sfrxETH to spend owner's frxETH
        vm.prank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), 5 ether);
        
        // Deposit frxETH to get sfrxETH
        vm.prank(owner);
        uint256 shares = sfrxETHtoken.deposit(5 ether, owner);
        
        // Check balances
        assertEq(frxETHtoken.balanceOf(owner), 5 ether);
        assertEq(frxETHtoken.balanceOf(address(sfrxETHtoken)), 5 ether);
        assertEq(sfrxETHtoken.balanceOf(owner), shares);
        assertEq(sfrxETHtoken.totalAssets(), 5 ether);
        
        // Initial deposit should give same amount of shares as assets
        assertEq(shares, 5 ether);
    }

    function test_mint() public {
        // Approve sfrxETH to spend owner's frxETH
        vm.prank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), 5 ether);
        
        // Mint sfrxETH shares
        vm.prank(owner);
        uint256 assets = sfrxETHtoken.mint(5 ether, owner);
        
        // Check balances
        assertEq(frxETHtoken.balanceOf(owner), 5 ether);
        assertEq(frxETHtoken.balanceOf(address(sfrxETHtoken)), 5 ether);
        assertEq(sfrxETHtoken.balanceOf(owner), 5 ether);
        
        // Initial mint should require same amount of assets as shares
        assertEq(assets, 5 ether);
    }

    function test_withdraw() public {
        // Deposit some frxETH first
        vm.startPrank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), 5 ether);
        sfrxETHtoken.deposit(5 ether, owner);
        vm.stopPrank();
        
        // Withdraw 2 ether worth of frxETH
        vm.prank(owner);
        uint256 shares = sfrxETHtoken.withdraw(2 ether, owner, owner);
        
        // Check balances after withdrawal
        assertEq(frxETHtoken.balanceOf(owner), 7 ether);
        assertEq(frxETHtoken.balanceOf(address(sfrxETHtoken)), 3 ether);
        assertEq(sfrxETHtoken.balanceOf(owner), 3 ether);
        assertEq(sfrxETHtoken.totalAssets(), 3 ether);
        
        // Should have consumed 2 ether worth of shares
        assertEq(shares, 2 ether);
    }

    function test_redeem() public {
        // Deposit some frxETH first
        vm.startPrank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), 5 ether);
        sfrxETHtoken.deposit(5 ether, owner);
        vm.stopPrank();
        
        // Redeem 2 ether worth of shares
        vm.prank(owner);
        uint256 assets = sfrxETHtoken.redeem(2 ether, owner, owner);
        
        // Check balances after redemption
        assertEq(frxETHtoken.balanceOf(owner), 7 ether);
        assertEq(frxETHtoken.balanceOf(address(sfrxETHtoken)), 3 ether);
        assertEq(sfrxETHtoken.balanceOf(owner), 3 ether);
        assertEq(sfrxETHtoken.totalAssets(), 3 ether);
        
        // Should have received 2 ether worth of assets
        assertEq(assets, 2 ether);
    }

    function test_pricePerShare() public {
        // Initial price per share should be 1:1
        assertEq(sfrxETHtoken.pricePerShare(), 1e18);
        
        // Deposit some frxETH
        vm.startPrank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), 5 ether);
        sfrxETHtoken.deposit(5 ether, owner);
        vm.stopPrank();
        
        // Add some rewards (simulate yield) - mint directly to the sfrxETH contract
        vm.prank(FRAX_COMPTROLLER);
        frxETHtoken.minter_mint(address(sfrxETHtoken), 1 ether);
        
        // Fast forward to end of rewards cycle
        vm.warp(block.timestamp + 1000);
        // Sync rewards (should happen automatically on next user action)
        vm.prank(owner);
        sfrxETHtoken.withdraw(0, owner, owner); // Zero withdrawal to trigger reward sync
        
        // Price per share should have increased
        // 6 ETH total assets / 5 ETH shares = 1.2 ETH per share
        vm.warp(block.timestamp + 1000);
        assertEq(sfrxETHtoken.pricePerShare(), 1.2e18);
    }

    function test_depositWithSignature() public {
        uint256 depositAmount = 5 ether;
        
        // Get the permit digest
        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: address(sfrxETHtoken),
            value: depositAmount,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });
        bytes32 digest = sigUtils_frxETH.getTypedDataHash(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        
        // Call depositWithSignature
        vm.prank(owner);
        uint256 shares = sfrxETHtoken.depositWithSignature(
            depositAmount,
            owner,
            block.timestamp + 1 days,
            false, // don't approve max
            v,
            r,
            s
        );
        
        // Check balances
        assertEq(frxETHtoken.balanceOf(owner), 5 ether);
        assertEq(frxETHtoken.balanceOf(address(sfrxETHtoken)), 5 ether);
        assertEq(sfrxETHtoken.balanceOf(owner), shares);
        assertEq(shares, 5 ether);
    }

    function test_syncRewards() public {
        // Deposit some frxETH
        vm.startPrank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), 5 ether);
        sfrxETHtoken.deposit(5 ether, owner);
        vm.stopPrank();
        
        // Add rewards
        vm.prank(FRAX_COMPTROLLER);
        frxETHtoken.minter_mint(address(sfrxETHtoken), 1 ether);
        
        // Check rewards cycle timing
        uint256 cycleEnd = sfrxETHtoken.rewardsCycleEnd();
        assertTrue(cycleEnd > block.timestamp);
        
        // Fast forward past the cycle end
        vm.warp(cycleEnd + 1);
        
        // Do a zero withdrawal to trigger reward sync
        vm.prank(owner);
        sfrxETHtoken.withdraw(0, owner, owner);
        
        // A new cycle should have started
        uint256 newCycleEnd = sfrxETHtoken.rewardsCycleEnd();
        assertTrue(newCycleEnd > cycleEnd);
        
        // Price per share should increase
        vm.warp(block.timestamp + 1000);
        assertEq(sfrxETHtoken.pricePerShare(), 1.2e18);
    }

    // New tests for permits and signatures
    function test_sfrxETH_Permit() public {
        uint256 transfer_amount = 0.5 ether;

        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: spender,
            value: transfer_amount,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        bytes32 digest = sigUtils_sfrxETH.getTypedDataHash(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Execute the permit
        sfrxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );

        // Check allowance was set correctly
        assertEq(sfrxETHtoken.allowance(owner, spender), transfer_amount);
        
        // Check nonce was incremented
        assertEq(sfrxETHtoken.nonces(owner), 1);
    }

    function test_frxETH_Permit() public {
        uint256 transfer_amount = 0.5 ether;

        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: spender,
            value: transfer_amount,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        bytes32 digest = sigUtils_frxETH.getTypedDataHash(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Execute the permit
        frxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );

        // Check allowance was set correctly
        assertEq(frxETHtoken.allowance(owner, spender), transfer_amount);
        
        // Check nonce was incremented
        assertEq(frxETHtoken.nonces(owner), 1);
    }

    function test_sfrxETH_ExpiredPermit() public {
        uint256 transfer_amount = 0.5 ether;

        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: spender,
            value: transfer_amount,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        bytes32 digest = sigUtils_sfrxETH.getTypedDataHash(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Fast forward past the deadline
        vm.warp(block.timestamp + 1 days + 1 seconds);

        // Should revert with an expired deadline message
        vm.expectRevert("PERMIT_DEADLINE_EXPIRED");
        sfrxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );
    }

    function test_frxETH_ExpiredPermit() public {
        uint256 transfer_amount = 0.5 ether;

        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: spender,
            value: transfer_amount,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        bytes32 digest = sigUtils_frxETH.getTypedDataHash(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Fast forward past the deadline
        vm.warp(block.timestamp + 1 days + 1 seconds);

        // Should revert with an expired deadline message
        vm.expectRevert("ERC20Permit: expired deadline");
        frxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );
    }

    function test_sfrxETH_InvalidSigner() public {
        uint256 transfer_amount = 0.5 ether;

        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: spender,
            value: transfer_amount,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        bytes32 digest = sigUtils_sfrxETH.getTypedDataHash(permit);
        
        // Use spender's private key to sign owner's permit (invalid)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(spenderPrivateKey, digest);

        // Should revert with an invalid signature message
        vm.expectRevert("INVALID_SIGNER");
        sfrxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );
    }

    function test_frxETH_InvalidSigner() public {
        uint256 transfer_amount = 0.5 ether;

        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: spender,
            value: transfer_amount,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        bytes32 digest = sigUtils_frxETH.getTypedDataHash(permit);
        
        // Use spender's private key to sign owner's permit (invalid)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(spenderPrivateKey, digest);

        // Should revert with an invalid signature message
        vm.expectRevert("ERC20Permit: invalid signature");
        frxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );
    }

    function test_sfrxETH_InvalidNonce() public {
        uint256 transfer_amount = 0.5 ether;

        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: spender,
            value: transfer_amount,
            nonce: 1, // Incorrect nonce (should be 0)
            deadline: block.timestamp + 1 days
        });

        bytes32 digest = sigUtils_sfrxETH.getTypedDataHash(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Should revert with an invalid signature message
        vm.expectRevert("INVALID_SIGNER");
        sfrxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );
    }

    function test_frxETH_InvalidNonce() public {
        uint256 transfer_amount = 0.5 ether;

        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: spender,
            value: transfer_amount,
            nonce: 1, // Incorrect nonce (should be 0)
            deadline: block.timestamp + 1 days
        });

        bytes32 digest = sigUtils_frxETH.getTypedDataHash(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Should revert with an invalid signature message
        vm.expectRevert("ERC20Permit: invalid signature");
        frxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );
    }

    function test_sfrxETH_SignatureReplay() public {
        uint256 transfer_amount = 0.5 ether;

        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: spender,
            value: transfer_amount,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        bytes32 digest = sigUtils_sfrxETH.getTypedDataHash(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Execute permit
        sfrxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );

        // Try to replay the same signature
        vm.expectRevert("INVALID_SIGNER");
        sfrxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );
    }

    function test_frxETH_SignatureReplay() public {
        uint256 transfer_amount = 0.5 ether;

        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: spender,
            value: transfer_amount,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        bytes32 digest = sigUtils_frxETH.getTypedDataHash(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Execute permit
        frxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );

        // Try to replay the same signature
        vm.expectRevert("ERC20Permit: invalid signature");
        frxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );
    }

    function test_TransferFromLimitedPermit() public {
        uint256 transfer_amount = 2 ether;

        // First deposit to get sfrxETH
        vm.startPrank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), 5 ether);
        sfrxETHtoken.deposit(5 ether, owner);
        vm.stopPrank();

        // Set up permit
        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: spender,
            value: transfer_amount,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        bytes32 digest = sigUtils_sfrxETH.getTypedDataHash(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Execute permit
        sfrxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );

        // Transfer shares using the permit
        vm.prank(spender);
        sfrxETHtoken.transferFrom(owner, spender, transfer_amount);

        // Verify transfers
        assertEq(sfrxETHtoken.balanceOf(owner), 3 ether);
        assertEq(sfrxETHtoken.balanceOf(spender), 2 ether);
        
        // Allowance should be reduced to 0
        assertEq(sfrxETHtoken.allowance(owner, spender), 0);
    }

    function test_TransferFromMaxPermit() public {
        uint256 transfer_amount = 2 ether;

        // First deposit to get sfrxETH
        vm.startPrank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), 5 ether);
        sfrxETHtoken.deposit(5 ether, owner);
        vm.stopPrank();

        // Set up max permit
        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: spender,
            value: type(uint256).max, // max approval
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        bytes32 digest = sigUtils_sfrxETH.getTypedDataHash(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Execute permit
        sfrxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );

        // Transfer shares using the permit
        vm.prank(spender);
        sfrxETHtoken.transferFrom(owner, spender, transfer_amount);

        // Verify transfers
        assertEq(sfrxETHtoken.balanceOf(owner), 3 ether);
        assertEq(sfrxETHtoken.balanceOf(spender), 2 ether);
        
        // Allowance should remain at max
        assertEq(sfrxETHtoken.allowance(owner, spender), type(uint256).max);
    }

    function test_InvalidAllowance() public {
        uint256 approve_amount = 1 ether;
        uint256 transfer_amount = 2 ether;

        // First deposit to get sfrxETH
        vm.startPrank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), 5 ether);
        sfrxETHtoken.deposit(5 ether, owner);
        vm.stopPrank();

        // Set up permit with limited allowance
        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: spender,
            value: approve_amount,
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        bytes32 digest = sigUtils_sfrxETH.getTypedDataHash(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Execute permit
        sfrxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );

        // Try to transfer more than the allowed amount
        vm.prank(spender);
        vm.expectRevert();
        sfrxETHtoken.transferFrom(owner, spender, transfer_amount); // Should fail
    }

    function test_InvalidBalance() public {
        uint256 transfer_amount = 10 ether;

        // First deposit to get sfrxETH (only 5 ETH)
        vm.startPrank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), 5 ether);
        sfrxETHtoken.deposit(5 ether, owner);
        vm.stopPrank();

        // Set up permit with high allowance
        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: owner,
            spender: spender,
            value: 20 ether, // more than what owner has
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        bytes32 digest = sigUtils_sfrxETH.getTypedDataHash(permit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Execute permit
        sfrxETHtoken.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );

        // Try to transfer more than the balance
        vm.prank(spender);
        vm.expectRevert();
        sfrxETHtoken.transferFrom(owner, spender, transfer_amount); // Should fail
    }

    // Tests for rewards distribution
    function test_totalAssetsDuringRewardDistribution() public {
        uint256 initialAmount = 5 ether;
        uint256 rewardAmount = 1 ether;
        
        // Deposit initial amount
        vm.startPrank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), initialAmount);
        sfrxETHtoken.deposit(initialAmount, owner);
        vm.stopPrank();
        
        assertEq(sfrxETHtoken.totalAssets(), initialAmount);
        
        // Mint "rewards" directly to sfrxETH contract
        vm.prank(FRAX_COMPTROLLER);
        frxETHtoken.minter_mint(address(sfrxETHtoken), rewardAmount);
        
        // Before sync, totalAssets should be the same
        assertEq(sfrxETHtoken.totalAssets(), initialAmount);
        assertEq(sfrxETHtoken.convertToAssets(initialAmount), initialAmount);
        
        // Sync rewards
        vm.warp(block.timestamp + 1000);
        sfrxETHtoken.syncRewards();
        
        // lastRewardAmount should be updated but totalAssets not yet
        assertEq(sfrxETHtoken.lastRewardAmount(), rewardAmount);
        assertEq(sfrxETHtoken.totalAssets(), initialAmount);
        
        // Move to middle of reward cycle (50%)
        vm.warp(block.timestamp + 500);
        
        // Half of rewards should be accrued
        assertEq(sfrxETHtoken.totalAssets(), initialAmount + (rewardAmount / 2));
        assertEq(sfrxETHtoken.convertToAssets(initialAmount), initialAmount + (rewardAmount / 2));
        
        // Move to end of reward cycle
        vm.warp(block.timestamp + 500); // total of 1000 seconds elapsed
        
        // All rewards should now be accrued
        assertEq(sfrxETHtoken.totalAssets(), initialAmount + rewardAmount);
        assertEq(sfrxETHtoken.convertToAssets(initialAmount), initialAmount + rewardAmount);
        
        // Price per share should reflect new value
        // (initialAmount + rewardAmount) / initialAmount * 1e18
        assertEq(sfrxETHtoken.pricePerShare(), 1.2e18);
    }

    function test_delayedRewardDistribution() public {
        uint256 initialAmount = 5 ether;
        uint256 rewardAmount = 1 ether;
        
        // Deposit initial amount
        vm.startPrank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), initialAmount);
        sfrxETHtoken.deposit(initialAmount, owner);
        vm.stopPrank();
        
        // Start halfway through a cycle
        vm.warp(block.timestamp + 1000);
        
        // Mint "rewards" directly to sfrxETH contract
        vm.prank(FRAX_COMPTROLLER);
        frxETHtoken.minter_mint(address(sfrxETHtoken), rewardAmount);
        
        // Sync rewards
        sfrxETHtoken.syncRewards();
        
        // lastRewardAmount should be updated but totalAssets not yet
        vm.warp(block.timestamp + 500);
        assertEq(sfrxETHtoken.lastRewardAmount(), rewardAmount);
        assertEq(sfrxETHtoken.totalAssets(), initialAmount + (rewardAmount/2));
        
        // Half of rewards should be accrued 
        vm.warp(block.timestamp + 500);
        assertEq(sfrxETHtoken.totalAssets(), initialAmount + (rewardAmount));
    }

    function test_multipleRewardCycles() public {
        uint256 initialAmount = 5 ether;
        uint256 reward1 = 1 ether;
        uint256 reward2 = 2 ether;
        
        // Deposit initial amount
        vm.startPrank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), initialAmount);
        sfrxETHtoken.deposit(initialAmount, owner);
        vm.stopPrank();
        
        // Cycle 1: Add first reward and sync
        vm.prank(FRAX_COMPTROLLER);
        // Fast forward to end of first cycle
        vm.warp(block.timestamp + 1000);
        frxETHtoken.minter_mint(address(sfrxETHtoken), reward1);
        sfrxETHtoken.syncRewards();
        
        
        
        // All of reward1 should be distributed
        vm.warp(block.timestamp + 1000);
        assertEq(sfrxETHtoken.totalAssets(), initialAmount + reward1);
        
        // Cycle 2: Add second reward and sync
        vm.prank(FRAX_COMPTROLLER);
        frxETHtoken.minter_mint(address(sfrxETHtoken), reward2);
        vm.warp(block.timestamp + 1000);
        sfrxETHtoken.syncRewards();
        
        // Immediately after sync, totalAssets should include all of reward1
        vm.warp(block.timestamp + 500);
        assertEq(sfrxETHtoken.totalAssets(), initialAmount + reward1 + (reward2/2));

        // All of reward1 and reward2 should be accrued
        vm.warp(block.timestamp + 1000);
        assertEq(sfrxETHtoken.totalAssets(), initialAmount + reward1 + reward2);
        
        // Final price per share calculation
        // (initialAmount + reward1 + reward2) / initialAmount * 1e18
        assertEq(sfrxETHtoken.pricePerShare(), 1.6e18);
    }

    function test_deposit_after_rewards() public {
        uint256 initialAmount = 5 ether;
        uint256 rewardAmount = 1 ether;
        uint256 secondDeposit = 2 ether;
        
        // First user deposits
        vm.startPrank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), initialAmount);
        sfrxETHtoken.deposit(initialAmount, owner);
        vm.stopPrank();
        
        // Add rewards
        vm.prank(FRAX_COMPTROLLER);
        frxETHtoken.minter_mint(address(sfrxETHtoken), rewardAmount);
        
        // Sync and complete reward cycle
        vm.warp(block.timestamp + 1000);
        sfrxETHtoken.syncRewards();
        
        // Second user deposits after rewards accrue
        // Mint some frxETH to the spender for the second deposit
        vm.prank(FRAX_COMPTROLLER);
        frxETHtoken.minter_mint(spender, secondDeposit);
        
        // Approve and deposit
        vm.startPrank(spender);
        frxETHtoken.approve(address(sfrxETHtoken), secondDeposit);

        vm.warp(block.timestamp + 1000);
        sfrxETHtoken.syncRewards();
        
        // Calculate expected shares
        // 2 ETH * 5 ETH / (5 ETH + 1 ETH) = 1.6667 ETH of shares
        vm.warp(block.timestamp + 1000);
        uint256 expectedShares = (secondDeposit * initialAmount) / (initialAmount + rewardAmount);
        
        // Deposit and check shares received
        uint256 shares = sfrxETHtoken.deposit(secondDeposit, spender);
        assertEq(shares, expectedShares);
        vm.stopPrank();
        
        // Total assets should be updated
        
        assertEq(sfrxETHtoken.totalAssets(), initialAmount + rewardAmount + secondDeposit);
        
        // Check share balances
        assertEq(sfrxETHtoken.balanceOf(owner), initialAmount);
        assertEq(sfrxETHtoken.balanceOf(spender), expectedShares);
    }

    function test_withdrawTooMuch() public {
        // Deposit some frxETH first
        vm.startPrank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), 5 ether);
        sfrxETHtoken.deposit(5 ether, owner);
        
        // Try to withdraw more than deposited
        vm.expectRevert();
        sfrxETHtoken.withdraw(6 ether, owner, owner);
        // Should fail
    }

    function test_syncRewardsDuringCycle() public {
        // Deposit initial amount
        vm.startPrank(owner);
        frxETHtoken.approve(address(sfrxETHtoken), 5 ether);
        sfrxETHtoken.deposit(5 ether, owner);
        vm.stopPrank();
        
        // Add rewards
        vm.prank(FRAX_COMPTROLLER);
        frxETHtoken.minter_mint(address(sfrxETHtoken), 1 ether);
        
        // Sync rewards
        vm.warp(block.timestamp + 1000);
        sfrxETHtoken.syncRewards();
        
        // Try to sync again during the cycle (should fail)
        vm.expectRevert();
        sfrxETHtoken.syncRewards();
    }
} 