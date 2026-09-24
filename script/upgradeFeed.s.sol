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
        MyPlumeFeed feed = MyPlumeFeed(payable(address(0xFbb53aa72c10680e822e255aC70D10f8bb957D64)));
        console.log(string.concat('Price before: ', vm.toString(feed.getMyPlumePrice())));

        vm.startBroadcast(deployer);

        ProxyAdmin admin = ProxyAdmin(0x99E18E728497c4732b68D27417A8b7e4dcf70080);
        MyPlumeFeed impl = new MyPlumeFeed();
        TransparentUpgradeableProxy proxy = TransparentUpgradeableProxy(payable(address(feed)));
        admin.upgrade(proxy, address(impl));

        vm.stopBroadcast();

        console.log('Feed impl deployed at', address(impl));
        console.log(string.concat('Price after: ', vm.toString(feed.getMyPlumePrice())));
    }
}
