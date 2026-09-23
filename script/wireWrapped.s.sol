//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import 'forge-std/console.sol';
import { frxETH } from "../src/frxETH.sol";

interface ITimelock {
    function PROPOSER_ROLE() external view returns (bytes32);
    function EXECUTOR_ROLE() external view returns (bytes32);
    function CANCELLER_ROLE() external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getMinDelay() external view returns (uint256);
}

interface IRewards {
    function MINTER_ROLE() external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @notice Wires the permissions the wMyPlume recycle keeper needs.
///
///  1. myPLUME.addMinter(timelock)          — the unbounded minting right sits behind the
///                                            24h delay. The keeper NEVER gets it.
///  2. timelock.grantRole(PROPOSER, keeper) — keeper can schedule minter_mint(vault, owed)
///  3. timelock.grantRole(EXECUTOR, keeper) — keeper can execute it after the delay
///  4. rewards.grantRole(MINTER_ROLE, keeper) — keeper can call resetUserRewardsAfterClaim
///  5. timelock.grantRole(CANCELLER, guardian) — so a bad proposal can be stopped in the window
///
/// Set KEEPER and GUARDIAN below before running. Every step is skipped if already granted.
contract Wire is Script {
    address constant deployer = 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c;

    address constant MYPLUME  = 0xc2387E0feA344D1edEC3E93Bf2124f909f74938C;
    address constant TIMELOCK = 0x474302838E35DfC33967bA99AbbcB7560D48C634;
    address constant REWARDS  = 0x6B9D6efF3f9B15b0655C5f5c2f27Fcc9A87f9087;

    // >>> SET THESE <<<
    address constant KEEPER   = 0x9149375776CdbB08674fa2b4Ed69da6235DE97A8; // runs recycleVaultRewards.js
    address constant GUARDIAN = 0x5D845540D2e05422E8ef10CEDEd7C0bFB5Aac4A2; // Safe 1.3.0, 3-of-5

    function run() public {
        frxETH token = frxETH(MYPLUME);
        ITimelock timelock = ITimelock(TIMELOCK);
        IRewards rewards = IRewards(REWARDS);

        require(KEEPER != address(0), "set KEEPER");
        require(!token.minters(KEEPER), "keeper must NOT be a myPLUME minter");

        console.log("deployer:", deployer);
        console.log("keeper:  ", KEEPER);
        console.log("timelock delay:", timelock.getMinDelay());

        vm.startBroadcast(deployer);

        // 1. the timelock becomes the myPLUME minter
        if (!token.minters(TIMELOCK)) {
            token.addMinter(TIMELOCK);
            console.log("granted: myPLUME minter -> timelock");
        } else {
            console.log("skip: timelock is already a myPLUME minter");
        }

        // 2 + 3. keeper may schedule and execute on the timelock
        bytes32 proposer = timelock.PROPOSER_ROLE();
        bytes32 executor = timelock.EXECUTOR_ROLE();
        if (!timelock.hasRole(proposer, KEEPER)) {
            timelock.grantRole(proposer, KEEPER);
            console.log("granted: PROPOSER_ROLE -> keeper");
        } else {
            console.log("skip: keeper already has PROPOSER_ROLE");
        }
        if (!timelock.hasRole(executor, KEEPER)) {
            timelock.grantRole(executor, KEEPER);
            console.log("granted: EXECUTOR_ROLE -> keeper");
        } else {
            console.log("skip: keeper already has EXECUTOR_ROLE");
        }

        // 4. keeper may clear the vault's reward ledger
        bytes32 minterRole = rewards.MINTER_ROLE();
        if (!rewards.hasRole(minterRole, KEEPER)) {
            rewards.grantRole(minterRole, KEEPER);
            console.log("granted: rewards MINTER_ROLE -> keeper");
        } else {
            console.log("skip: keeper already has rewards MINTER_ROLE");
        }

        // 5. a guardian that can cancel a scheduled operation inside the 24h window
        if (GUARDIAN != address(0)) {
            bytes32 canceller = timelock.CANCELLER_ROLE();
            if (!timelock.hasRole(canceller, GUARDIAN)) {
                timelock.grantRole(canceller, GUARDIAN);
                console.log("granted: CANCELLER_ROLE -> guardian");
            } else {
                console.log("skip: guardian already has CANCELLER_ROLE");
            }
        } else {
            console.log("skip: no GUARDIAN set - only the deployer can cancel");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("Verify, then run the keeper with DRY_RUN=true before going live.");
    }
}
