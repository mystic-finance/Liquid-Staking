//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol"; // Gives vm and console
import 'forge-std/console.sol';
import {frxETH} from "../src/frxETH.sol";
import {sfrxETH, ERC20} from "../src/sfrxETH.sol";
import {stPlumeMinter} from "../src/stPlumeMinter.sol";
import {stPlumeRewards} from "../src/stPlumeRewards.sol";
import {OperatorRegistry} from "../src/OperatorRegistry.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract Deploy is Script {
    address constant TIMELOCK_ADDRESS = 0x474302838E35DfC33967bA99AbbcB7560D48C634;
    uint32 constant REWARDS_CYCLE_LENGTH = 7 days;
    address constant PLUME_STAKING = 0x30c791E4654EdAc575FA1700eD8633CB2FEDE871;
    address constant deployer = 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c;

    function run() public {
        console.log('Deployer:', deployer);
        vm.startBroadcast(deployer);

        frxETH fe = new frxETH(deployer, TIMELOCK_ADDRESS);
        // // sfrxETH sfe = new sfrxETH(ERC20(address(fe)), REWARDS_CYCLE_LENGTH);
        ProxyAdmin admin = new ProxyAdmin();
        // Encode initializer
        stPlumeMinter impl = new stPlumeMinter();
        // bytes memory initData = abi.encodeWithSignature("initialize(address,address, address, address, address)", address(fe), address(0), msg.sender, TIMELOCK_ADDRESS, PLUME_STAKING);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), address(admin), bytes(""));
        stPlumeMinter fem = stPlumeMinter(payable(address(proxy)));
        fem.initialize(address(fe), deployer, TIMELOCK_ADDRESS, PLUME_STAKING);

        stPlumeRewards implRewards = new stPlumeRewards();
        // bytes memory initData2 = abi.encodeWithSignature("initialize(address,address, address)", address(fe), address(fem), msg.sender);
        TransparentUpgradeableProxy proxyRewards = new TransparentUpgradeableProxy(address(implRewards), address(admin), bytes(""));
        stPlumeRewards femRewards = stPlumeRewards(payable(address(proxyRewards)));
        femRewards.initialize(address(fe), address(fem), deployer);
        
        OperatorRegistry.Validator[] memory validators = new OperatorRegistry.Validator[](2);
        validators[0] = OperatorRegistry.Validator(1);
        validators[1] = OperatorRegistry.Validator(2);
        // validators[2] = OperatorRegistry.Validator(3);
        // validators[3] = OperatorRegistry.Validator(4);
        // validators[4] = OperatorRegistry.Validator(5);
        // Post deploy
        console.log('Deployer:', deployer);
        fe.addMinter(address(fem));
        fem.setStPlumeRewards(address(femRewards));
        fe.updateStPlumeRewards(address(femRewards));
        fem.addValidators(validators);

        console.log("Minter deployed at", address(fem));
        console.log("Minter added to frxETH at", address(fe));
        console.log("Minter added to frETh Rewards at", address(femRewards));
        
        vm.stopBroadcast();
    }
}



// == Logs ==
//   Deployer: 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c
//   Deployer: 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c
//   Minter deployed at 0x72E6Dcc8E45e6a770e45A4C23F8cBb6536064F67
//   Minter added to frxETH at 0x11A4aC7b41F0981cB9Cc75833ed45CdF907b48A1
//   Minter added to sfrxETH at 0x0D1e28744849a254D1730Ae898aBFB73eC393e64


// Mainnet test
// == Logs ==
//   Deployer: 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c
//   Deployer: 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c
//   Minter deployed at 0x8F74472cfCc3c2fDadc7CBbF761bde38349Fa4D6
//   Minter added to frxETH at 0xc8F76806482007C73Ee4d88D9B9B78C622c03e6C

// mainnet test 2
// == Logs ==
//   Deployer: 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c
//   Deployer: 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c
//   Minter deployed at 0x253b9DdAE24F43F4F59507Fbd497d7d713563393
//   Minter added to frxETH at 0x24D9a443D293Ab977E1fb723072408b5BA54F20b
//   Minter added to frETh Rewards at 0xf0F16fCf0757D604E2e0c1EC2C0B50fd045b3D15