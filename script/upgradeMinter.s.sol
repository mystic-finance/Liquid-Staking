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
    address constant deployer = 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c;

    function run() public {
        console.log('Deployer:', deployer);
        vm.startBroadcast(deployer);

        ProxyAdmin admin = ProxyAdmin(0x99E18E728497c4732b68D27417A8b7e4dcf70080);
        stPlumeMinter impl = new stPlumeMinter();
        TransparentUpgradeableProxy proxy = TransparentUpgradeableProxy(payable(address(0xAD8874006ee4EBe311066E47c650A74171b8F624)));
        admin.upgrade(proxy, address(impl));
        
        vm.stopBroadcast();
    }
}