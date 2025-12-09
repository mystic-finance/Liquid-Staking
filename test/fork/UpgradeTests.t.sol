// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/stPlumeMinter.sol";
import "../../src/frxETH.sol";
import "../../src/sfrxETH.sol";
import "../../src/OperatorRegistry.sol";
import "../../src/stPlumeRewards.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// Mock updated implementation for testing upgrades
contract stPlumeMinterV2 is stPlumeMinter {
    // New state variable
    uint256 public newFeature;
    
    // New function to demonstrate upgrade
    function setNewFeature(uint256 _value) external onlyByOwnGov {
        newFeature = _value;
    }
    
    // Override existing function to demonstrate changes
    function setNewFees(uint256 newInstantFee, uint256 newStandardFee) external onlyByOwnGov {
        require(newInstantFee <= 500000 && newStandardFee <= 500000, "Fees too high in V2");
        INSTANT_REDEMPTION_FEE = newInstantFee;
        REDEMPTION_FEE = newStandardFee;
    }
}

contract UpgradeTests is Test {
    // Core contracts
    ProxyAdmin public admin;
    stPlumeMinter public minterImplementation;
    stPlumeMinter public minter;
    stPlumeRewards public rewardsImplementation;
    stPlumeRewards public rewards;
    frxETH public frxETHToken;
    
    // Mock contracts
    IPlumeStaking public mockPlumeStaking;
    
    // Addresses
    address public owner = address(0x1234);
    address public timelock = address(0x5678);
    address public user = address(0x9ABC);
    
    event Upgraded(address indexed implementation);
    
    function setUp() public {
        // Deploy mock PlumeStaking
        mockPlumeStaking =  IPlumeStaking(0x30c791E4654EdAc575FA1700eD8633CB2FEDE871);
        vm.deal(address(mockPlumeStaking), 100 ether);
        vm.deal(address(user), 10000 ether);
        
        // Deploy frxETH token
        frxETHToken = new frxETH(owner, timelock);

        vm.deal(address(user), 10000 ether);
        
        // Setup ProxyAdmin
        vm.startPrank(owner);
        admin = new ProxyAdmin();
        vm.stopPrank();
    }
    
    function test_initialProxySetup() public {
        // Deploy implementation contracts
        minterImplementation = new stPlumeMinter();
        rewardsImplementation = new stPlumeRewards();
        
        // Setup proxies
        vm.startPrank(owner);
        
        // Deploy minter proxy
        TransparentUpgradeableProxy minterProxy = new TransparentUpgradeableProxy(
            address(minterImplementation),
            address(admin),
            bytes("")
        );
        minter = stPlumeMinter(payable(address(minterProxy)));
        minter.initialize(address(frxETHToken), owner, timelock, address(mockPlumeStaking));
        
        // Deploy rewards proxy
        TransparentUpgradeableProxy rewardsProxy = new TransparentUpgradeableProxy(
            address(rewardsImplementation),
            address(admin),
            bytes("")
        );
        rewards = stPlumeRewards(payable(address(rewardsProxy)));
        rewards.initialize(address(frxETHToken), address(minter), owner);
        
        // Setup connections
        minter.setStPlumeRewards(address(rewards));
        frxETHToken.addMinter(address(minter));
        frxETHToken.updateStPlumeRewards(address(rewards));
        
        vm.stopPrank();
        // Verify initialization
        assertEq(address(minter.frxETHToken()), address(frxETHToken));
        assertTrue(minter.hasRole(0x00, owner)); // DEFAULT_ADMIN_ROLE
        
        // Check implementation addresses
        assertEq(admin.getProxyImplementation(TransparentUpgradeableProxy(payable(address(minter)))), address(minterImplementation));
        assertEq(admin.getProxyImplementation(TransparentUpgradeableProxy(payable(address(rewards)))), address(rewardsImplementation));
    }
    
    function test_statePreservationDuringUpgrade() public {
        // First setup the proxies
        test_initialProxySetup();
        
        // Configure initial state
        vm.startPrank(owner);
        minter.setFees(2000, 100); // Set some fees
        
        // Add validators
        OperatorRegistry.Validator[] memory validators = new OperatorRegistry.Validator[](2);
        validators[0] = OperatorRegistry.Validator(1);
        validators[1] = OperatorRegistry.Validator(2);
        minter.addValidators(validators);
        vm.stopPrank();

        vm.startPrank(user);
        minter.submit{value: 100 ether}();
        vm.stopPrank();
        
        // Deploy upgraded implementation
        stPlumeMinterV2 newImplementation = new stPlumeMinterV2();
        
        // Perform upgrade
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, false);
        emit Upgraded(address(newImplementation));
        admin.upgrade(TransparentUpgradeableProxy(payable(address(minter))), address(newImplementation));
        vm.stopPrank();
        
        // Create interface to V2 functions
        stPlumeMinterV2 minterV2 = stPlumeMinterV2(payable(address(minter)));
        
        // Check state is preserved
        assertEq(minterV2.INSTANT_REDEMPTION_FEE(), 2000);
        assertEq(minterV2.REDEMPTION_FEE(), 100);
        assertEq(minterV2.numValidators(), 2);
        assertEq(minterV2.currentWithheldETH(), 2 ether);

        vm.startPrank(user);
        frxETHToken.approve(address(minterV2), 50 ether);
        minterV2.unstake(50 ether);
        vm.stopPrank();

        vm.warp(minterV2.nextBatchUnstakeTimePerValidator(1));
        vm.startPrank(owner);
        minterV2.processBatchUnstake();
        vm.stopPrank();

        (,, uint256 requestTimestamp,) = minterV2.withdrawalRequests(user, 0);
        vm.warp(requestTimestamp);
        vm.prank(user);
        minterV2.withdraw(user, 0);
        
        // Check we can use new functionality
        vm.prank(owner);
        minterV2.setNewFeature(42);
        assertEq(minterV2.newFeature(), 42);
    }
    
    function test_upgradeAndNewBehavior() public {
        // Setup initial proxy
        test_initialProxySetup();
        vm.prank(owner);
        minter.setFees(500001, 10000); // should work
        
        // Deploy upgraded implementation with new features
        stPlumeMinterV2 newImplementation = new stPlumeMinterV2();
        
        // Perform upgrade
        vm.prank(owner);
        admin.upgrade(TransparentUpgradeableProxy(payable(address(minter))), address(newImplementation));
        
        // Cast to V2 to access new functions
        stPlumeMinterV2 minterV2 = stPlumeMinterV2(payable(address(minter)));
        
        // Test new feature
        vm.startPrank(owner);
        minterV2.setNewFeature(999);
        assertEq(minterV2.newFeature(), 999);
        
        // Test modified behavior
        vm.expectRevert("Fees too high in V2");
        minterV2.setNewFees(500001, 100); // Will revert in V2 due to new validation
        
        // This should work
        minterV2.setNewFees(400000, 100);
        assertEq(minterV2.INSTANT_REDEMPTION_FEE(), 400000);
        vm.stopPrank();
    }
    
    function test_unauthorizedUpgrade() public {
        // Setup initial proxy
        test_initialProxySetup();
        
        // Deploy upgraded implementation
        stPlumeMinterV2 newImplementation = new stPlumeMinterV2();
        
        // Attempt unauthorized upgrade from user
        vm.startPrank(user);
        vm.expectRevert(); // Should revert as user is not admin
        admin.upgrade(TransparentUpgradeableProxy(payable(address(minter))), address(newImplementation));
        vm.stopPrank();
        
        // Verify implementation hasn't changed
        assertEq(
            admin.getProxyImplementation(TransparentUpgradeableProxy(payable(address(minter)))), 
            address(minterImplementation)
        );
    }
    
    function test_upgradeRewardsContract() public {
        // Setup initial proxies
        test_initialProxySetup();
        
        // Create new rewards implementation
        stPlumeRewards newRewardsImpl = new stPlumeRewards();
        
        // Perform upgrade on rewards
        vm.prank(owner);
        admin.upgrade(TransparentUpgradeableProxy(payable(address(rewards))), address(newRewardsImpl));
        
        // Verify implementation updated
        assertEq(
            admin.getProxyImplementation(TransparentUpgradeableProxy(payable(address(rewards)))), 
            address(newRewardsImpl)
        );
        
    }

    function test_upgradeMainnetContracts() public {
        // Setup initial proxies
       // Deploy upgraded implementation
        admin = ProxyAdmin(0x99E18E728497c4732b68D27417A8b7e4dcf70080);
        minter = stPlumeMinter(payable(0xAD8874006ee4EBe311066E47c650A74171b8F624));
        owner = 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c;

        vm.prank(user);
        minter.submit{value: 100 ether}();

        vm.prank(owner);
        minter.togglePauseDepositEther();


        stPlumeMinter newImplementation = new stPlumeMinter();
        uint withholdEth = minter.withHoldEth();
        uint validators = minter.numValidators();
        uint currentWithheldETH = minter.currentWithheldETH();
        uint withholdRatio = minter.withholdRatio();
        uint redemptionFee = minter.REDEMPTION_FEE();

        // Perform upgrade
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, false);
        emit Upgraded(address(newImplementation));
        admin.upgrade(TransparentUpgradeableProxy(payable(address(minter))), address(newImplementation));
        vm.stopPrank();
               
        // Check state is preserved
        assertEq(minter.withHoldEth(), withholdEth);
        assertEq(minter.withholdRatio(), withholdRatio);
        assertEq(minter.REDEMPTION_FEE(), redemptionFee);
        assertEq(minter.numValidators(), validators);
        assertEq(minter.currentWithheldETH(), currentWithheldETH);
        assertEq(minter.depositEtherPaused(), true);

        vm.prank(owner);
        minter.grantRole(keccak256("PAUSER_ROLE"), owner);
        vm.prank(owner);
        minter.togglePauseDepositEther();

        vm.startPrank(user);
        frxETHToken.approve(address(minter), 50 ether);
        minter.unstake(50 ether);
        vm.stopPrank();

        vm.warp(minter.nextBatchUnstakeTimePerValidator(1));
        vm.startPrank(owner);
        minter.processBatchUnstake();
        vm.stopPrank();

        (,, uint256 requestTimestamp,) = minter.withdrawalRequests(user, 0);
        vm.warp(requestTimestamp);
        vm.prank(user);
        minter.withdraw(user, 0);

        vm.prank(owner);
        minter.grantRole(keccak256("PAUSER_ROLE"), user);

        vm.prank(user);
        minter.togglePauseDepositEther();
    }
    
    function test_proxyAdminTransfer() public {
        // Setup initial proxies
        test_initialProxySetup();
        
        address newAdmin = address(0xABCD);
        
        // Transfer admin rights
        vm.prank(owner);
        admin.transferOwnership(newAdmin);
        
        assertEq(admin.owner(), newAdmin);
        
        // Old admin can no longer upgrade
        vm.startPrank(owner);
        stPlumeMinterV2 newImplementation = new stPlumeMinterV2();
        vm.expectRevert();
        admin.upgrade(TransparentUpgradeableProxy(payable(address(minter))), address(newImplementation));
        vm.stopPrank();
        
        // New admin can upgrade
        vm.startPrank(newAdmin);
        stPlumeMinterV2 newImpl = new stPlumeMinterV2();
        admin.upgrade(TransparentUpgradeableProxy(payable(address(minter))), address(newImpl));
        vm.stopPrank();
        
        // Verify upgrade was successful
        assertEq(
            admin.getProxyImplementation(TransparentUpgradeableProxy(payable(address(minter)))),
            address(newImpl)
        );
    }
}