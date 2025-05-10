//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol"; // Gives vm and console
import 'forge-std/console.sol';
import {frxETH} from "../src/frxETH.sol";
import {sfrxETH, ERC20} from "../src/sfrxETH.sol";
import {stPlumeMinter} from "../src/stPlumeMinter.sol";

contract Deploy is Script {
    address constant TIMELOCK_ADDRESS = 0x8412ebf45bAC1B340BbE8F318b928C466c4E39CA;
    uint32 constant REWARDS_CYCLE_LENGTH = 3 days;
    address constant PLUME_STAKING = 0xA20bfe49969D4a0E9abfdb6a46FeD777304ba07f;

    function run() public {
        console.log('Deployer:', msg.sender);
        vm.startBroadcast();

        frxETH fe = new frxETH(msg.sender, TIMELOCK_ADDRESS);
        sfrxETH sfe = new sfrxETH(ERC20(address(fe)), REWARDS_CYCLE_LENGTH);
        stPlumeMinter fem = new stPlumeMinter(address(fe), address(sfe), msg.sender, TIMELOCK_ADDRESS, PLUME_STAKING);
        
        // Post deploy
        console.log('Deployer:', msg.sender);
        fe.addMinter(address(fem));

        console.log("Minter deployed at", address(fem));
        console.log("Minter added to frxETH at", address(fe));
        console.log("Minter added to sfrxETH at", address(sfe));
        
        vm.stopBroadcast();
    }
}



// == Logs ==
//   Deployer: 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c
//   Deployer: 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c
//   Minter deployed at 0x72E6Dcc8E45e6a770e45A4C23F8cBb6536064F67
//   Minter added to frxETH at 0x11A4aC7b41F0981cB9Cc75833ed45CdF907b48A1
//   Minter added to sfrxETH at 0x0D1e28744849a254D1730Ae898aBFB73eC393e64