//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol"; // Gives vm and console
import 'forge-std/console.sol';
import "openzeppelin-contracts/contracts/finance/PaymentSplitter.sol";

contract Deploy is Script {
    address constant deployer = 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c;

    function run() public {
        console.log('Deployer:', deployer);
        vm.startBroadcast(deployer);

        address[] memory recipients = new address[](2);
        recipients[0] = 0x0F44298b5C26259425f982F8Fe5eEE1C30FaBBe4; //mystic
        recipients[1] = 0x6f8e88a87E6A58D3588B6f224459D56B674f7075; //edge
        // recipients[2] = 0x7bfE10c32321B01b049a1F79757B1b3e1E973096; //plume
        // recipients[3] = 0xfa69E8D0591A6871E879f6a66fd5c05bCA2262b3; //cicada

        uint256[] memory shares = new uint256[](2);
        shares[0] = 33330000;
        shares[1] = 66670000;
        // shares[2] = 10000000;
        // shares[3] = 15000000;
        
        PaymentSplitter paymentSplitter = new PaymentSplitter(recipients, shares);

        console.log("PaymentSplitter deployed", address(paymentSplitter));
        
        vm.stopBroadcast();
    }
}