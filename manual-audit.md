# Liquid-Staking (myPLUME) — Manual Security Audit

**Scope**
- `src/stPlumeMinter.sol`
- `src/stPlumeRewards.sol`
- `src/frxETH.sol`
- `src/frxETHMinter.sol`
- `src/sfrxETH.sol`
- `src/OperatorRegistry.sol`
- `src/ERC20/ERC20PermitPermissionedMint.sol`
- `src/Periphery/MyPlumeFeed.sol`
- `src/Utils/OwnedUpgradeable.sol`

**Branch:** `staked-plume`
**Methodology:** manual code review, control-flow analysis of all state-mutating paths, integration analysis against `IPlumeStaking` (Plume mainnet facets), ERC-20/2612/4626 conformance review, role/permission audit, upgradeability/storage-slot review, multi-round Q&A with the protocol team.

---

## 1. Executive Summary

myPLUME is a fork of Frax `frxETH` adapted to the Plume L1, with one structural deviation: the protocol enables direct 1:1 `unstake/withdraw` on the principal token (`myPLUME`) and distributes Plume validator rewards through a Synthetix-style accumulator on the same token (`stPlumeRewards`). An optional ERC-4626 wrapper (`sfrxETH` / `wMystPlume`) sits on top.

The contracts are well-structured and the design is internally coherent. The primary risk class is **integration with Plume's per-validator binary slashing model**: Plume slashing is governance-gated (unanimous validator vote), but on finalization it fully zeros active stake and unmatured cooldowns on the slashed validator. Active stake cannot be evacuated during the vote window because Plume offers no cross-validator stake migration and `maxSlashVoteDuration < cooldownInterval`. The protocol must therefore (a) **enforce concentration limits** to bound single-event loss, and (b) **handle post-slash state cleanup** so that a slash event does not brick batch processing or trap user withdrawal requests.

Secondary risks are operational: governance powers (fees, recover, pause toggles) are wider than necessary, and a few accounting paths in `_withdraw` and `MyPlumeFeed` are fragile to validator-state transitions.

No critical-severity bug results in immediate fund loss under normal operation. The findings below should be addressed before mainnet exposure scales beyond comfortable governance-recovery limits.

---

## 2. Slashing Model and Protocol Exposure

This section documents the Plume slashing semantics that drive several findings.

### 2.1 Plume slashing mechanics (verified against `ValidatorFacet.sol`, `StakingFacet.sol`, `ManagementFacet.sol`)

- **Trigger:** `voteToSlashValidator(uint16, uint256)`. Voters are *other* validator admins. Threshold is **unanimous** — every active, non-slashed validator excluding the target must vote.
- **Auto-finalization:** the last vote within `voteToSlashValidator` invokes `_performSlash` in the same transaction.
- **Manual path:** `slashValidator(uint16)` callable by `TIMELOCK_ROLE`, but still gated by unanimity.
- **No silent slash:** there is no admin/timelock override that bypasses voting.
- **Vote window:** caller-supplied `voteExpiration`, bounded by global `maxSlashVoteDurationInSeconds`. **Invariant: `maxSlashVoteDurationInSeconds < cooldownInterval`** (enforced in `ManagementFacet.setMaxSlashVoteDuration`).
- **Pre-finalization signal:** `SlashVoteCast(maliciousValidatorId, voterValidatorId, voteExpiration)` event on every vote; `getSlashVoteCount(uint16)` view returns active vote count.
- **State changes on `_performSlash`:**
  - `validator.active = false`, `validator.slashed = true`, `validator.slashedAtTimestamp = now`.
  - `validatorTotalStaked[V] = 0`, `validatorTotalCooling[V] = 0`. Global `totalStaked` / `totalCooling` decremented.
  - Per-user `userValidatorStakes[user][V].staked` is **NOT zeroed in `_performSlash`** — it remains as stale data until admin runs `adminClearValidatorRecord(user, V)`.
- **Effect on cooldowns:** a cooldown entry on V survives only if `cooldownEndTime < slashedAtTimestamp`. Cooldowns still in flight at slash time are burned.
- **Effect on parked / withdrawable funds:** preserved.
- **Reward claim on slashed V:** allowed, capped at `slashedAtTimestamp`.

### 2.2 What this means for `stPlumeMinter`

| Funds at slash finalization | Outcome |
|---|---|
| Active staked on slashed V | **Lost** |
| Cooling on V, `cooldownEndTime ≥ slashedAtTimestamp` | **Lost** |
| Cooling on V, `cooldownEndTime < slashedAtTimestamp` | Recoverable |
| Parked / withdrawable on V before slash | Safe |
| Active staked on a **different** validator | Safe |
| Held in `currentWithheldETH` on minter | Safe |

### 2.3 No evacuation path for active stake during the vote window

`restake(V2, amount)` can only draw from (a) the global `parked` pool, or (b) unmatured cooling on the **target** validator V2. It **cannot** draw from cooling on V1. Plume exposes no `redelegate`, `transferStake`, or `migrate` function. The only path from V1-active to V2-active is:

`unstake(V1, amount)` → wait full `cooldownInterval` → matures into global `parked` → `restake(V2, amount)`.

Because `maxSlashVoteDuration < cooldownInterval`, the slash can finalize before V1's cooldown matures. Therefore **calling `unstake` during the vote window does not save active-staked funds**.

### 2.4 What monitoring `SlashVoteCast` does and does not buy

A naive read of the vote-window mechanism suggests "we have time to evacuate." We don't, for active stake. Detecting the first `SlashVoteCast` at time `T_cast`, calling `unstake(V, full)`, then waiting: cooldown ends at `T_cast + cooldownInterval`. Slash can finalize anywhere in `[T_cast, T_cast + maxSlashVoteDuration]`. Since `maxSlashVoteDuration < cooldownInterval`, even the latest possible slash finalization beats the cooldown — funds are still in `cooling` on V when the slash hits, and are burned. The Plume invariant guarantees safe withdrawal *if the slash fails*, not if it succeeds.

What monitoring `SlashVoteCast` IS useful for:
- Pausing new deposits via `togglePauseSubmits` so no further user funds are routed onto the at-risk validator.
- Off-chain alerting and incident response.
- Pre-positioning the post-slash recovery transaction (F-2 `recordSlash`) so it lands immediately after `ValidatorSlashed`, minimizing the window where the protocol operates with stale on-chain state.

### 2.5 Implications for protocol design

