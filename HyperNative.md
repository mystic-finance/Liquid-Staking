## High-signal rulesets and parameters to monitor on Hypernative

### Immediate shutdown/pause triggers

- **Custody/outflow anomalies**

  - Any `moveWithheldETH`, `recoverEther`, or `withdrawFee` ≥ 2% TVL or sent to non-treasury address. Trigger pause.
  - Invariant breach: `totalInstantUnstaked > currentWithheldETH`. Trigger pause.
  - Unexplained ETH outflow or `currentWithheldETH` spike ≥ 2% TVL in 10 min. Trigger pause.

- **Privileged control changes**

  - `owner` / `timelock_address` changes or role grants/revokes on `stPlumeMinter`, `frxETHMinter`, `frxETH`, `stPlumeRewards`, or `OperatorRegistry` to unknown addresses. Trigger pause.
  - `recoverEther`, `recoverERC20`: Any call: Trigger pause.

- **Parameter tampering**

  - `setStPlumeRewards` or `frxETH.updateStPlumeRewards` to unexpected address. Trigger pause.
  - `setWithholdRatio` increases above (50%) or >10x in a single tx. Trigger pause.
  - `setFees` where `INSTANT_REDEMPTION_FEE` or `REDEMPTION_FEE` increases >5x in one tx. Trigger pause.
  - `setBatchUnstakeParams`: threshold cut >50% or interval < 6h. Trigger pause.
  - `setMinStake` reduced below `plumeStaking.getMinStakeAmount()`. Trigger pause.

- **Registry integrity**

  - `TimelockChanged` on `OperatorRegistry`. Trigger pause.
  - `clearValidatorArray()` or `numValidators()` becomes 0. Trigger pause.

- **External dependency degradation**

  - `plumeStaking.amountWithdrawable()` drops to 0, or multiple consecutive reverts in `withdraw()`/`claim()`. Trigger pause.

- **Rewards pipeline anomalies**

  - `stPlumeRewards.setYieldFee` > (50%) or >2X jump. Trigger pause.
  - `rewardRate` drops >70% in 60 min unexpectedly. Trigger pause.
  - `stPlumeMinter` must have `MINTER_ROLE`; Any revocation: Trigger pause.

- **Token anomalies**

  - `onlyOwner` `updateStPlumeRewards(address)`: Any change: Trigger pause.
  - Ensure `stPlumeRewards` equals deployed rewards contract; divergence: Critical.

- **Withdrawal pressure**

  - Rapid `withdraw()` series totaling ≥ 5% TVL in 10 min across users. Trigger pause.

- **Direct mint abuse**
  - Large unexpected EOAs sending Plume to `stPlumeMinter.receive()` causing outsized `ETHSubmitted` mints. Trigger pause.

### Immediate actions on trigger

- Call `frxETHMinter.togglePauseSubmits()` to halt new mints/deposits.
- Call `frxETHMinter.togglePauseDepositEther()` to stop mints/deposits, withdrawal and claiming rewards.

---

### Alerts

#### stPlumeMinter

- **Admin/Roles**

  - Monitor `DEFAULT_ADMIN_ROLE`, `REBALANCER_ROLE`, `CLAIMER_ROLE`, `HANDLER_ROLE` grants/revokes. Critical
  - Any privileged call by non-expected `owner` / `timelock` / role holder.Critical

- **Registry integrity**

  - `addValidator`, `removeValidator`, `popValidators`, `swapValidator`, `clearValidatorArray`: Any call: High.
  - `numValidators()` is zero. Critical
  - `TimelockChanged`: Critical (Trigger pause).
  - Large or frequent validator set changes: High.

- **Pauses and safety toggles**

  - `togglePauseSubmits`, `togglePauseDepositEther`: Any change: High. Rapid toggles: Medium.

- **Economic parameters**

  - `setFees(newInstantFee, newStandardFee)`: Any change. If `INSTANT_REDEMPTION_FEE` > 2% or `REDEMPTION_FEE` > 1%: High.
  - `setMinStake(_minStake)`: If decreased or set below operational norms: High.
  - `setMaxValidatorPercentage(validatorId, maxPct)`: If set to 0 or big change (>50%): Medium.
  - `setBatchUnstakeParams(_threshold, _interval)`: If threshold lowered >50% or interval < 6h: High.
  - `setStPlumeRewards(address)`: Any change: Critical.
  - `setWithholdRatio(newRatio)`:
    - If > 10%: High.
    - Any increase >2x in one tx: High.

- **Funds movement / custody**

  - `moveWithheldETH(to, amount)`: Any call: High; if `to` != treasury or amount > 25% of `currentWithheldETH`: Critical.
  - `withdrawGov()`, `unstakeGov(...)`: Any call: High.
  - `recoverEther`, `recoverERC20`: Any call: Critical.

