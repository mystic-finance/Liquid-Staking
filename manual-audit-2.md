# myPLUME LST Protocol — Manual Security Audit (Round 2)

**Date:** 2026-05-07
**Branch:** `stake-plume-new`
**Scope (in-tree):**

| File | Role |
|---|---|
| [src/stPlumeMinter.sol](src/stPlumeMinter.sol) | Minter / withdrawal queue / validator router |
| [src/stPlumeRewards.sol](src/stPlumeRewards.sol) | Synthetix-style yield accumulator |
| [src/frxETH.sol](src/frxETH.sol) | LST principal token (myPLUME) |
| [src/frxETHMinter.sol](src/frxETHMinter.sol) | Frax-fork base minter |
| [src/sfrxETH.sol](src/sfrxETH.sol) | ERC-4626 wrapper (wMystPlume) |
| [src/OperatorRegistry.sol](src/OperatorRegistry.sol) | Validator registry |
| [src/ERC20/ERC20PermitPermissionedMint.sol](src/ERC20/ERC20PermitPermissionedMint.sol) | ERC-20 + ERC-2612 base |
| [src/Periphery/MyPlumeFeed.sol](src/Periphery/MyPlumeFeed.sol) | Pricing feed |

**External dependency:** Plume L1 staking diamond ([plumenetwork/contracts/plume](https://github.com/plumenetwork/contracts/tree/main/plume)).

This is a follow-up audit to [manual-audit.md](manual-audit.md). It re-walks all state-mutating paths, re-evaluates ERC-20/2612/4626 conformance for the LST stack, and reflects rebuttals from the protocol team. Findings already documented and resolved in the prior round (F-2, F-3, F-7) are not re-litigated here; findings still open from round 1 are cross-referenced rather than duplicated.

---

## 1. Executive Summary

The LST stack is structurally sound. The Plume-integration design — per-validator batch unstaking, withheld-ETH liquidity buffer, explicit `slashedAmount` socialized-loss accumulator, and post-slash recovery via `addFundsDirectly` + `setSlashedAmount` — is internally consistent and reflects active hardening across multiple remediation rounds.

This round surfaces no critical issue causing direct loss of funds under honest operation. The remaining items are split between:

- One **operational-risk** path on the principal token's transfer hook, which couples ERC-20 transferability to a role state that can be misrotated (M-1).
- A handful of **low-severity** governance-hardening items around `setSlashedAmount` and `addValidator`.
- **Informational** notes on price-feed semantics, registry ordering, and an intentional carve-out where yield withdrawal is not haircut by `slashedAmount`.

Storage layout for the proposed upgrade (adding `slashedAmount` and reducing `__gap` from 50→49 in `stPlumeMinter`) was verified against git history and is correct: `AccessControlUpgradeable` has been in `stPlumeMinter`'s linearization since the first upgradeable version (`0188199`), so no slot reshuffle occurs. Parent contracts' gaps (`OwnedUpgradeable`, `OperatorRegistry`, `frxETHMinter`) do not need to be reduced — only the contract that adds state consumes its own gap.

The price-feed haircut for `slashedAmount` has been applied in [MyPlumeFeed.getTotalDeposits()](src/Periphery/MyPlumeFeed.sol#L46-L50) since round 1, closing what was previously a Medium finding.

---

## 2. Resolved / Withdrawn Since Round 1

| Round-1 ref | Title | Disposition this round |
|---|---|---|
| Price-feed `slashedAmount` haircut | `MyPlumeFeed.getTotalDeposits` undercounts post-slash | **Fixed** — [MyPlumeFeed.sol:49](src/Periphery/MyPlumeFeed.sol#L49) now subtracts `stPlumeMinter.slashedAmount()` |
| `getMyPlumePrice` divide-by-zero | Reverts when `totalSupply == 0` | **Fixed** — [MyPlumeFeed.sol:53-55](src/Periphery/MyPlumeFeed.sol#L53-L55) returns 0 on empty supply |
| Storage layout shift from `AccessControlUpgradeable` | Potential slot reshuffle on upgrade | **Withdrawn** — `AccessControlUpgradeable` was already in the inheritance chain at first upgradeable deployment; the round-2 diff only adds `slashedAmount` and consumes 1 slot of `stPlumeMinter`'s own `__gap` |
| `_unstake` "Already requested" guard, `minter_burn_from` allowance bypass, `removeMinter` array holes, `PAUSER_ROLE` initialize gap | Already documented | **Cross-referenced** to round 1 / acknowledged |

---

## 3. Findings Summary

| # | Title | Severity |
|---|---|---|
| M-1 | Token transfer hook reverts under `HANDLER_ROLE` mis-rotation or reward-pointer swap-without-grant | **Medium (operational)** |
| L-1 | `setSlashedAmount` lacks event and ceiling | Low |
| L-2 | `addValidator` does not validate Plume-side `active` / `slashed` state | Low |
| L-3 | Reward-path `_depositEther` revert can block deposits | Low — cross-ref [manual-audit.md F-4](manual-audit.md) |
| L-4 | `PAUSER_ROLE` not granted in `initialize` | Low — cross-ref [manual-audit.md F-10](manual-audit.md) |
| I-1 | `unstakeRewards` does not apply `slashedAmount` haircut (intentional) | Informational |
| I-2 | Setters lack purpose-specific events | Informational |
| I-3 | `MyPlumeFeed.totalRewards` double-counts vesting + unclaimed | Informational |
| I-4 | `_unstake` validator-loop is registry-order, not concentration-aware | Informational |
| I-5 | `_submit` mint-then-rebalance ordering invariant | Informational |
| I-6 | `removeMinter` leaves `address(0)` holes in `minters_array` | Informational |

---

## 4. Findings

### M-1 — Medium (operational) — Token transfer hook reverts under `HANDLER_ROLE` mis-rotation

**Location:** [src/frxETH.sol:45-58](src/frxETH.sol#L45-L58), [src/stPlumeRewards.sol:153](src/stPlumeRewards.sol#L153)

```solidity
// frxETH._beforeTokenTransfer
if (stPlumeRewards != address(0)) {
    if (!(from == address(0) || from == address(this))) IstPlumeRewards(stPlumeRewards).handleTokenTransfer(from);
    if (!(to   == address(0) || to   == address(this))) IstPlumeRewards(stPlumeRewards).handleTokenTransfer(to);
}

// stPlumeRewards.handleTokenTransfer
function handleTokenTransfer(address user) external onlyRole(HANDLER_ROLE) updateReward(user) {}
```

The `updateReward` body itself does not have a data-driven revert path: `rewardPerToken()` short-circuits on `totalSupply == 0`, and `lastTimeRewardApplicable() - lastSync` cannot underflow given how `loadRewards` and the modifier maintain those two values (the modifier sets `lastSync = lastTimeRewardApplicable()`, which is non-decreasing under monotonic block time). So under correct operational state, **transfers are not at risk.**

The realistic revert paths are role/upgrade-level:

1. **`HANDLER_ROLE` revoked** from the `frxETH` contract on `stPlumeRewards`. The role is granted exactly once during `stPlumeRewards.initialize` ([stPlumeRewards.sol:64](src/stPlumeRewards.sol#L64)) and never re-granted anywhere; if an admin rotates the role and forgets to re-grant, every non-mint/non-burn transfer reverts.
2. **Pointer swap without role grant.** `frxETH.updateStPlumeRewards(newAddr)` is owner-only and atomic on the token side, but it does **not** verify that `newAddr` has granted `HANDLER_ROLE` to `frxETH`. Pointing the token at a freshly deployed rewards contract before granting `HANDLER_ROLE` on it bricks transfers until the role is granted.
3. **Upgrade of `stPlumeRewards`** (it is `Initializable`-pattern and presumably proxy-fronted) to an implementation that reverts in `handleTokenTransfer`.

Because the failure mode is total — every `transfer`, `transferFrom`, and any path through the `sfrxETH` ERC-4626 wrapper depends on this hook — the asymmetry between operational footprint (one missed `grantRole` call) and blast radius (full token DoS) warrants Medium classification despite the absence of an internal revert path.

**Recommendations**

1. Wrap each external call in `try / catch`, falling back to a no-op so a faulty rewards contract degrades to "stale reward sync for this user" rather than "token bricked." The accumulator's `rewardPerTokenStored` is a global; a missed user sync only delays that user's claim accounting and is corrected on the next successful hook call.
2. In `frxETH.updateStPlumeRewards`, optionally probe the new rewards contract for `hasRole(HANDLER_ROLE, address(this))` and revert if not yet granted, making the pointer-swap atomic with the precondition.
3. Document role rotation as a single operation: revoke-after-grant rather than revoke-then-grant.

---

### L-1 — Low — `setSlashedAmount` lacks event and ceiling

**Location:** [src/stPlumeMinter.sol:632-634](src/stPlumeMinter.sol#L632-L634)

```solidity
function setSlashedAmount(uint256 amount) external onlyByOwnGov {
    slashedAmount = amount;
}
```

Gated to `owner` / `timelock`, so this is governance hardening rather than an exploit path. Two concerns:

- **No event.** Off-chain pricing oracles reading `MyPlumeFeed.getTotalDeposits()` (which now subtracts `slashedAmount` — round-1 fix) will see the price step without any on-chain log explaining it. Operational forensics and downstream caches both suffer.
- **No ceiling.** A typo or compromised key setting `slashedAmount > frxETH.totalSupply()`-equivalent value would cause the `_unstake` haircut math to underflow on `s - slashedAmount` and brick all redemptions. The setter accepts arbitrary `uint256`.

**Recommendations**
1. Emit `SlashedAmountSet(uint256 prev, uint256 next, address actor)`.
2. Cap `amount` to a sane bound — e.g. `require(amount <= getTotalDepositsFloor(), "slash too high")` where the floor is a conservative on-chain bound (sum of `info.staked + info.cooled + info.parked + currentWithheldETH`). The cap need not be exact; it just has to prevent the underflow case.
3. (Optional) Pair with a timelock delay on increases — slashes are not instantaneous events and a few hours of recording lag is acceptable. Decreases are normal flow (driven by user `_unstake` calls) and remain ungated.

---

### L-2 — Low — `addValidator` does not validate Plume-side state

**Location:** [src/stPlumeMinter.sol:82-87](src/stPlumeMinter.sol#L82-L87)

```solidity
function addValidator(Validator calldata validator) public override onlyByOwnGov {
    require(!_checkValidator(uint256(validator.validatorId)), "Validator exists");
    validators.push(validator);
    nextBatchUnstakeTimePerValidator[uint16(validator.validatorId)] = block.timestamp + plumeStaking.getCooldownInterval();
    emit ValidatorAdded(validator.validatorId, bytes(""));
}
```

A slashed (`slashed = true`) or inactive (`active = false`) validator can be (re)added with no on-chain feedback. Subsequent behavior is non-uniform:

- Explicit-validator deposits (`submitForValidator`, `_depositEther` with a non-zero `_validatorId`) revert at `require(active, "Validator inactive")` — fine.
- Loop-mode deposits silently skip the dead entry, but the registry now contains a permanent dead slot consumed in every `_depositEther`, `_unstake`, and `processBatchUnstake` loop.

Cheap to fix; meaningfully reduces foot-gun surface for governance UIs that show "validator added" and create false comfort.

**Recommendation**
```solidity
(bool active, , , ) = plumeStaking.getValidatorStats(uint16(validator.validatorId));
require(active, "Validator not active on Plume");
(PlumeStakingStorage.ValidatorInfo memory info, , ) = plumeStaking.getValidatorInfo(uint16(validator.validatorId));
require(!info.slashed, "Validator slashed");
```

---

### L-3 — Low — Reward-path `_depositEther` revert blocks deposits

Cross-referenced from [manual-audit.md F-4](manual-audit.md). The chain `_submit → _rebalance → _claim → _loadRewards → stPlumeRewards.loadRewards → minter.receive → _depositEther` reverts the originating user's deposit if every active validator is at capacity (the `require(remainingAmount == 0, "Insufficient capacity")` at [stPlumeMinter.sol:426](src/stPlumeMinter.sol#L426)).

The clean fix is to wrap the validator-stake step in `_depositEther` so that, on capacity exhaustion, the unstaked remainder falls back to `currentWithheldETH` instead of reverting the entire reward-claim-and-deposit chain. That decouples user submit/unstake liveness from the validator capacity envelope.

---

### L-4 — Low — `PAUSER_ROLE` not granted in `initialize`

Cross-referenced from [manual-audit.md F-10](manual-audit.md). `togglePauseSubmits` and `togglePauseDepositEther` are `onlyRole(PAUSER_ROLE)` ([stPlumeMinter.sol:637-648](src/stPlumeMinter.sol#L637-L648)), but `PAUSER_ROLE` is never assigned in `initialize` ([stPlumeMinter.sol:64-80](src/stPlumeMinter.sol#L64-L80)). Until a follow-up `grantRole` is sent, the emergency pause levers are unreachable. Grant to `_owner` (or to a dedicated emergency multisig) inside `initialize` so the protocol is never deployed in an un-pausable state.

---

### I-1 — Informational — `unstakeRewards` does not apply `slashedAmount` haircut

**Location:** [src/stPlumeMinter.sol:323-334](src/stPlumeMinter.sol#L323-L334), [src/stPlumeMinter.sol:442-452](src/stPlumeMinter.sol#L442-L452)

`_unstake(yield, true, 0)` is invoked with `rewards = true`, which bypasses both `minter_burn_from` and the slash haircut. Per protocol team rebuttal: this is intentional — the rewards path is decoupled from the principal-token economy; yield is paid out at full notional because it has been earned and accounted for separately from the LST burn/price.

Documented here so the carve-out is explicit, and so any future change that consolidates the two paths (or applies the haircut universally) does not silently drop the design intent. Recommendation: add a comment at [stPlumeMinter.sol:444](src/stPlumeMinter.sol#L444) noting that rewards are intentionally exempt from `slashedAmount`.

Note for monitoring: a sufficiently large slash event will leave a window during which yield withdrawal pays at full value while principal redemption is haircut. This is observable on-chain and would constitute a (small, bounded) MEV-style asymmetry but not a bug.

---

### I-2 — Informational — Setters lack purpose-specific events

The following state-changing functions either emit no event or share a generic event with mixed semantics:

- [setFees](src/stPlumeMinter.sol#L602-L609), [setMinStake](src/stPlumeMinter.sol#L611-L614), [setMaxValidatorPercentage](src/stPlumeMinter.sol#L616-L619), [setBatchUnstakeParams](src/stPlumeMinter.sol#L621-L626), [setStPlumeRewards](src/stPlumeMinter.sol#L628-L630), [setSlashedAmount](src/stPlumeMinter.sol#L632-L634) — no events.
- [unstakeGov](src/stPlumeMinter.sol#L147-L158), [withdrawGov](src/stPlumeMinter.sol#L160-L167), [withdrawFee](src/stPlumeMinter.sol#L194-L201) — no events distinguishing governance flows from organic user flows.
- [addFundsDirectly](src/stPlumeMinter.sol#L173-L181) emits `ETHSubmitted` with `validatorId=0`, which is indistinguishable from a normal user submission with full withholding — log forensics cannot separate slash-recovery deposits from user activity.

Add purpose-specific events for each.

---

### I-3 — Informational — `MyPlumeFeed.totalRewards` double-counts

**Location:** [src/Periphery/MyPlumeFeed.sol:95-100](src/Periphery/MyPlumeFeed.sol#L95-L100)

```solidity
function totalRewards() public view returns (uint256) {
    uint256 reward = plumeStaking.getClaimableReward(address(stPlumeMinter), nativeToken);
    uint256 yieldAmount = (reward * stPlumeRewards.YIELD_FEE()) / stPlumeRewards.RATIO_PRECISION();
    uint256 netReward = reward - yieldAmount;
    return getMyPlumeRewards() + netReward;
}
```

`getMyPlumeRewards()` is `rewardPerToken() * totalSupply() / 1e18` — computed from the accumulator state, which already includes rewards loaded since the last sync. `netReward` is the *unclaimed-on-Plume* portion. These are disjoint only at the instant immediately after `_rebalance()`; in any other block they overlap or skip the in-flight delta.

Either:
- Drop the `netReward` term and rename the function to clarify it returns currently-vested rewards, or
- Compute the union explicitly: snapshot accumulator-vested rewards as `getMyPlumeRewards()`, add only the *un-loaded* slice (anything in `getClaimableReward` that hasn't yet flowed through `loadRewards`).

---

### I-4 — Informational — `_unstake` validator order is registry order

[src/stPlumeMinter.sol:483-510](src/stPlumeMinter.sol#L483-L510). The unstake-loop drains validators in their position in `validators[]`. Deterministic but suboptimal:

- A slash on the first-in-array validator amplifies loss because that slot accumulates the most exposure under steady-state unstake pressure.
- No round-robin or concentration-aware ordering means the protocol's slash-event distribution is structurally biased.

Consider sorting by lowest concentration risk, lowest queued-withdrawal pressure, or storing a rotating cursor. This is a defense-in-depth recommendation against single-validator exposure; the primary mitigation remains `maxValidatorPercentage` (per-validator concentration cap) which is already in place.

---

### I-5 — Informational — `_submit` mint-then-rebalance ordering invariant

`_submit` ([stPlumeMinter.sol:565-571](src/stPlumeMinter.sol#L565-L571)) calls `_rebalance()` *before* `super._submit(recipient)`. The `super._submit` path mints frxETH, which triggers `_beforeTokenTransfer` → `handleTokenTransfer(recipient)`, pegging the new holder's `userRewardPerTokenPaid` to the **post-rebalance** `rewardPerTokenStored`. This is correct: the new holder does not retroactively claim rewards loaded by the rebalance they themselves triggered.

Documented as an invariant note: any future deposit path that mints **before** rebalancing will dilute existing holders by one transaction's worth of rewards. Preserve "rebalance first, mint second."

---

### I-6 — Informational — `removeMinter` leaves zero-address holes

[src/ERC20/ERC20PermitPermissionedMint.sol:84-89](src/ERC20/ERC20PermitPermissionedMint.sol#L84-L89). Use swap-and-pop to keep `minters_array` compact. Off-chain consumers iterating must currently filter `address(0)`. Cosmetic; mapping-based access control (`minters[address]`) is not affected.

---

## 5. Storage Layout — Verification of Round-2 Diff

The round-2 change to `stPlumeMinter` is:

```diff
-    uint256[50] private __gap;
+    uint256 public slashedAmount;
+    uint256[49] private __gap;
```

This is the textbook-correct upgrade pattern: insert the new state variable immediately before the `__gap`, reduce `__gap` by exactly the number of slots consumed.

Inheritance chain (verified from git: `0188199 add upgradeability to stplumeminter (V1): WIP`, gaps standardized in `651b92b`):

```
stPlumeMinter
  → AccessControlUpgradeable (Context, ERC165, AccessControl — included since first upgradeable deployment)
  → frxETHMinter
      → OperatorRegistry → OwnedUpgradeable → Initializable
      → ReentrancyGuardUpgradeable
```

`AccessControlUpgradeable` was **not** newly added in this round — it has been the leftmost parent since `0188199`. Therefore no slot reshuffle occurs from the inheritance side; the only delta is the +1 storage slot for `slashedAmount`, absorbed by the `stPlumeMinter` gap.

**Parent gaps do not need to be reduced.** Each contract's `__gap` is reserved exclusively for that contract's future state additions:
- `OwnedUpgradeable.__gap[10]` — only consumed if state is added to `OwnedUpgradeable`.
- `OperatorRegistry.__gap[10]` — only consumed if state is added to `OperatorRegistry`.
- `frxETHMinter.__gap[10]` — only consumed if state is added to `frxETHMinter`.

This round adds state only to `stPlumeMinter`, so the `stPlumeMinter` gap is the only one to shrink. The proposed upgrade is layout-safe.

For continued safety on future upgrades, consider adopting the OpenZeppelin storage-layout-comparison pattern in CI:

```bash
forge inspect stPlumeMinter storageLayout > new-layout.json
diff <(jq -S . old-layout.json) <(jq -S . new-layout.json)
```

against the previously deployed implementation's layout.

---

## 6. Recommended Remediation Priority

1. **M-1** — `try / catch` the `_beforeTokenTransfer` external calls and add a runbook for `HANDLER_ROLE` rotation. This is the only finding with non-trivial blast radius.
2. **L-1** — event + ceiling on `setSlashedAmount`. Small change, large operational-trust dividend.
3. **L-2** — Plume-side validation in `addValidator`. Small change, removes a registry foot-gun.
4. **L-3** / **L-4** — soft-fail in the reward-deposit chain; grant `PAUSER_ROLE` in `initialize`. Both already documented in round 1.
5. **I-1 through I-6** — cleanup batch (events, comments, ordering), no urgency.

---

## 7. Methodology

- Static read of every state-mutating path in scope, including all `_submit → _rebalance → _claim → _loadRewards → receive → _depositEther` re-entrancy and revert-propagation chains.
- ERC-20, ERC-2612, ERC-4626 conformance check against the OZ inheritance and the `xERC4626` base.
- `_unstake` slash-haircut math walked against pre-burn supply, post-burn supply, and the `slashedAmount` decrement to confirm pro-rata correctness.
- Storage layout verified via git history: confirmed `AccessControlUpgradeable` predates the storage-gap commit and confirmed the round-2 diff consumes exactly one slot of `stPlumeMinter`'s own gap.
- Cross-referenced Plume slashing semantics from [manual-audit.md](manual-audit.md) §2 (treated as authoritative for Plume facts; not independently re-derived from the Plume repo).
- Did not run dynamic tests; the existing fork suite ([test/fork/](test/fork/)) should be re-run after applying any of the above remediations, with explicit cases for: `stPlumeRewards` reverting on `handleTokenTransfer` (M-1), non-zero `slashedAmount` flowing through redemption (regression for the round-1 price-feed fix), and re-adding a slashed validator (L-2).
