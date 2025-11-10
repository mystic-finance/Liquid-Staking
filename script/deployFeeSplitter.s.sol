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

        address[] memory recipients = new address[](4);
        recipients[0] = 0x6FE60Cb3F305d0A03d6432F5fAab4eb78e0c1F31; //mev
        recipients[1] = 0x5D845540D2e05422E8ef10CEDEd7C0bFB5Aac4A2; //mystic
        recipients[2] = 0x7bfE10c32321B01b049a1F79757B1b3e1E973096; //plume
        recipients[3] = 0xfa69E8D0591A6871E879f6a66fd5c05bCA2262b3; //cicada

        uint256[] memory shares = new uint256[](4);
        shares[0] = 37500000;
        shares[1] = 37500000;
        shares[2] = 10000000;
        shares[3] = 15000000;
        
        PaymentSplitter paymentSplitter = new PaymentSplitter(recipients, shares);

        console.log("PaymentSplitter deployed", address(paymentSplitter));
        
        vm.stopBroadcast();
    }
}