- **Minting**

  - `ETHSubmitted` spikes (count/value) or large `currentWithheldETH` spikes: Medium/High.
  - Large unexpected EOAs using `receive()` mint path: High.

- **Withdrawals**

  - `withdraw(...)`: Unusually large withdrawals (> 5% TVL threshold) or burst activity: High.
    - If any single withdrawal > threshold (1M Plume), trigger pause.
  - Monitor `Withdrawn(user, amount)` for outliers.

- **External dependency**

  - If `plumeStaking.amountWithdrawable()` suddenly drops to 0: High (see shutdown triggers).

- **Invariants and state health**
  - Track `currentWithheldETH`, `totalInstantUnstaked`, `totalUnstaked`:
    - If `totalInstantUnstaked > currentWithheldETH`: Critical.
    - If `totalUnstaked` drops sharply (>15% in 10 min) without corresponding expected operations: High.
  - Per-validator:
    - `totalQueuedWithdrawalsPerValidator[validatorId]` approaching `withdrawalQueueThreshold`: Info.
    - `_processBatchUnstake` anomalies: Medium.
    - `nextBatchUnstakeTimePerValidator[validatorId]` not updating: Medium.

#### stPlumeRewards

- **Admin/Roles**

  - `MINTER_ROLE`, `HANDLER_ROLE` grants/revokes: Critical.
  - Ensure `stPlumeMinter` retains `MINTER_ROLE`; revocation: Critical
  - Any role granted to unexpected EOA: Critical.

- **Economic parameters**

  - `setYieldFee(newYieldFee)`: Any increase. If > 50% or >2x: High
  - `setRewardsCycleLength(newLength)`: If < 1 day: High.

- **Rewards cycle health**

  - Track `rewardRate`, `rewardsCycleEnd`, `lastSync`, `rewardPerTokenStored`:
    - `rewardRate` drop > 70% in 1h: High.
    - No new `NewRewardsCycle` past `rewardsCycleEnd` when claims expected: High.

- **ETH flows**

  - `loadRewards()` pay-ins: unexpected sender or very large amounts: Medium

- **User accounting**
  - Sudden mass `handleTokenTransfer` activity spikes: Low.

#### frxETH

- **Admin**

  - `onlyOwner` `updateStPlumeRewards(address)`: Any change: Critical (Trigger pause).
  - Ensure `stPlumeRewards` equals deployed rewards contract; divergence: Critical.

- **Token transfer hooks**
  - Spike in `handleTokenTransfer` calls:Low.
  - `totalSupply` sudden drops/increases: Medium.

#### Cross-contract invariants

- **Accounting**

  - `currentWithheldETH` ≈ contract ETH balance minus funds staked . Unexplained delta > 10000 PLUME: High.
  - `stPlumeRewards` net reward per cycle correlates with claims and external loads; anomaly > 30%: Medium.
  - Enforce `totalInstantUnstaked <= currentWithheldETH`. Critical.

- **Large ETH movement**

  - > 2% TVL or > 100000 ETH within 10 minutes: High.

- **Queue pressure**

  - `totalQueuedWithdrawalsPerValidator` > 80% of `withdrawalQueueThreshold`: Medium; 100% triggers batch: Info to validate expected run.

- **Address cohesion**

  - `frxETH.stPlumeRewards` == rewards contract.
  - `stPlumeMinter.stPlumeRewards` == rewards contract.
  - Any change: Critical (Trigger pause).

- **Receive/mint path**
  - `stPlumeMinter.receive()` mints to sender for non-`treasury`/`plumeStaking`. Monitor unexpected EOAs sending large ETH directly: Info/Medium.

---

### Morpho and Morpho vaults

- **Governance/roles**

  - Admin/guardian/pause role changes. Critical.

- **Market safety**

  - Oracle address/implementation change. Critical.
  - Collateral factors, reserve factors, supply/borrow caps changes. High.
  - Pauses/freezes toggled. High.

- **Risk metrics**

  - TVL drop > 10% in 10 min: High.
  - Utilization > 95% sustained, or sudden spike: Medium/High.
  - Bad debt growth or insolvent accounts detected: Critical.

- **Vault health**

  - Share price (pricePerShare) drop > 0.5% in 1h (if unlevered) or > strategy-specific threshold: High.
  - Unexpected large withdrawals or deposits: Medium/High.
  - Strategy allocation/underlying market changes (target markets or adapters updated): High.

- **Caps and limits**

  - Hitting or changing supply/borrow caps. Medium on hit; High on change > 25%.
  - New market creation or deprecation used by vaults. High.

- **Cross-dependency**
  - Any Morpho market pause or oracle failure should raise alerts on the vaults that depend on it. High/Critical.