- **Concentration limits** are the primary defense. Protocol max single-event loss ≈ (largest validator's share of TVL).
- **Healthy `currentWithheldETH` buffer** keeps liquid funds off Plume entirely; this ETH is never at slash risk.
- **Post-slash recovery** must exist on-chain: the minter must (a) skip slashed validators in batch processing, (b) record the loss at the protocol level, and (c) settle stuck withdrawal requests at a socialized haircut so unlucky users aren't permanently stranded while lucky users redeem at full value.

---

## 3. Findings Summary

| # | Title | Severity |
|---|---|---|
| F-1 | No default validator concentration cap; slash exposure can be 100% of TVL | **High** — addressed operationally (Section 11) |
| F-2 | `processBatchUnstake` reverts on slashed-V with queued withdrawals | **Resolved** — `active` check added |
| F-3 | Stuck withdrawal requests post-slash | **Resolved** — `addFundsDirectly` co-bumps `tIU` + on-chain haircut via `slashedAmount` |
| F-4 | Reward-path `_depositEther` revert can block exits when validators are saturated | **Low** |
| F-5 | `setFees` cap of 100% with owner-or-timelock gate | **Low** |
| F-6 | `recoverEther` / `recoverERC20` can sweep tracked protocol balances | **Low** |
| F-7 | Synthetix reward dilution lag for new depositors | **Resolved** — `_rebalance()` added to `_submit` |
| F-8 | `MyPlumeFeed.getTotalDeposits` undercounts cooling/parked balances and is stale post-slash | **Medium** |
| F-9 | `_withdraw` deficit branch misleading error and brittle invariant | **Low** |
| F-10 | `PAUSER_ROLE` not granted in `initialize` | **Low** |
| F-11 | `addValidator` accepts `validatorId == 0` | **Low** |
| F-12 | `addFundsDirectly` emits misleading `ETHSubmitted` event | **Low** |
| F-13 | Reward ETH ping-pong (gas) | **Info** |
| F-14 | Linear validator-array loops in hot paths | **Info** |
| F-15 | `getMyPlumePrice` divide-by-zero when supply is 0 | **Info** |
| F-16 | Unused `HANDLER_ROLE` grant | **Resolved** — declaration + grant commented out |
| F-17 | `unstakeGov` interference with user queue and batch processing | **Resolved** — queue-merge design |
| F-18 | Slash-haircut accounting depends on admin maintaining `slashedAmount` | **Low** — admin coordination |

**By design / acknowledged:**
- `_rebalance` requires `!depositEtherPaused` (intentional all-stop semantics; documented).
- Validator removal does not check residual queue/stake (admin-privileged operation).
- `togglePause*` are toggles rather than explicit `pause/unpause`.
- Single-validator `unstakeFromValidator` UX path; `unstake` (no validator) auto-spreads.

---

## 4. Detailed Findings

### F-1 — No default validator concentration cap; slash exposure can be 100% of TVL — High

**Files:** [stPlumeMinter.sol:44](src/stPlumeMinter.sol#L44), [stPlumeMinter.sol:94-110](src/stPlumeMinter.sol#L94-L110), [stPlumeMinter.sol:604-607](src/stPlumeMinter.sol#L604-L607)

`maxValidatorPercentage[validatorId]` is a per-validator cap consulted in `getNextValidator`. The mapping defaults to `0`, which the code treats as "no cap":

```solidity
uint256 percentage = ((stakedAmount + depositAmount) * RATIO_PRECISION) / (totalStaked + depositAmount);
if(maxValidatorPercentage[validatorId] > 0 && percentage > maxValidatorPercentage[validatorId]){
    return (validatorId, 0);
}
```

The `setMaxValidatorPercentage` setter requires governance to explicitly populate each validator. New validators added via `addValidator` start uncapped.

Combined with Plume's binary per-validator slash semantics (Section 2), this means a single slash event can wipe up to 100% of the protocol's active stake if one validator has accumulated all (or most) of the deposits. There is no automatic load-balancing — validators are tried in array order, so the first validator with non-saturated capacity absorbs all deposits until full.

**Recommendation:**
1. Add a `defaultMaxValidatorPercentage` storage variable, set to a conservative default (e.g., 250000 = 25%) in `initialize`.
2. In `getNextValidator`, fall back to the default when `maxValidatorPercentage[V] == 0`.
3. Consider `addValidator` populating the per-validator cap explicitly at admission so the policy is visible on-chain.

This is the single most important hardening change in the protocol.

---

### F-2 — `processBatchUnstake` reverts on slashed validator — RESOLVED

**Status:** Fixed in [stPlumeMinter.sol:337-338](src/stPlumeMinter.sol#L337-L338). The keeper-callable `processBatchUnstake()` now reads `getValidatorStats(validatorId).active` before deciding to fire the batch:

```solidity
(bool active,,,) = plumeStaking.getValidatorStats(validatorId);
if (active && (totalQueuedWithdrawalsPerValidator[validatorId] >= withdrawalQueueThreshold
    || block.timestamp >= nextBatchUnstakeTimePerValidator[validatorId])) {
    _processBatchUnstake(validatorId);
}
```

A slashed validator's stale queue no longer causes the loop to revert; the slashed validator is silently skipped, and other validators' batches process normally. The `_unstake` paths were already protected by their existing `active` check at line 482 (auto-loop) and line 460 (specific-validator).

**Original finding kept below for context:**

---

### F-2 (original) — `processBatchUnstake` slash handling — was High

**Files:** [stPlumeMinter.sol:330-341](src/stPlumeMinter.sol#L330-L341), [stPlumeMinter.sol:526-540](src/stPlumeMinter.sol#L526-L540), [stPlumeMinter.sol:96-109](src/stPlumeMinter.sol#L96-L109), [stPlumeMinter.sol:148-153](src/stPlumeMinter.sol#L148-L153), [stPlumeMinter.sol:381-382](src/stPlumeMinter.sol#L381-L382), [stPlumeMinter.sol:455-498](src/stPlumeMinter.sol#L455-L498)

This is the central post-slash recovery finding. It bundles three mechanically-related concerns: (a) `processBatchUnstake` reverts the whole loop on a slashed validator, (b) the minter has no on-chain memory of what was lost, and (c) every status check uses `getValidatorStats` which cannot distinguish paused vs slashed validators.

**Bug (a): batch loop bricks.**

```solidity
function processBatchUnstake() external {
    uint numVals = numValidators();
    uint256 index = 0;
    require(numVals != 0, "Validator stack is empty");
    while (index < numVals) {
        uint16 validatorId = uint16(validators[index].validatorId);
        if (totalQueuedWithdrawalsPerValidator[validatorId] >= withdrawalQueueThreshold
            || block.timestamp >= nextBatchUnstakeTimePerValidator[validatorId]) {
            _processBatchUnstake(validatorId);   // calls plumeStaking.unstake(V, amount)
        }
        index++;
    }
}
```

After a slash on `V` with non-zero `totalQueuedWithdrawalsPerValidator[V]`, the inline call reverts with `ActionOnSlashedValidatorError`. The loop has no `try/catch`; the whole call reverts; no other validator's batch processes. Keeper-driven batch processing is bricked.

**Bug (b): no loss register.**

After a slash, the protocol holds fewer PLUME than `frxETH.totalSupply()` is backed by, but nothing on-chain records this. F-3's stuck withdrawal requests have no haircut ratio to apply because the magnitude of the loss is never written down. The implicit behavior — losses concentrate on whoever happens to redeem against the slashed validator — is unsettleable: unlucky users revert forever (F-3), lucky users redeem at full value, draining the remaining backing until insolvent.

**Bug (c): paused-vs-slashed conflation.**

The minter calls `plumeStaking.getValidatorStats(V)` everywhere it needs validator status. That function returns `(active, commission, totalStaked, stakersCount)` with no `slashed` field. Both a paused and a slashed validator look like `active=false`, but recovery semantics differ entirely (paused funds are intact and recoverable on reactivation; slashed funds are gone). Without distinguishing, governance might mis-classify and either record a phantom loss or miss a real one.

**Recommendation: one coordinated change.**

1. **Use `getValidatorInfo` for status reads.** It returns the full `ValidatorInfo` struct including `slashed`:
   ```solidity
   function _isHealthy(uint16 V) internal view returns (bool) {
       (PlumeStakingStorage.ValidatorInfo memory info, , ) = plumeStaking.getValidatorInfo(V);
       return info.active && !info.slashed;
   }
   ```
   Replace all `(bool active, , , ) = getValidatorStats(V); if (!active) ...` sites with `_isHealthy(V)`. This also lets `_unstake`'s validator loop skip slashed entries cleanly (today it gates on `active` only, which is correct in normal operation but ambiguous for recovery decisions).

2. **Skip slashed validators in `processBatchUnstake`:**
   ```solidity
   if (!_isHealthy(validatorId)) { index++; continue; }
   ```

3. **Record the loss at the protocol level.** Add a slash-loss register and an admin entry point:
   ```solidity
   struct SlashEvent {
       uint256 timestamp;
       uint16 validatorId;
       uint256 amountLost;          // staked + cooling on V at slash time, attributable to this minter
       uint256 totalSupplyAtSlash;  // for haircut ratio computation
   }
   SlashEvent[] public slashEvents;
   uint256 public lostBackingFromSlash;
   mapping(uint16 => bool) public slashRecorded;

   function recordSlash(uint16 validatorId) external onlyByOwnGov {
       require(!slashRecorded[validatorId], "Already recorded");
       (PlumeStakingStorage.ValidatorInfo memory info, , ) = plumeStaking.getValidatorInfo(validatorId);
       require(info.slashed, "Validator not slashed");

       // Pre-slash protocol stake: read the still-stale per-user view.
       // Plume only zeros validator-level totals in _performSlash; userValidatorStakes[this][V]
       // remains as the pre-slash amount until adminClearValidatorRecord runs.
       uint256 lostAmount = plumeStaking.getUserValidatorStake(address(this), validatorId);

       slashEvents.push(SlashEvent({
           timestamp: block.timestamp,
           validatorId: validatorId,
           amountLost: lostAmount,
           totalSupplyAtSlash: frxETHToken.totalSupply()
       }));
       lostBackingFromSlash += lostAmount;
       slashRecorded[validatorId] = true;

       // Clean up minter-side state so processBatchUnstake stops touching V.
       delete totalQueuedWithdrawalsPerValidator[validatorId];
       _removeValidatorFromArray(validatorId);

       emit SlashRecorded(validatorId, lostAmount, block.timestamp);
   }
   ```

   The reliance on the *stale* `getUserValidatorStake` is intentional and correct: between `_performSlash` and Plume's `adminClearValidatorRecord(this, V)`, that view returns the exact pre-slash amount, which is what we need to capture as the loss. Calling `recordSlash` in this window is the protocol's way of snapshotting before Plume admin cleans up.

4. **Compute the haircut ratio for F-3 to consume:**
   ```solidity
   function haircutRatio() public view returns (uint256) {
       if (lostBackingFromSlash == 0) return 1e18;
       // Use the supply at the time of the most recent slash as the denominator.
       // For multi-slash sequencing, keep a running snapshot or apply ratios in series.
       uint256 snapshotSupply = slashEvents[slashEvents.length - 1].totalSupplyAtSlash;
       if (snapshotSupply == 0) return 1e18;
       uint256 lossPerShare = (lostBackingFromSlash * 1e18) / snapshotSupply;
       return lossPerShare >= 1e18 ? 0 : 1e18 - lossPerShare;
   }
   ```

This single coordinated fix:
- Unbricks `processBatchUnstake` for healthy validators.
- Distinguishes paused (transient) from slashed (terminal) so governance is never confused.
- Captures loss magnitude on-chain so F-3 can socialize it deterministically.
- Composes with F-1 — concentration cap bounds any single `lostBackingFromSlash` increment.

---

### F-3 — Stuck withdrawal requests post-slash — RESOLVED

**Status:** Addressed by **two complementary mechanisms** now in the contract:

**1. Insurance backfill path** ([stPlumeMinter.sol:177-178](src/stPlumeMinter.sol#L177-L178)):

```solidity
function addFundsDirectly(uint16 validatorId) public payable nonReentrant onlyRole(REBALANCER_ROLE) {
    if(validatorId > 0){
        _depositEther(msg.value, validatorId);
    }else{
        currentWithheldETH += msg.value;
        totalInstantUnstaked += msg.value;   // co-bump preserves the buffer ↔ earmark invariant
    }
    emit ETHSubmitted(address(this), address(this), msg.value, validatorId);
}
```

**How this resolves stuck requests post-slash:**

1. After a slash on V, user requests queued against V have `request.amount > 0` but `plumeStaking.amountWithdrawable()` returns less than expected (the cooling on V was burned). The deficit branch in `_withdraw` would normally revert with `"Insufficient funds to cover deficit"`.
2. Governance (insurance treasury) calls `addFundsDirectly{value: stuckAmount}(0)`. Both `currentWithheldETH` and `totalInstantUnstaked` increase by `stuckAmount`.
3. The user calls `withdraw(id)`. `_withdraw` now sees `totalInstantUnstaked >= totalAmount` (the require at line 246 passes via the buffer instead of the on-chain plumeStaking pull), and the function pays out from `currentWithheldETH` directly.
4. Both `cWE` and `tIU` decrement by `totalAmount` together; invariants preserved.

**Property preserved:** users with pre-existing instant-unstake reservations (their own `tIU` portion) are not robbed by stuck-user claims. Each backfilled amount is earmarked specifically for the stuck request being settled.

**Operational rules** (documented for the runbook):
- Backfill exactly the sum of stuck request amounts. Over-backfilling creates phantom `tIU` reserves which are non-fatal but block instant unstakes for new users until consumed.
- Do **not** call `moveWithheldETH` while phantom `tIU` exists (pre-existing footgun: `moveWithheldETH` doesn't check `tIU ≤ cWE`).
- Do **not** call `withdrawGov` while user-allocated funds are matured on plumeStaking (pre-existing footgun: pulled funds increment `cWE` only, leaving user requests un-settleable until natural drain).

**2. On-chain haircut path** ([stPlumeMinter.sol:435-441](src/stPlumeMinter.sol#L435-L441)):

```solidity
if (slashedAmount > 0) {
    uint256 s = frxETHToken.totalSupply() + amount;   // pre-burn supply
    uint256 newAmount = amount * (s - slashedAmount) / s;
    slashedAmount -= (amount - newAmount);             // burn user's share of the loss
    amount = newAmount;
}
```

When governance writes the loss size via `setSlashedAmount` ([stPlumeMinter.sol:621-623](src/stPlumeMinter.sol#L621-L623)) post-slash, every subsequent unstake (principal path only — gated by `if (!rewards)`) receives a pro-rata haircut: the user burns their full nominal `myPLUME` but receives `amount * (supply - slashedAmount) / supply` PLUME. The `slashedAmount` accumulator decrements by the user's share of the loss on each redemption, so the haircut ratio remains constant across redeemers regardless of order — preserving NAV.

**Two-layer recovery model:**

| Layer | Trigger | Effect |
|---|---|---|
| Insurance backfill | Governance calls `addFundsDirectly{value: lossAmount}(0)` | Bumps `currentWithheldETH` and `totalInstantUnstaked`, fully restoring liquidity for stuck requests. No haircut applied to users. |
| On-chain haircut | Governance calls `setSlashedAmount(loss)` | All future principal unstakes pay pro-rata haircut. Used when insurance can't fully cover the loss. |

**Recovery sequencing:**

1. Slash detected → governance reads protocol's pre-slash stake on the slashed validator (still-stale `getUserValidatorStake`).
2. If insurance treasury covers the loss: `addFundsDirectly{value: loss}(0)` only. Stuck requests settle via existing `_withdraw` flow against the buffer. Users get full payout. `slashedAmount` stays 0.
3. If insurance partially covers: `addFundsDirectly{value: covered}(0)` then `setSlashedAmount(loss - covered)`. Users pay haircut on the residual.
4. As insurance refills (e.g., yield fee accumulation, treasury top-ups), governance calls `setSlashedAmount(newSmaller)` to lower the haircut on subsequent redemptions.

**Properties preserved:**
- Pre-existing instant-unstake reservations (each user's own `tIU` portion) are not affected — backfilled funds are earmarked specifically for stuck requests.
- The haircut applies only to principal (`!rewards`), never to yield. Yield is tracked separately in `stPlumeRewards` and is not affected by validator-side slash.
- NAV is preserved across redemption ordering by decrementing `slashedAmount` proportionally.
- Staking is unaffected by `slashedAmount` — depositors entering during a recovery state are protected by `togglePauseSubmits` (operational), not by code.

**Operational rules** (documented for the runbook):
- Backfill exactly the sum of stuck request amounts (or the slash size). Over-backfilling creates phantom `tIU` reserves which block instant unstakes for new users until consumed.
- Do **not** call `moveWithheldETH` while phantom `tIU` exists or while `slashedAmount > 0` (pre-existing footgun: `moveWithheldETH` doesn't check `tIU ≤ cWE`).
- Do **not** call `withdrawGov` when user-allocated funds are matured on plumeStaking (pre-existing footgun: pulled funds increment `cWE` only, leaving user requests un-settleable until natural drain).
- During a slash recovery, call `togglePauseSubmits` to halt new mints from depositing at par into a state where NAV < 1.

**Original finding kept below for context:**

---

### F-3 (original) — Stuck withdrawal requests post-slash — was High

**Files:** [stPlumeMinter.sol:197-208](src/stPlumeMinter.sol#L197-L208), [stPlumeMinter.sol:236-278](src/stPlumeMinter.sol#L236-L278), [stPlumeMinter.sol:436-524](src/stPlumeMinter.sol#L436-L524)

When a user has an outstanding `WithdrawalRequest` whose backing was queued through validator V, and V is slashed before the cooldown window matures, Plume burns the cooled funds on V. The minter has no path to settle that request:

1. The request slot is non-zero (`request.amount > 0`).
2. `plumeStaking.amountWithdrawable()` does not include the burned portion.
3. `plumeStaking.withdraw()` returns `withdrawn < amount`.
4. The deficit branch reverts: `require(amount-withdrawn < fee, "Insufficient funds to cover deficit")` — with any non-trivial slash shortfall this is always false.
5. There is no haircut function, no socialization mechanism. The user is permanently stuck.

The Plume documentation is explicit: *"Users cannot recover losses, so admins use adminClearValidatorRecord / adminBatchClearValidatorRecords to erase orphaned state."* The LST — being the only "user" from Plume's perspective — must implement the equivalent loss-handling logic on its own side. Currently the only mitigation is governance manually topping up backing via `addFundsDirectly`, which is not a settlement mechanism.

Worse, the current implicit behavior is unfair: lucky users (those with no validator overlap with the slashed V) redeem at full 1:1, draining the diminished backing further; unlucky users (those queued against V) revert forever and absorb the entire loss.

**Recommendation:** apply F-2's haircut ratio to redemptions against any request opened before the most recent recorded slash. Burn the user's full `myPLUME`, settle PLUME at the haircut amount.

```solidity
function _withdraw(address recipient, uint256 id) internal returns (uint256 amount) {
    WithdrawalRequest storage request = withdrawalRequests[msg.sender][id];
    uint256 originalAmount = request.amount + request.deficit;

    // If a slash was recorded after this request was created, socialize it.
    uint256 effectiveAmount = originalAmount;
    if (slashEvents.length > 0
        && slashEvents[slashEvents.length - 1].timestamp > request.createdTimestamp) {
        effectiveAmount = (originalAmount * haircutRatio()) / 1e18;
    }

    // Continue withdrawal flow using `effectiveAmount` for the payable amount,
    // and the original `request.amount` for accounting decrements (totalUnstaked etc.).
    // The shortfall (originalAmount - effectiveAmount) is the user's share of the slash.
    ...
}
```

The same haircut applies on the principal-redemption path of `_unstake` so that *new* exits initiated after a slash also pay the haircut, preventing the drain-the-backing race.

Properties:
- Stuck pre-slash requests become settleable at fair value.
- Loss is socialized across all current and pre-slash holders, not concentrated on whoever happens to be queued against the slashed validator.
- Total payouts are bounded by remaining backing — protocol cannot pay out more than it owns.
- Governance retains optional discretionary top-up via `addFundsDirectly` if it wants to soften the haircut.

This relies on F-2's `recordSlash` having been called by governance after observing `ValidatorSlashed`. The current `"Insufficient funds to cover deficit"` error becomes either a successful haircut path or, if no slash has been recorded yet, a clearer error per F-9.

---

### F-4 — Reward-path `_depositEther` revert can block exits when validators are saturated — Low

**Files:** [stPlumeMinter.sol:343-348](src/stPlumeMinter.sol#L343-L348), [stPlumeMinter.sol:367-423](src/stPlumeMinter.sol#L367-L423), [stPlumeMinter.sol:634-644](src/stPlumeMinter.sol#L634-L644), [stPlumeRewards.sol:111-150](src/stPlumeRewards.sol#L111-L150)

`_rebalance` is called inside every user-facing exit. Its tail calls `_loadRewards` → `stPlumeRewards.loadRewards{value}()` → `minter.call{value: netReward}("")` → `receive()` → `_depositEther(netReward, 0)`. If every validator returns `capacity == 0` from `getNextValidator` (saturated, or all blocked by `maxValidatorPercentage`), `_depositEther` reverts at `require(remainingAmount == 0, ...)`. The revert bubbles through to the user's exit call.

Probability is very low: the Plume validator alone has near-infinite capacity, and the failure mode requires *every* validator simultaneously rejecting. If it does occur, governance can resolve in one transaction by raising `minStake` (which routes residuals into `currentWithheldETH` via the existing branch at [stPlumeMinter.sol:374-377](src/stPlumeMinter.sol#L374-L377)) or adding a high-capacity validator.

**Recommendation:** harden `receive()` so reward inflows can never block user exits even in this corner case:

```solidity
if(msg.sender == address(stPlumeRewards)){
    try IDepositRouter(address(this)).tryDepositReward{value: msg.value}() {} catch {
        currentWithheldETH += msg.value;
    }
    return;
}
```

Document the `minStake` and add-validator runbook responses for operations.

---

### F-5 — `setFees` cap of 100% with owner-or-timelock gate — Low

**File:** [stPlumeMinter.sol:590-597](src/stPlumeMinter.sol#L590-L597)

```solidity
require(newInstantFee <= 1000000 && newStandardFee <= 1000000, "Fees too high");
```

`RATIO_PRECISION = 1e6`, so the cap is 100%. `onlyByOwnGov` accepts owner OR timelock; an admin mistake (or compromise) could set the fee very high and drain redemptions into `withHoldEth`. Recoverable: a follow-up `setFees` call corrects it before most users withdraw.

This is admin-trust hygiene rather than a protocol-level bug; governance is responsible for not making the mistake. Still worth tightening defense in depth.

**Recommendation:** hardcode a meaningful cap (e.g., `5%` = 50000). Optionally, route fee changes through `timelock_address` only.

---

### F-6 — `recoverEther` / `recoverERC20` can sweep tracked protocol balances — Low

**File:** [frxETHMinter.sol:124-137](src/frxETHMinter.sol#L124-L137)

The inherited `recoverEther` / `recoverERC20` accept any amount with no exclusion for `currentWithheldETH` or pending reward tokens. The owner could drain user-owed liquidity (instant-redemption buffer) or claimed reward tokens that haven't yet been routed through `_loadRewards`. Recoverable via `addFundsDirectly` if a mistake happens, but a hostile actor with the owner key has no on-chain limit.

This is admin-trust hygiene; the responsibility rests on multisig/timelock policy rather than the contract.

**Recommendation:** add an exclusion `require(amount <= address(this).balance - currentWithheldETH - totalInstantUnstaked)` and restrict to `timelock_address` only.

---

### F-7 — Synthetix reward dilution lag for new depositors — RESOLVED

**Status:** Fixed in [stPlumeMinter.sol:557](src/stPlumeMinter.sol#L557). `_submit(address, uint16)` now calls `_rebalance()` at the top before minting:

```solidity
function _submit(address recipient, uint16 validatorId) internal returns (uint256 amount) {
    _rebalance();   // flush pending rewards before snapshotting userRewardPerTokenPaid
    amount = super._submit(recipient);
    require(amount >= minStake, "not enough to stake");
    _depositEther(amount, validatorId);
    return amount;
}
```

Every deposit now claims and loads any pending PLUME rewards on `plumeStaking` before `frxETHToken.minter_mint` fires the `_beforeTokenTransfer` → `handleTokenTransfer(recipient)` → `updateReward(recipient)` chain. New depositors enter at the post-rebalance `rewardPerTokenStored`, capturing nothing from the pre-existing pipeline.

The dilution window is closed: between rebalances, no rewards accrue on `plumeStaking` that aren't already in `rewardRate` because every deposit triggers a rebalance.

**Original finding kept below for context:**

---

### F-7 (original) — was Low/Info

**Files:** [stPlumeMinter.sol:550-559](src/stPlumeMinter.sol#L550-L559), [stPlumeRewards.sol:88-150](src/stPlumeRewards.sol#L88-L150)

`stPlumeRewards` distributes claimed PLUME at `rewardRate` over a 7-day cycle. `rewardRate` is set on each `_loadRewards` call. Between successive `_loadRewards`, rewards continue to accrue on `plumeStaking` but are not yet reflected in `rewardPerTokenStored`. A depositor entering during this lag captures pro-rata of the unloaded pipeline (which they did not earn) by sharing the next loaded distribution.

With a daily keeper bot calling `_rebalance` (or any user op triggering it), the steady-state pipeline ≈ `rewardRate × 7d`. Attacker capture ≈ `~3.5d × emission × attacker_share`. With 5% APR and 50% share, an attacker with 1M PLUME nets ~480 PLUME of pipeline capture at the cost of ~5753 PLUME in opportunity vs direct staking + 150 PLUME in fees over a 42-day cooldown. The attack is sub-economical (~0.3% annualized advantage).

**Recommendation:** add `_rebalance()` at the top of `_submit` so every deposit flushes the pipeline before the depositor's `userRewardPerTokenPaid` is set:

```solidity
function _submit(address recipient, uint16 validatorId) internal returns (uint256 amount) {
    _rebalance();
    amount = super._submit(recipient);
    require(amount >= minStake, "not enough to stake");
    _depositEther(amount, validatorId);
    return amount;
}
```

`super._submit` calls `frxETHToken.minter_mint`, which fires `_beforeTokenTransfer → handleTokenTransfer(recipient) → updateReward(recipient)` *after* `_rebalance` has flushed the pipeline. New depositors enter at post-rebalance `rewardPerTokenStored`. One-line change; closes the informational concern entirely.

---

### F-8 — `MyPlumeFeed.getTotalDeposits` undercounts cooling/parked balances and is stale post-slash — Medium

**File:** [Periphery/MyPlumeFeed.sol:46-48](src/Periphery/MyPlumeFeed.sol#L46-L48)

Current formula:

```solidity
return getPlumeStakedAmount() + currentWithheldETH() - totalInstantUnstaked() - getMyPlumeRewards();
```

Three issues:

1. `getPlumeStakedAmount()` reads `stakeInfo(this).staked`, which excludes funds in `cooled` and `parked` states on `plumeStaking`. Once `_processBatchUnstake` moves funds staked → cooling, the numerator drops while the corresponding `totalSupply` reduction has already happened at unstake-time. Result: `getMyPlumePrice()` undershoots between batch processing and `withdraw`.

2. `totalInstantUnstaked` covers only the instant-redemption-reserved portion. Queued non-instant unstakes are not subtracted, so between `unstake` (supply burn) and `_processBatchUnstake` (`staked` decrement), the price feed *spikes upward*.

3. **Post-slash staleness.** Plume's `_performSlash` zeros only validator-level totals (`validatorTotalStaked[V]`, `validatorTotalCooling[V]`) and the global aggregates. Per-user `userValidatorStakes[user][V]` and aggregate `stakeInfo[user].staked` are NOT auto-updated; they remain stale until Plume admin runs `adminClearValidatorRecord(this, V)`. Between slash-finalization and Plume admin cleanup, `stakeInfo(this).staked` overstates by the slashed amount → `getTotalDeposits()` and `getMyPlumePrice()` over-report. Integrators using this feed for collateral pricing get inflated values during this gap. The duration of the gap is bounded only by Plume governance responsiveness.

**Recommendation:** read protocol-owned PLUME using both `getUserValidators(this)` (Plume-side filter that excludes slashed validators) and the per-validator stakes, summing only across non-slashed validators:

```solidity
function getTotalDeposits() public view returns (uint256) {
    uint256 plumeOwned = 0;
    uint16[] memory validators = plumeStaking.getUserValidators(address(stPlumeMinter));
    for (uint i = 0; i < validators.length; i++) {
        plumeOwned += plumeStaking.getUserValidatorStake(address(stPlumeMinter), validators[i]);
    }
    // Add cooling and parked portions via stakeInfo, then subtract any portion attributable to slashed validators.
    // Verify the precise field semantics in PlumeStakingStorage.StakeInfo.
    PlumeStakingStorage.StakeInfo memory info = plumeStaking.stakeInfo(address(stPlumeMinter));
    plumeOwned += info.cooled + info.parked;

    return plumeOwned
         + stPlumeMinter.currentWithheldETH()
         - stPlumeMinter.totalUnstaked()
         - stPlumeMinter.lostBackingFromSlash()  // F-2 register
         - getMyPlumeRewards();
}
```

Notes:
- `getUserValidators` already filters out slashed validators (per Plume's `ValidatorFacet` line ~917), so summing per-validator avoids the stale `stakeInfo[user].staked` issue.
- The cooling/parked totals from `stakeInfo` may also include slash-affected portions; cross-check field semantics — if Plume reduces these on slash, no further correction needed; if not, subtract the protocol's `lostBackingFromSlash` register (F-17) directly.
- Verify `StakeInfo` field names against [interfaces/PlumeStakingStorage.sol](src/interfaces/PlumeStakingStorage.sol).

Severity raised to Medium because the post-slash overestimation directly mis-prices any consumer using this feed for LTV or oracle purposes during the (potentially long) Plume admin response window.

---

### F-9 — `_withdraw` "Insufficient funds to cover deficit" misleading error and brittle invariant — Low

**File:** [stPlumeMinter.sol:259-264](src/stPlumeMinter.sol#L259-L264)

The deficit branch's `require(amount-withdrawn < fee, ...)` is intended as a rounding-error guard, but its error message ("Insufficient funds to cover deficit") fires in two completely different scenarios:

- Slash shortfall (F-3): `amount - withdrawn` = the slashed amount, dwarfs `fee`, permanent revert.
- Keeper lateness: `_processBatchUnstake` was called after `request.timestamp`, plumeStaking cooldown not yet complete at user's withdraw, `withdrawn = 0`, message reads as if there's a fund shortage when actually it's a timing issue.

**Recommendation:** distinguish the cases:

```solidity
require(plumeStaking.amountWithdrawable() == 0 || withdrawn > 0,
    "Underlying validator cooldown not yet complete; retry later");
require(amount - withdrawn < fee,
    "Slash-induced shortfall; admin must settle (clearSlashedValidatorState)");
```

Combined with F-3, the second branch becomes a graceful settlement rather than a revert.

---

### F-10 — `PAUSER_ROLE` not granted in `initialize` — Low

**Files:** [stPlumeMinter.sol:63-79](src/stPlumeMinter.sol#L63-L79), [stPlumeMinter.sol:621-632](src/stPlumeMinter.sol#L621-L632), [script/deployMinter.s.sol:38-52](script/deployMinter.s.sol#L38-L52)

`initialize` grants `DEFAULT_ADMIN_ROLE`, `REBALANCER_ROLE`, `CLAIMER_ROLE`, `HANDLER_ROLE` but not `PAUSER_ROLE`. The two pause toggles are gated by `PAUSER_ROLE`. Default admin can grant the role manually post-deployment, but until they do, the protocol cannot be paused.

The deploy script does not currently grant `PAUSER_ROLE` either.

**Recommendation:** in `initialize`:
```solidity
_setupRole(PAUSER_ROLE, _owner);
```
Or update the deploy script to grant it explicitly after `setStPlumeRewards`.

---

### F-11 — `addValidator` accepts `validatorId == 0` — Low

**File:** [stPlumeMinter.sol:81-86](src/stPlumeMinter.sol#L81-L86)

The codebase uses `validatorId == 0` as a sentinel meaning "any validator" in `_unstake`, `_depositEther`, and `submitForValidator`. Adding a validator with id `0` would corrupt branch logic.

**Recommendation:** `require(validator.validatorId != 0, "Invalid validator id")`.

---

### F-12 — `addFundsDirectly` emits misleading `ETHSubmitted` event — Low

**File:** [stPlumeMinter.sol:168-175](src/stPlumeMinter.sol#L168-L175)

```solidity
emit ETHSubmitted(address(this), address(this), msg.value, validatorId);
```

The fourth parameter of `ETHSubmitted` is `withheld_amt` ([frxETHMinter.sol:141](src/frxETHMinter.sol#L141)); passing `validatorId` produces nonsensical values for off-chain indexers. Function also doesn't mint `myPLUME` (intentional, for slash-recovery), making the event semantics doubly confusing.

**Recommendation:** add a dedicated `event SlashRecoveryFunded(uint16 indexed validatorId, uint256 amount)` and emit it instead.

---

### F-13 — Reward ETH ping-pong (gas) — Info

`_rebalance` → claim PLUME → `_loadRewards` → send ETH to `stPlumeRewards` → `stPlumeRewards` splits and sends ETH back to minter (`addWithHoldFee` + `receive`) → `_depositEther` re-stakes. Two extra `CALL` ops per rebalance.

**Recommendation:** pass amounts as `uint256` parameters and let the minter retain the ETH; only inform `stPlumeRewards` of the split. Optional micro-optimization.

---

### F-14 — Linear validator-array loops in hot paths — Info

`_unstake`, `_depositEther`, `_checkValidator`, `processBatchUnstake` all iterate `validators[]` linearly (O(N)). With many validators, gas cost grows. Set a soft cap on validator count or migrate to a mapping-indexed structure for membership checks.

---

### F-15 — `getMyPlumePrice` divide-by-zero when supply is 0 — Info

**File:** [Periphery/MyPlumeFeed.sol:50-52](src/Periphery/MyPlumeFeed.sol#L50-L52)

```solidity
function getMyPlumePrice() public view returns (uint256) {
    return getTotalDeposits() * 1e18 / myPlume.totalSupply();
}
```

Reverts when supply is 0 (immediately post-deployment). Cosmetic; recommend returning `1e18` in the supply-zero case.

---

### F-16 — Unused `HANDLER_ROLE` grant — RESOLVED

**Status:** The constant declaration ([stPlumeMinter.sol:23](src/stPlumeMinter.sol#L23)) and grant in `initialize` ([stPlumeMinter.sol:71](src/stPlumeMinter.sol#L71)) are both commented out. The role was unused and has been removed from the runtime code path. Bytecode reduction.

---

### F-18 — Slash-haircut accounting depends on admin maintaining `slashedAmount` — Low

**Files:** [stPlumeMinter.sol:33](src/stPlumeMinter.sol#L33), [stPlumeMinter.sol:435-441](src/stPlumeMinter.sol#L435-L441), [stPlumeMinter.sol:621-623](src/stPlumeMinter.sol#L621-L623)

The `slashedAmount` storage variable drives the haircut applied in `_unstake`. There is no on-chain mechanism to compute or verify it — governance writes any value via `setSlashedAmount(uint256)`:

```solidity
function setSlashedAmount(uint256 amount) external onlyByOwnGov {
    slashedAmount = amount;
}
```

This is **admin-trust** territory:

- Setting `slashedAmount` too high → users get a larger-than-necessary haircut, governance retains the difference as ambient backing.
- Setting `slashedAmount` too low → users get less haircut than the actual loss, protocol becomes structurally insolvent (last-out users unable to redeem).
- Forgetting to update after `addFundsDirectly` insurance backfill → users continue paying haircut on already-restored backing.
- Manual proportional decrement on each redemption (`slashedAmount -= (amount - newAmount)`) makes the math correct only if the *initial* value was correct.

**No bug per se** — governance is already the trusted root for fees, withdrawals, and validator selection — but operations must treat `slashedAmount` updates with care:

1. **On slash detection:** read `getUserValidatorStake(this, slashedV)` (still-stale, returns the pre-slash amount) and use that as the loss measurement. Subtract any insurance backfill done in the same tx.
2. **On insurance refill:** decrement `slashedAmount` by the refill amount via `setSlashedAmount(slashedAmount - refill)`.
3. **On full recovery:** `setSlashedAmount(0)` to disable the haircut.

**Recommendation:**
- Add an event in `setSlashedAmount` (currently silent) so off-chain monitoring can detect haircut state changes:
  ```solidity
  event SlashedAmountSet(uint256 oldAmount, uint256 newAmount);
  ```
- Document the recovery runbook prominently (Section 11.5).
- Consider a sanity-check require: `slashedAmount < frxETHToken.totalSupply()` to prevent the haircut from exceeding 100% of supply. With `slashedAmount >= totalSupply`, `(s - slashedAmount)` underflows in Solidity 0.8 (revert on underflow protects against insolvency-by-overstatement, but produces a confusing revert rather than a clean refusal). One-line addition: `require(amount < frxETHToken.totalSupply(), "Bad slash");`.

Severity: Low. The mechanism is correct given honest admin coordination; the risk is operational mishandling rather than a contract-level vulnerability.

---

### F-17 — `unstakeGov` interference with user queue and batch processing — RESOLVED

**Status:** Fixed in [stPlumeMinter.sol:146-157](src/stPlumeMinter.sol#L146-L157). `unstakeGov` now merges its amount into `totalQueuedWithdrawalsPerValidator[V]`, atomically processes the combined queue+gov amount through `plumeStaking.unstake`, zeros the queue, and resets the timer:

```solidity
function unstakeGov(uint16 validatorId, uint256 amount) external nonReentrant onlyByOwnGov returns (uint256 amountRestaked) {
    _rebalance();
    (bool active, , uint256 stakedAmount, ) = plumeStaking.getValidatorStats(uint16(validatorId));
    uint256 queued = totalQueuedWithdrawalsPerValidator[validatorId];
    uint256 total = amount + queued;

    if (active && stakedAmount > 0 && stakedAmount >= total) {
        amountRestaked = plumeStaking.unstake(uint16(validatorId), total);
        totalQueuedWithdrawalsPerValidator[validatorId] = 0;
        nextBatchUnstakeTimePerValidator[validatorId] = block.timestamp + batchUnstakeInterval;
    }
}
```

**Original interference modes resolved:**

1. **Stake-depletion brick** — eliminated. The function consumes the user queue in the same call, so V's stake on plumeStaking is no longer left in a state where `validatorStakedAmount < totalQueued[V]`. No underflow at [stPlumeMinter.sol:480](src/stPlumeMinter.sol#L480), no revert in subsequent `_processBatchUnstake(V)`.

2. **Timer-based cooldown consolidation** — mitigated. `nextBatchUnstakeTimePerValidator[V] = now + batchUnstakeInterval` pushes the next timer-driven batch fire past `now + cooldownInterval` (since `batchUnstakeInterval > cooldownInterval` by configuration). Governance's cooling matures before the next timer fire, so timer-driven batches don't consolidate.

3. **`amount = 0` semantics** — useful side-effect. Calling `unstakeGov(V, 0)` becomes a manual queue-flush: it processes the user queue and resets the timer without governance unstaking anything additional. Equivalent to a forced batch fire.

**Residual considerations (operational, not bugs):**

- **Threshold-based consolidation can still occur.** If user activity hits `withdrawalQueueThreshold` between the `unstakeGov` call and its cooldown maturation, an inline batch fire inside `_unstake` will consolidate with the gov cooldown on Plume's side, extending it. Mitigate by raising `withdrawalQueueThreshold` temporarily during the gov-unstake → withdrawGov cycle, or accept a few days of extra wait.

- **Existing cooling on V at call time.** If V already has cooling on Plume (from a prior batch or prior gov unstake), the new unstake bundles into the existing entry and resets its end time. Pre-existing user requests with `request.timestamp` tied to the prior batch may briefly revert until the new consolidated end. Mitigate by checking `_getCoolDownPerValidator(V).amount == 0` off-chain before calling, or accept a brief re-try window for those users.

- **Stake check looseness.** `stakedAmount` reads `getValidatorStats(V).totalStaked` (validator's global stake across all delegators), not the protocol's stake on V. The check is therefore looser than `getUserValidatorStake(this, V) >= total`. In practice, a borderline call passes the if-check but `plumeStaking.unstake` reverts cleanly with its own error. No corruption risk; preserves the original `unstakeGov` looseness pattern.

The new design is strictly better than the original `unstakeGov` (which silently failed to coordinate with the user queue). Severity: resolved.

---

## 5. ERC-Standard Conformance

| Standard | Contract | Conformance |
|---|---|---|
| ERC-20 | `frxETH` (myPLUME) | Conforms via OZ `ERC20` + `ERC20Burnable`. `_beforeTokenTransfer` makes an external call to `stPlumeRewards.handleTokenTransfer` — non-reentrant on rewards side, but the external dependency means a misconfigured/upgraded `stPlumeRewards` could brick all `myPLUME` transfers. Consider a try/catch with a circuit breaker. |
| ERC-2612 (Permit) | `frxETH` | Full conformance via OZ `ERC20Permit`. |
| ERC-4626 | `sfrxETH` | Conforms via `xERC4626`. Note the `name`/`symbol` ("Wrapped Mystic Staked Plume" / "wMystPlume") differ from underlying — consumers should not assume share-token name. |
| ERC-165 | None | Not implemented. Optional but recommended for `AccessControl` discoverability. |

---

## 6. Upgradeability and Storage

- `stPlumeMinter` extends `frxETHMinter` extends `OperatorRegistry` extends `OwnedUpgradeable` and adds `AccessControlUpgradeable` as the leftmost parent. Storage gaps: `__gap[10]` in `OwnedUpgradeable`, `OperatorRegistry`, `frxETHMinter`; `__gap[50]` in `stPlumeMinter`. Confirm with `forge inspect storage-layout` against any prior deployment.
- `stPlumeRewards` storage layout has `__gap[50]` placed *before* the user-mapping fields. The convention is for the gap to come **last**; future fields added before the gap risk corrupting `userRewardPerTokenPaid` / `userRewards`. Plan accordingly.
- `_setupRole` is the OZ v4 idiom; if migrating to OZ v5, swap to `_grantRole`.

**Recommendation:** lock the storage layout in CI for both proxies (snapshot via `forge inspect storage-layout` and diff in PR checks).

---

## 7. Centralization Inventory

| Power | Holder | Risk |
|---|---|---|
| Grant/revoke all roles | `DEFAULT_ADMIN_ROLE` (deployer/owner) | Standard |
| Add/remove validators, set fees, set min stake, set max validator %, recover ether/ERC20 | `onlyByOwnGov` (owner OR timelock) | High — fees and recover paths can extract value (F-5, F-6) |
| Trigger rebalance, restake, stake withheld, add funds directly | `REBALANCER_ROLE` | Operational |
| Claim rewards | `CLAIMER_ROLE` | Operational |
| Pause submits / deposits | `PAUSER_ROLE` | **Not granted by default — F-10** |

**Recommendation:** segregate value-extracting permissions (fees, recover, fee withdrawal) onto `timelock_address` only, distinct from `owner`.

---

## 8. Recommended Remediation Order

1. **Slash recovery system (F-1, F-2, F-3).** One coordinated change: concentration cap at admission (F-1), `recordSlash` admin function maintaining `lostBackingFromSlash` plus slash-aware `processBatchUnstake` and status checks via `getValidatorInfo` (F-2), socialized haircut on redemption (F-3). Bounds the worst case and makes the protocol degrade gracefully under slash.
2. **Price feed accuracy (F-8).** Switch to per-validator iteration via `getUserValidators` and subtract `lostBackingFromSlash`.
3. **Reward dilution one-liner (F-7).** Add `_rebalance()` at top of `_submit`.
4. **Reward-path liveness (F-4).** `try/catch` in `receive()` for the rewards-source branch.
5. **Governance hygiene (F-5, F-6).** Hardcode fee cap; gate recover on timelock; add `currentWithheldETH` exclusion.
6. **Code quality / Low (F-9 through F-16).** Misleading errors, missing role grants, sentinel-id check, cleanup events, gas optimizations.

---

## 9. Tests

The existing test suite (`test/frxETHMinter.t.sol`, `test/frxETH_sfrxETH_combo.t.sol`) is inherited from Frax and does not exercise Plume-specific paths. The fork test directory (`test/fork/`) should be confirmed to cover at minimum:

- `unstake → processBatchUnstake → withdraw` round-trips with random deposit/withdraw sequences and validator caps.
- Slash simulation: stub `plumeStaking.unstake` to revert with `ActionOnSlashedValidatorError` when called for a flagged validator; verify `processBatchUnstake` skips it once F-2 is fixed; verify `clearSlashedValidatorState` cleans up; verify users receive haircut payouts via F-3 path.
- Reward dilution invariant: `sum(getUserRewards) ≤ rewardPerToken × totalSupply` ± epsilon.
- Concentration cap: deposits past `maxValidatorPercentage` route to other validators.

---

## 10. Conclusion

The protocol's structural design (1:1 `myPLUME` + Synthetix-style yield + ERC-4626 wrapper) is internally coherent and inherits Frax's audited foundation. The Plume integration is the dominant risk surface, and its dominant subset is per-validator slash exposure.

With the contract changes already applied:

- **Active-check** in `processBatchUnstake` (F-2)
- **`addFundsDirectly` co-bumping `totalInstantUnstaked`** for stuck-request settlement (F-3)
- **`slashedAmount` + on-chain NAV-preserving haircut** in `_unstake` for socialized loss when insurance is insufficient (F-3)
- **`_rebalance()` at top of `_submit`** to close the reward-dilution window (F-7)
- **Queue-merge in `unstakeGov`** to eliminate stake-depletion brick (F-17)
- **`HANDLER_ROLE` removed** for size reduction (F-16)
- **Various string shortenings** for size compliance

…the on-chain mechanics handle slash recovery, stuck-request settlement, reward dilution, `unstakeGov` interference, and partial-coverage haircuts. The remaining defense is operational — concentration limits, insurance treasury, withhold ratio, and the slash-response runbook (Section 11).

Other open findings (F-1 operational, F-4 through F-15 hygiene, F-18 admin-trust) introduce no immediate fund-loss vectors under current parameters. Address them in a follow-up release as bandwidth allows.

---

## 11. Slashing Countermeasures (Operational Plan)

The protocol's defense against Plume's per-validator binary slashing is layered. None of the layers below require contract changes — they're governance configuration plus off-chain infrastructure.

### 11.1 Concentration Limits

Set per-validator caps via `setMaxValidatorPercentage`:

| Validator | Cap |
|---|---|
| Plume canonical validator | 40% (`400000`) |
| Validator A | 15% (`150000`) |
| Validator B | 15% (`150000`) |
| Validator C | 15% (`150000`) |
| Validator D | 15% (`150000`) |
| **Total cap** | **100%** |

Worst-case single-event loss:
- Plume validator slashed: **−40% TVL**
- Any other validator slashed: **−15% TVL**

The 40% on Plume's canonical validator is a calculated trust assumption — Plume Network is unlikely to vote-slash its own validator under normal governance. The 15% cap on the others bounds tail risk on operators outside Plume's direct governance.

**Implementation:** call `setMaxValidatorPercentage(V_id, percentage)` for each of the five validators after deployment. This is governance-only; no code change.

### 11.2 Pre-Slash Notification + Active-Stake Evacuation

Plume's invariant `cooldownInterval > maxSlashVoteDuration` ensures users can withdraw safely only when a slash *fails to pass*. If a slash succeeds, active stake on the targeted validator cannot be evacuated by reacting to the on-chain `SlashVoteCast` event — the cooldown is too long to mature before slash finalization.

However, **off-chain advance notice from validator operators** can extend the reaction window. If governance receives notification at least `cooldownInterval - maxSlashVoteDuration` *before* the public vote begins, evacuation via `unstakeGov` becomes feasible:

| `maxSlashVoteDuration` | Required head-start | Likelihood of useful notice |
|---|---|---|
| ~1 day | ~20 days | Practical with informal validator coordination |
| ~7 days | ~14 days | Practical |
| ~14 days | ~7 days | Practical |
| ~20 days | ~1 day | Tight; depends on observability |

**On-chain fallback** (when no advance notice arrives): listen for `SlashVoteCast` events. On detection:
1. **Immediately** call `togglePauseSubmits()` to stop new mints from entering at par. Do **not** call `togglePauseDepositEther` — that also blocks user exits via the `_rebalance()` check.
2. Alert ops team and community.
3. Pre-position the post-slash recovery transaction (insurance backfill via `addFundsDirectly`) so it lands immediately after `ValidatorSlashed`.

Reactive monitoring cannot save active stake on the target validator, but it bounds the damage by stopping new exposure and accelerating recovery.

### 11.3 Insurance Treasury

Off-chain split of the existing 10% yield fee (no contract change):

| Allocation | Share of yield | Destination |
|---|---|---|
| User yield | 90% | distributed via `stPlumeRewards` |
| Protocol revenue | 5% | operational multisig |
| Insurance fund | 5% | separate insurance multisig |
| Withdrawal fees (REDEMPTION_FEE, INSTANT_REDEMPTION_FEE) | — | protocol revenue multisig |

**Where to hold the insurance fund:** anywhere except Plume validators. Acceptable: a separate multisig holding native PLUME, wrapped PLUME on a different chain, stable equivalents in lending markets, or simply ETH/PLUME in a cold wallet. **Not acceptable:** restaking the insurance into plumeStaking — that re-exposes it to slash.

**Funding rate:** ~0.05% TVL/year (5% × 10% of 5% APR). For meaningful coverage, the insurance treasury should be **seeded from launch reserves**. Pure yield-fee accumulation is a top-up, not the primary backstop.

**On-slash deployment:** insurance multisig calls `addFundsDirectly{value: lostAmount}(0)` on the minter. The contract co-bumps `currentWithheldETH` and `totalInstantUnstaked`, allowing stuck `WithdrawalRequest`s to be settled via the existing `_withdraw` flow (per F-3).

### 11.4 Withhold Ratio Increase

Call `setWithholdRatio(50000)` to raise the buffer from the default 2% to **5%**.

Effect:
- New deposits: 95% goes to plumeStaking, 5% accumulates in `currentWithheldETH`.
- Larger liquid buffer absorbs more instant unstakes without queueing — smoother UX.
- The buffer is **never** sent to plumeStaking, so it's structurally immune to slashing.

Trade-off: 5% of TVL doesn't earn yield. At 5% APR, that's 0.25% yield drag at the protocol level. Accepted as the cost of liveness during slash recovery.

### 11.5 Post-Slash Recovery Runbook

```
TRIGGER: ValidatorSlashed(V, ...) event observed on plumeStaking

Step 1 (immediate, automated):
  - togglePauseSubmits()                                       // halt new mints
  - off-chain: read getUserValidatorStake(this, V)             // = exact pre-slash loss
                                                                  (still-stale until Plume admin clears)
  - off-chain: identify all WithdrawalRequests against V       // sum stuckAmount
  - off-chain: alert ops + community

Step 2A (insurance fully covers loss):
  - addFundsDirectly{value: lossAmount}(0)                     // restores buffer + earmarks tIU
  - verify: currentWithheldETH ≥ totalInstantUnstaked
            AND totalInstantUnstaked ≥ sum(stuck request totalAmounts)
  - slashedAmount stays 0 — no haircut applied

Step 2B (insurance partially covers loss):
  - addFundsDirectly{value: coveredAmount}(0)                  // restore what insurance can
  - setSlashedAmount(lossAmount - coveredAmount)               // apply haircut on residual
  - All future principal unstakes get pro-rata haircut

Step 3 (per affected user, automated or self-service):
  - User calls withdraw(id)                                    // settles from buffer
  - User calls unstake(amount) for new exits                   // gets haircut if slashedAmount > 0

Step 4 (cleanup):
  - removeValidator(slashedVIdx, true)                         // pop V from validators[]
  - togglePauseSubmits()                                       // unpause when buffer is healthy
  - setMaxValidatorPercentage on remaining validators if redistribution is desired

Step 5 (insurance refill over time):
  - As yield fees accumulate insurance, decrement haircut:
    setSlashedAmount(slashedAmount - newRefill)
  - Final state: setSlashedAmount(0) when fully restored

Step 6 (followup):
  - Publish post-mortem
  - Replenish insurance treasury from protocol revenue if drawn down
  - Review concentration policy
```

### 11.6 What's still residual after all four layers

| Risk | Layer that addresses it | Residual |
|---|---|---|
| Plume canonical validator slash (-40% TVL) | Insurance treasury + on-chain haircut + concentration cap | If insurance < loss: `setSlashedAmount(residual)` socializes the rest pro-rata across redeemers. NAV-preserving math ensures no first-out advantage. Residual: governance must coordinate `setSlashedAmount` correctly (see F-18). |
| Concurrent slashes on multiple validators | Same | Compounded loss; sum into a single `slashedAmount` value. Realistically very low probability (would require coordinated unanimity across multiple validators simultaneously). |
| `unstakeGov` threshold-based cooldown consolidation | Operational only | A few days of delayed `withdrawGov` in worst case. Accept or raise threshold during recovery. |
| Free-rider depositors during recovery (mint at par while haircut implicit) | `togglePauseSubmits` immediately | Depends on automation responsiveness. Manual lag is bounded by ops alert time. |
| Admin mis-sets `slashedAmount` (over/under) | None — admin trust | Mitigated by emit-on-set monitoring (recommended in F-18) and the `slashedAmount < totalSupply` sanity require. |

The combined defense is structural (concentration), economic (insurance), liquidity-based (withhold buffer), accounting (on-chain haircut), and operational (runbook). No single layer is sufficient on its own; all five together bound the worst case to a manageable, recoverable event.
