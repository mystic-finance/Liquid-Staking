//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol"; // Gives vm and console
import 'forge-std/console.sol';
import {MyPlumeFeed} from "../src/Periphery/MyPlumeFeed.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract Deploy is Script {
    address constant deployer = 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c;

    function run() public {
        console.log('Deployer:', deployer);
        vm.startBroadcast(deployer);

        ProxyAdmin admin = ProxyAdmin(0x99E18E728497c4732b68D27417A8b7e4dcf70080);
        // Encode initializer
        MyPlumeFeed impl = new MyPlumeFeed();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), address(admin), bytes(""));
        MyPlumeFeed feed = MyPlumeFeed(payable(address(proxy)));
        feed.initialize(address(0xc2387E0feA344D1edEC3E93Bf2124f909f74938C), address(0xAD8874006ee4EBe311066E47c650A74171b8F624), address(0x6B9D6efF3f9B15b0655C5f5c2f27Fcc9A87f9087), address(0x30c791E4654EdAc575FA1700eD8633CB2FEDE871));

        console.log('Deployer:', deployer);
        console.log("Feed deployed at", address(feed));
        vm.stopBroadcast();
    }
}

// == Logs ==
//   Deployer: 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c
//   Feed deployed at 0xc2099DE332E4220E72a140427b34b8aa4D54c50C


// == Logs ==
//   Deployer: 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c
//   Feed deployed at 0xC615fc6c1BA3FB447ebd8f0A778878Ec0d4C1d3D

//  Deployer: 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c
//   Feed deployed at 0xFbb53aa72c10680e822e255aC70D10f8bb957D64