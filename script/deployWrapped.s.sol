//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import 'forge-std/console.sol';
import {sfrxETH, ERC20} from "../src/sfrxETH.sol";
import {frxETH} from "../src/frxETH.sol";

/// @notice Deploys wMyPlume (unmodified Frax sfrxETH / xERC4626) over myPLUME and seeds it.
/// @dev Non-upgradeable by design: the vault is Frax's audited code and is not meant to change.
///      The seed deposit is permanent and mitigates the ERC-4626 first-depositor inflation attack.
contract Deploy is Script {
    address constant deployer = 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c;
    address payable constant MINTER = payable(0xAD8874006ee4EBe311066E47c650A74171b8F624);
    address constant MYPLUME = 0xc2387E0feA344D1edEC3E93Bf2124f909f74938C;
    uint32 constant REWARDS_CYCLE_LENGTH = 7 days; // immutable once deployed. The keeper recycles
                                                   // more often than this; mints simply accumulate
                                                   // in the vault until the next sync.
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant SEED = 10 ether;              // PLUME -> myPLUME -> vault; shares burned to DEAD

    function run() public {
        console.log('Deployer:', deployer);
        vm.startBroadcast(deployer);

        require(deployer.balance >= SEED + 1 ether, "fund deployer with seed + gas");

        sfrxETH vault = new sfrxETH(ERC20(MYPLUME), REWARDS_CYCLE_LENGTH);

        // Seed: mint myPLUME to the deployer, deposit it, and burn the shares so the
        // vault can never return to a zero-supply state (ERC-4626 first-depositor guard).
        (bool ok,) = MINTER.call{value: SEED}(abi.encodeWithSignature("submit()"));
        require(ok, "seed submit failed");
        frxETH(MYPLUME).approve(address(vault), SEED);
        uint256 shares = vault.deposit(SEED, DEAD);
        require(shares > 0, "seed deposit failed");

        console.log("wMyPlume deployed at", address(vault));
        console.log("seeded shares", shares);
        console.log("rewardsCycleEnd", vault.rewardsCycleEnd());

        vm.stopBroadcast();
    }
}
