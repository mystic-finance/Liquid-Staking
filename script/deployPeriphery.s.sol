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

        ProxyAdmin admin = ProxyAdmin(0xB7791d7039284c2021C0F77120C84609B03BB2E9);
        // Encode initializer
        MyPlumeFeed impl = new MyPlumeFeed();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), address(admin), bytes(""));
        MyPlumeFeed feed = MyPlumeFeed(payable(address(proxy)));
        feed.initialize(address(0x5c982097b505A3940823a11E6157e9C86aF08987), address(0xE4274Bc25BA313364DE71F104acF27746c6278Cb), address(0x2E420ac76a43fC94F05168Cb8DCf4996b717dA17), address(0x30c791E4654EdAc575FA1700eD8633CB2FEDE871));

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