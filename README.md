# Frax Staked Ethereum

## Flowchart

![frxETH Flowchart](flowchart.svg)

## Overview Documentation

[https://docs.frax.finance/frax-ether/overview](https://docs.frax.finance/frax-ether/overview).

<!-- //////////////////////////////////////////////////////////////// -->

# Building and Testing

## Setup

1. `git clone https://github.com/FraxFinance/frxETH-public.git --recurse-submodules --remote-submodules`
2. Install [foundry](https://book.getfoundry.sh/getting-started/installation)
3. `forge install`
4. `git submodule update --init --recursive`
   4a) `cd ./lib/ERC4626 && git checkout main`. This should switch it to `corddry`'s fork.
5. (Optional) Occasionally update / pull your submodules to keep them up to date. `git submodule update --recursive --remote`
6. Create your own .env and copy SAMPLE.env into there. Sample mainnet validator deposit keys are in test/deposit_data-TESTS-MAINNET.json if you need more.
7. You don't need to add PRIVATE_KEY, ETHERSCAN_KEY, or FRXETH_OWNER if you are not actually deploying on live mainnet

### Forge

Manually, forced
`forge build --force`

## Testing

### General / Helpful Notes

1. If you want to add more fuzz cycles, edit foundry.toml
2. Foundry [cheatcodes](https://book.getfoundry.sh/cheatcodes/)

### Forge

Most cases
`source .env && forge test -vv`

If you need to fork mainnet
`source .env && forge test --fork-url $MAINNET_RPC_URL -vv`

If you need to fork mainnet, single test contract
`source .env && forge test --fork-url $MAINNET_RPC_URL -vv --match-path ./test/frxETHMinter.t.sol`

Verbosely test a single contract while forking mainnet
or `source .env && forge test --fork-url $MAINNET_RPC_URL -m test_frxETHMinter_submitAndDepositRegular -vvvvv` for single test verbosity level 5

### Other Scipts

tsx validate-msig-add-validators.ts

DepositDataToCalldata: SEE THE DepositDataToCalldata.s.sol FILE ITSELF FOR INSTRUCTIONS

### Slither

1. Install [slither](https://github.com/crytic/slither#how-to-install)
2. Slither a single contract
   `slither ./src/sfrxETH.sol --solc-remaps "openzeppelin-contracts=lib/openzeppelin-contracts ERC4626=lib/ERC4626/src solmate=lib/solmate/src"`

<!-- //////////////////////////////////////////////////////////////// -->

# Deployment & Environment Setup

## Deploy

1. Deploy frxETH.sol
2. Deploy sfrxETH.sol
3. Deploy frxETHMinter.sol
4. Add the frxETHMinter as a valid minter for frxETH
5. (Optional, depending on how you want to test) Add some validators to frxETHMinter

### Goerli

#### Single deploy

`source .env && forge create src/frxETH.sol:frxETH --private-key $PRIVATE_KEY --rpc-url $GOERLI_RPC_URL --verify --optimize --etherscan-api-key $ETHERSCAN_KEY --constructor-args $FRXETH_OWNER $TIMELOCK_ADDRESS`

#### Group deploy script

Goerli
`source .env && forge script script/deployGoerli.s.sol:Deploy --rpc-url $GOERLI_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY`
Mainnet
`source .env && forge script script/deployMainnet.s.sol:Deploy --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY`

#### Etherscan Verification

Sometimes the deploy scripts above fail with Etherscan's verification API. In that case, use:
`forge flatten src/frxETHMinter.sol -o flattened.sol`
Then do
`sed -i '/SPDX-License-Identifier/d' ./flattened.sol && sed -i '/pragma solidity/d' ./flattened.sol && sed -i '1s/^/\/\/ SPDX-License-Identifier: GPL-2.0-or-later\npragma solidity >=0.8.0;\n\n/' flattened.sol`

## Development

To make new dependencies play nicely with VSCode:
`forge remappings > remappings.txt`

<!-- //////////////////////////////////////////////////////////////// -->

# Contracts Under Review

## ERC20PermitPermissionedMint.sol

Parent contract for frxETH.sol. Has EIP-712/EIP-2612 permit capability, is burnable, and has an array of authorized minters. Is also owned.

## frxETH.sol

Basically the same as ERC20PermitPermissionedMint.sol

## frxETHMinter.sol

Authorized minter for frxETH. Users deposit ETH for frxETH. It then deposits that ETH into ETH 2.0 staking validators to earn yield. It can also withhold part of the ETH deposit for future use, such as to earn yield in other places to supplement the ETH 2.0 staking yield.

## OperatorRegistry.sol

Keeps track of available validators to add batches of 32 ETH to. Contains various array manipulations. It is assumed that validator checks for validity, as well as ordering in the array, are done off-chain to save gas beforehand.

## sfrxETH.sol

Autocompounding vault token for frxETH. Users deposit their frxETH for sfrxETH. Adheres to ERC4626/xERC4626. Any rewards earned externally, such as from ETH 2.0 staking, are converted to frxETH then sent here. After that happens, the exchange rate / pricePerShare for the sfrxETH token increases and sfrxETH hodlers can exchange their sfrxETH tokens for more frxETH than they initially put in (this is their rewards). Has EIP-712/EIP-2612 permit capability.

<!-- //////////////////////////////////////////////////////////////// -->

# Contracts Included but not under review

## ERC4626.sol, xERC4626.sol

Already audited several times.

## DepositContract.sol

Official Ethereum 2.0 deposit contract.

## Owned.sol

Synthetix.io created.

## SigUtils.sol

Only used for testing, so no need to audit.

## ERC20Permit, ERC20Burnable, etc

Openzeppelin created contracts are already extensively audited.

<!-- //////////////////////////////////////////////////////////////// -->

# Known Issues

### xERC4626.sol

xTRIBE, which is xERC4626.sol based and has some functions that sfrxETH.sol uses, has two known medium severity corner case issues [M-01](https://code4rena.com/reports/2022-04-xtribe/#m-01-xerc4626sol-some-users-may-not-be-able-to-withdraw-until-rewardscycleend-the-due-to-underflow-in-beforewithdraw) and
[M-02](https://github.com/code-423n4/2022-04-xtribe-findings/issues/66)

### OperatorRegistry.sol

No checking for valid validator pubkeys, signatures, etc are done here. They are assumed to be done off chain before they are added. However, the official ETH 2.0 DepositContract.sol DOES do checks and will revert if something is wrong. It is assumed that the team, or the manager(s) of the OperatorRegistry.sol contract will remove/replace the offending invalid validators.

<!-- //////////////////////////////////////////////////////////////// -->

# Contest Scope

- stPlume/src/frxETHMinter.sol
- stPlume/src/stPlumeMinter.sol
- stPlume/src/OperatorRegistry.sol

- Original frxETH Repository: [https://github.com/FraxFinance/frxETH-public](https://github.com/FraxFinance/frxETH-public)
  -~600 Total sLoC in scope (increased from 365 due to new contracts)
- Contracts use inheritance, most of the parents are time/battle tested Openzeppelin or other contracts
- Most public interaction will be with stPlumeMinter.sol, sfrxETH.sol, and OperatorRegistry.sol
- frxETH.sol conforms to EIP-712/EIP-2612 and ERC-20 standards and uses Openzeppelin and Synthetix.io parents
- sfrxETH.sol conforms to EIP-712/EIP-2612, ERC-4626, and ERC-20 standards
- stPlumeMinter.sol extends frxETHMinter with staking, unstaking, and reward claiming functionality
- OperatorRegistry.sol manages validators for ETH staking operations
- Interacts with Plume Staking protocol for validator management and ETH staking: [https://github.com/plumenetwork/contracts/tree/main/plume](https://github.com/plumenetwork/contracts/tree/main/plume)
- No novel or unique curve logic or mathematical models-
- Not an NFT
- Not an AMM
- Not a fork of a popular project
- Does not use rollups
- Single-chain only



forge install https://github.com/transmissions11/solmate@62e0943c013a66b2720255e2651450928f4eed7a
forge install https://github.com/OpenZeppelin/openzeppelin-contracts@8d908fe2c20503b05f888dd9f702e3fa6fa65840
forge install https://github.com/foundry-rs/forge-std
forge install https://github.com/corddry/ERC4626@6cf2bee5d784169acb02cc6ac0489ca197a4f149


REWARD Mechanism:

Core Components of the Reward System

1. Reward Collection and Fee Structure
The reward system begins with collecting yields from staking ETH with validators through the PlumeStaking protocol:

- Yield Fee: The contract takes a configurable fee (default 10% via YIELD_FEE = 100000)
- Redemption Fees: Two types of fees are charged when users withdraw:
    - Standard redemption fee: 0.015% (REDEMPTION_FEE = 150)
    - Instant redemption fee: 0.5% (INSTANT_REDEMPTION_FEE = 5000)

2. Reward Accumulation Mechanism
Rewards are collected through several methods:

- claim() - Claims rewards from a specific validator
- claimAll() - Claims rewards from all validators
- loadRewards() - Allows direct ETH deposits as rewards
- _rebalance() - Internal function that claims rewards and loads them
When rewards are received, they're processed through _loadRewards():

```solidity
function _loadRewards(uint256 amount) internal {
    if(amount > 0){
        uint256 yieldAmount = amount * YIELD_FEE / RATIO_PRECISION;
        yieldEth += amount - yieldAmount;
        withHoldEth += yieldAmount;
        _depositEther(amount - yieldAmount, 0);
        if (block.timestamp >= rewardsCycleEnd) { syncRewards(); }
    }
}
```

3. Cycle-Based Reward Distribution
The system uses a time-based cycle mechanism for distributing rewards:
- Reward Cycles: Rewards are distributed over cycles (default 7 days via rewardsCycleLength)
- Cycle Tracking: Each cycle's rewards and total supply are recorded in the cycleRewards array
- Gradual Unlocking: Rewards are linearly unlocked over the cycle period

The syncRewards() function manages cycle transitions:

```solidity
function syncRewards() public virtual {
    uint256 timestamp = block.timestamp;
    require(timestamp >= rewardsCycleEnd, "Not in rewards cycle");
    require(yieldEth >= lastRewardAmount, "Negative rewards");

    uint256 nextRewards = yieldEth - lastRewardAmount;
    rewardsEth += nextRewards;
    cycleRewards.push(CycleRewards({
        rewards: nextRewards,
        totalSupply: frxETHToken.totalSupply(),
        cycleEnd: rewardsCycleEnd
    }));
    
    // Set up the next cycle
    uint256 end = ((timestamp + rewardsCycleLength) / rewardsCycleLength) * rewardsCycleLength;
    if (end - timestamp < rewardsCycleLength / 20) {
        end += rewardsCycleLength;
    }

    lastRewardAmount = uint192(nextRewards);
    lastSync = uint32(timestamp);
    rewardsCycleEnd = uint32(end);
}
```

4. User Reward Tracking
The contract meticulously tracks each user's rewards:

- Per-User Tracking: userRewards mapping tracks each user's accumulated rewards
- Reward Accrual: When users interact with the contract (deposit/withdraw), their rewards are accrued
- Cycle Tracking: The contract tracks which cycles a user has claimed rewards from

5. Reward Calculation
The getYield() function calculates the total available yield:

```solidity
function getYield() public view returns (uint256) {
    if (block.timestamp >= rewardsCycleEnd) {
        return rewardsEth + lastRewardAmount;
    }
    uint256 unlockedRewards = (lastRewardAmount * (block.timestamp - lastSync)) / (rewardsCycleEnd - lastSync);
    return rewardsEth + unlockedRewards;
}
```
For individual users, rewards are calculated based on:
- Their token balance
- The cycles they've participated in
- The current unlocked rewards

The normalizedAmount() function returns a user's balance plus accrued rewards:

```solidity
function normalizedAmount(address user, uint256 amount) public view returns (uint256) {
    return amount + userRewards[user].rewardsAccrued + _getCurrentUserYield(user, amount);
}
```

6. Reward Claiming
Users claim rewards through unstakeRewards():

```solidity
function unstakeRewards() external nonReentrant returns (uint256 yield) {
    _rebalance();
    yield = getUserRewards(msg.sender);
    if(yield == 0){return 0;}
    _unstake(yield, true, 0);
    userRewards[msg.sender].rewardsAccrued = 0;
    userRewards[msg.sender].rewardsBefore = getYield();
    userRewards[msg.sender].lastCycleClaimed = cycleRewards.length;
    require(getUserRewards(msg.sender) == 0, "Rewards should be reset after unstaking");
    return yield;
}
```

7. Reward Flow Summary
- Reward Collection: ETH rewards are collected from validators via PlumeStaking
- Fee Extraction: A portion of rewards (10% by default) is taken as protocol fee
- Cycle Management: Remaining rewards are added to the current cycle
- Gradual Distribution: Rewards are linearly unlocked over the cycle period
- User Accounting: When users interact with the contract, their rewards are accrued
- Reward Claiming: Users can claim rewards by calling unstakeRewards()

The system ensures that rewards are fairly distributed to frxETH token holders based on their balance and participation in the protocol, while maintaining the protocol's sustainability through fee collection.



## New Staking Scope
You can find the codebase here: https://github.com/mystic-finance/Liquid-Staking/tree/staked-plume

The key components include:
- Core contracts (~500 LOC) in src/: stPlumeMinter.sol, frxETH.sol, frxEthMinter.sol, and OperatorRegistry.sol
- Withdrawal and rewards management script in automation/
- Tests in tests/fork/ with main test of stPlumeMinter.t.sol
- Deployment script in script/ with DeployMinter.s.sol as the main deployment file
