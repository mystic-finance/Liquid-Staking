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
        
        OperatorRegistry.Validator[] memory validators = new OperatorRegistry.Validator[](5);
        validators[0] = OperatorRegistry.Validator(3);
        validators[1] = OperatorRegistry.Validator(9);
        validators[2] = OperatorRegistry.Validator(8);
        validators[3] = OperatorRegistry.Validator(5);
        validators[4] = OperatorRegistry.Validator(1);
        // Post deploy
        console.log('Deployer:', deployer);
        fe.addMinter(address(fem));
        fem.setStPlumeRewards(address(femRewards));
        fe.updateStPlumeRewards(address(femRewards));
        fem.addValidators(validators);
        femRewards.grantRole(femRewards.MINTER_ROLE(), 0x0402447db83Fc8c30c3E36DaA03E9a59d2eAb453); //approve keeper

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

// Mainnet Test Final
// Deployer: 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c
//   Deployer: 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c
//   Minter deployed at 0xd19dE4F03e5F255292339c16E3EA3b39c3480677
//   Minter added to frxETH at 0xC0Aa9d797d79953CD56B042166fd39C124b40a08
//   Minter added to frETh Rewards at 0x82839Ac47C6B4f66f5e8d6b45EF23f25CB669faa
//   Proxy admin is at 0x70FBa7741DF916286F6841919AD48E42ecD72277

// Mainnet Main
// == Logs ==
//   Deployer: 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c
//   Deployer: 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c
//   Minter deployed at 0xE4274Bc25BA313364DE71F104acF27746c6278Cb
//   Minter added to frxETH at 0x5c982097b505A3940823a11E6157e9C86aF08987
//   Minter added to frETh Rewards at 0x2E420ac76a43fC94F05168Cb8DCf4996b717dA17
//   Proxy admin is at 0xB7791d7039284c2021C0F77120C84609B03BB2E9

