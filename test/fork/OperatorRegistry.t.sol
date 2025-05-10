// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/OperatorRegistry.sol";

contract OperatorRegistryForkTest is Test {
    OperatorRegistry registry;
    address owner = address(0x1234);
    address timelock = address(0x5678);

    function setUp() public {
        
        // Deploy registry
        registry = new OperatorRegistry(owner, timelock);
    }

    function test_constructor() public {
        assertEq(registry.owner(), owner);
        assertEq(registry.timelock_address(), timelock);
    }

    function test_addValidator() public {
        vm.prank(owner);
        registry.addValidator(OperatorRegistry.Validator(1));
        
        assertEq(registry.numValidators(), 1);
        
        (uint256 validatorId) = registry.getValidator(0);
        assertEq(validatorId, 1);
    }

    function test_addValidators() public {
        vm.startPrank(owner);
        
        OperatorRegistry.Validator[] memory validators = new OperatorRegistry.Validator[](2);
        validators[0] = OperatorRegistry.Validator(1);
        validators[1] = OperatorRegistry.Validator(2);
        
        registry.addValidators(validators);
        vm.stopPrank();
        
        assertEq(registry.numValidators(), 2);
        
        (uint256 validatorId1) = registry.getValidator(0);
        (uint256 validatorId2) = registry.getValidator(1);
        
        assertEq(validatorId1, 1);
        assertEq(validatorId2, 2);
    }

    function test_swapValidator() public {
        vm.startPrank(owner);
        
        // Add validators
        registry.addValidator(OperatorRegistry.Validator(1));
        registry.addValidator(OperatorRegistry.Validator(2));
        
        // Swap them
        registry.swapValidator(0, 1);
        vm.stopPrank();
        
        // Check the array after swap
        (uint256 validatorId1) = registry.getValidator(0);
        (uint256 validatorId2) = registry.getValidator(1);
        
        assertEq(validatorId1, 2);
        assertEq(validatorId2, 1);
    }

    function test_popValidators() public {
        vm.startPrank(owner);
        
        // Add validators
        registry.addValidator(OperatorRegistry.Validator(1));
        registry.addValidator(OperatorRegistry.Validator(2));
        registry.addValidator(OperatorRegistry.Validator(3));
        
        // Pop two validators
        registry.popValidators(2);
        vm.stopPrank();
        
        // Check array length
        assertEq(registry.numValidators(), 1);
        
        // Check remaining validator
        (uint256 validatorId) = registry.getValidator(0);
        assertEq(validatorId, 1);
    }

    function test_removeValidatorSwapAndPop() public {
        vm.startPrank(owner);
        
        // Add validators
        registry.addValidator(OperatorRegistry.Validator(1));
        registry.addValidator(OperatorRegistry.Validator(2));
        registry.addValidator(OperatorRegistry.Validator(3));
        
        // Remove the validator at index 1 (don't care about ordering)
        registry.removeValidator(1, true);
        vm.stopPrank();
        
        // Check array length
        assertEq(registry.numValidators(), 2);
        
        // Check remaining validators (validator 3 should be swapped to position 1)
        (uint256 validatorId1) = registry.getValidator(0);
        (uint256 validatorId2) = registry.getValidator(1);
        
        assertEq(validatorId1, 1);
        assertEq(validatorId2, 3);
    }

    function test_removeValidatorKeepOrdering() public {
        vm.startPrank(owner);
        
        // Add validators
        registry.addValidator(OperatorRegistry.Validator(1));
        registry.addValidator(OperatorRegistry.Validator(2));
        registry.addValidator(OperatorRegistry.Validator(3));
        
        // Remove the validator at index 1 (keep ordering)
        registry.removeValidator(1, false);
        vm.stopPrank();
        
        // Check array length
        assertEq(registry.numValidators(), 2);
        
        // Check remaining validators (validator 3 should be moved to position 1)
        (uint256 validatorId1) = registry.getValidator(0);
        (uint256 validatorId2) = registry.getValidator(1);
        
        assertEq(validatorId1, 1);
        assertEq(validatorId2, 3);
    }

    function test_clearValidatorArray() public {
        vm.startPrank(owner);
        
        // Add validators
        registry.addValidator(OperatorRegistry.Validator(1));
        registry.addValidator(OperatorRegistry.Validator(2));
        
        // Clear the array
        registry.clearValidatorArray();
        vm.stopPrank();
        
        // Check array length
        assertEq(registry.numValidators(), 0);
    }

    function test_setTimelock() public {
        address newTimelock = address(0xABCD);
        
        vm.prank(owner);
        registry.setTimelock(newTimelock);
        
        assertEq(registry.timelock_address(), newTimelock);
    }

    function test_onlyByOwnGov() public {
        // Try to add a validator as a non-owner/non-timelock address
        vm.prank(address(0x9999));
        vm.expectRevert();
        registry.addValidator(OperatorRegistry.Validator(1));
    }
} 