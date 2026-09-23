const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
require("dotenv").config();

// =====================================================================================
//  wMyPlume vault keeper
//
//  The wMyPlume vault holds myPLUME. stPlumeRewards pays rewards to whoever HOLDS myPLUME,
//  so the vault's rewards land on the vault's own ledger entry and nobody can claim them.
//  This keeper moves that yield into the vault's share price.
//
//  HOW: the PLUME behind those rewards is ALREADY inside stPlumeMinter (net rewards are
//  restaked when they are loaded). Clearing the vault's ledger entry frees exactly that
//  much backing, and minting the same amount of myPLUME to the vault consumes exactly that
//  much. Backing stays 1:1 and NO PLUME MOVES ANYWHERE.
//
//  It runs three tasks every hour, in this order:
//
//   Task C  executeRecycle   Once the timelock delay has passed, and ONLY if the ledger was
//                            already cleared:
//                              timelock.execute( myPLUME.minter_mint(vault, owed) )
//                            The mint happens inside that one transaction, so there is no
//                            second step that can fail halfway.
//
//   Task A  syncVault        vault.syncRewards() once the vault cycle has ended, which
//                            unlocks the accumulated myPLUME into the share price over the
//                            next cycle. Runs after Task C so a fresh mint is included.
//                            NOTE the two cadences differ and that is fine: the vault cycle
//                            is 7 days while a recycle happens roughly daily, so several
//                            mints accumulate in the vault balance and one sync picks them
//                            all up (nextRewards = balanceOf - stored - lastRewardAmount).
//                            Checking hourly just means the sync happens soon after the
//                            cycle actually ends.
//
//   Task B  proposeRecycle   ONLY if nothing is pending:
//                              owed = stPlumeRewards.getUserRewards(vault)
//                              stPlumeRewards.resetUserRewardsAfterClaim(vault)
//                              timelock.schedule( myPLUME.minter_mint(vault, owed) )
//                            The "nothing is pending" guard throttles the loop: a new
//                            recycle only starts on the first tick after Task C finished
//                            the last, so roughly every 24h, set by the timelock delay.
//
//  WHY THE RESET HAPPENS AT PROPOSE TIME, NOT INSIDE THE TIMELOCK CALL:
//  timelock calldata is fixed when it is scheduled, so the mint amount must be known 24h in
//  advance. If the reset ran at execute time it would zero the 24h of accrual that built up
//  in the meantime while only minting the older, smaller amount — losing roughly half of
//  every cycle. Resetting at propose time loses nothing: the vault simply accrues from zero
//  again and that accrual is picked up by the next recycle.
//
//  PERMISSIONS
//    keeper   MINTER_ROLE on stPlumeRewards  -> resetUserRewardsAfterClaim only. That call
//                                               zeroes a reward ledger entry and does
//                                               nothing else: it moves no funds and mints
//                                               no tokens.
//    keeper   PROPOSER_ROLE + EXECUTOR_ROLE on the timelock
//    timelock on the myPLUME minters whitelist -> the unbounded minting right stays behind
//                                               the 24h delay. The keeper NEVER holds it,
//                                               and startup fails if it does.
//    multisig CANCELLER_ROLE on the timelock, so a bad proposal can be stopped in the window.
//
//  There are no in-process timers: everything is driven by the hourly tick, so a restart
//  loses nothing.
//
//  WHY THE ORDER IS RESET-THEN-SCHEDULE:
//
//   * Mint scheduled, reset never did -> would mint `amount` myPLUME while still owing
//     `amount` on the ledger, counting the same PLUME twice and leaving the protocol
//     under-backed. Resetting first makes that state UNREACHABLE: a mint can only be
//     scheduled after the reset has landed.
//
//   * Reset landed, schedule failed   -> recoverable. The amount and salt are written to
//     PENDING_FILE before anything is sent, and Task C reconciles against the chain.
//     Even unrecovered this is a fairness loss (the vault's rewards become surplus backing
//     shared by all holders), not a solvency break.
//
//  Once scheduled, the mint MUST eventually execute or the vault's rewards are lost, so the
//  record is retried every tick. Never delete PENDING_FILE while a recycle is in flight, and
//  never cancel a scheduled recycle without re-issuing the same mint.
//
//  Dry run:  DRY_RUN=true node recycleVaultRewards.js
//  It performs every read and every safety check and logs the transactions it would send,
//  without sending any of them or writing any state.
// =====================================================================================

const {
  RPC_URL,
  KEEPER_PRIVATE_KEY,
  STPLUME_REWARDS_ADDRESS,
  MYPLUME_TOKEN_ADDRESS,
  WMYPLUME_VAULT_ADDRESS,
  MIN_RECYCLE_AMOUNT = "5",   // in PLUME. Do not bother recycling less than this.
  CHECK_INTERVAL_HOURS = "1", // how often the main loop runs
  DRY_RUN = "false",          // "true" = log every transaction instead of sending it
} = process.env;

const dryRun = DRY_RUN === "true";

// If tx.wait() fails we re-check the receipt this many times before giving up, so a flaky
// RPC is never mistaken for a transaction that did not happen.
const RECEIPT_RECHECK_ATTEMPTS = 5;
const RECEIPT_RECHECK_DELAY_MS = 15000;
const checkIntervalMs = Number(CHECK_INTERVAL_HOURS) * 60 * 60 * 1000;
const PENDING_FILE = path.join(__dirname, "vault-recycle-pending.json");

// Refuse to start unless every setting is present and well formed. A wrong address here
// would mint myPLUME to the wrong place, so this is a hard stop.
function validateConfig() {
  const problems = [];

  if (!RPC_URL) problems.push("RPC_URL is missing");

  if (!KEEPER_PRIVATE_KEY) {
    problems.push("KEEPER_PRIVATE_KEY is missing");
  } else {
    try {
      new ethers.Wallet(KEEPER_PRIVATE_KEY);
    } catch {
      problems.push("KEEPER_PRIVATE_KEY is not a valid private key");
    }
  }

  const addresses = { STPLUME_REWARDS_ADDRESS, MYPLUME_TOKEN_ADDRESS, WMYPLUME_VAULT_ADDRESS };
  for (const [name, value] of Object.entries(addresses)) {
    if (!value) {
      problems.push(`${name} is missing`);
    } else if (!ethers.utils.isAddress(value)) {
      problems.push(`${name} is not a valid address: ${value}`);
    } else if (value === ethers.constants.AddressZero) {
      problems.push(`${name} is the zero address`);
    }
  }

  try {
    ethers.utils.parseEther(MIN_RECYCLE_AMOUNT);
  } catch {
    problems.push(`MIN_RECYCLE_AMOUNT is not a number: ${MIN_RECYCLE_AMOUNT}`);
  }

  const hours = Number(CHECK_INTERVAL_HOURS);
  if (!Number.isFinite(hours) || hours <= 0) {
    problems.push(`CHECK_INTERVAL_HOURS must be a positive number: ${CHECK_INTERVAL_HOURS}`);
  }

  if (problems.length > 0) {
    console.error("Cannot start. Fix the following in your .env file:");
    for (const problem of problems) console.error(`  - ${problem}`);
    process.exit(1);
  }
}

validateConfig();

// ---------------------------------------------------------------------------
//  Contracts
// ---------------------------------------------------------------------------

const tokenABI = [
  "function minter_mint(address m_address, uint256 m_amount)",
  "function minters(address) view returns (bool)",
  "function timelock_address() view returns (address)",
  "function balanceOf(address) view returns (uint256)",
];

const rewardsABI = [
  "function getUserRewards(address user) view returns (uint256)",
  "function resetUserRewardsAfterClaim(address user)",
  "function MINTER_ROLE() view returns (bytes32)",
  "function hasRole(bytes32 role, address account) view returns (bool)",
];

const vaultABI = [
  "error SyncError()",
  "function syncRewards()",
  "function rewardsCycleEnd() view returns (uint32)",
  "function pricePerShare() view returns (uint256)",
  "function asset() view returns (address)",
];

const timelockABI = [
  "function getMinDelay() view returns (uint256)",
  "function PROPOSER_ROLE() view returns (bytes32)",
  "function EXECUTOR_ROLE() view returns (bytes32)",
  "function hasRole(bytes32 role, address account) view returns (bool)",
  "function hashOperation(address target, uint256 value, bytes data, bytes32 predecessor, bytes32 salt) view returns (bytes32)",
  "function schedule(address target, uint256 value, bytes data, bytes32 predecessor, bytes32 salt, uint256 delay)",
  "function execute(address target, uint256 value, bytes data, bytes32 predecessor, bytes32 salt) payable",
  "function isOperation(bytes32 id) view returns (bool)",
  "function getTimestamp(bytes32 id) view returns (uint256)",
  "function isOperationReady(bytes32 id) view returns (bool)",
  "function isOperationDone(bytes32 id) view returns (bool)",
];

const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(KEEPER_PRIVATE_KEY, provider);

const tokenContract = new ethers.Contract(MYPLUME_TOKEN_ADDRESS, tokenABI, wallet);
const rewardsContract = new ethers.Contract(STPLUME_REWARDS_ADDRESS, rewardsABI, wallet);
const vaultContract = new ethers.Contract(WMYPLUME_VAULT_ADDRESS, vaultABI, wallet);
let timelockContract; // built in checkSetup() from myPLUME.timelock_address()

console.log(`Vault keeper started. Wallet address: ${wallet.address}`);
console.log(`stPlumeRewards: ${STPLUME_REWARDS_ADDRESS}`);
console.log(`myPLUME token:  ${MYPLUME_TOKEN_ADDRESS}`);
console.log(`wMyPlume vault: ${WMYPLUME_VAULT_ADDRESS}`);
console.log(`Minimum recycle amount: ${MIN_RECYCLE_AMOUNT} PLUME`);
console.log(`Main loop runs every ${CHECK_INTERVAL_HOURS}h`);
if (dryRun) console.log("DRY RUN: no transactions will be sent and no state will be written");

// ---------------------------------------------------------------------------
//  Helpers
// ---------------------------------------------------------------------------

const log = (level, message, data) => {
  const timestamp = new Date().toISOString();
  console.log(`${timestamp} [${level}] ${message}`);
  if (data instanceof Error) {
    // JSON.stringify(error) prints "{}" — show something useful instead.
    console.log(`  ${data.reason || data.message || data}`);
    if (data.code) console.log(`  code: ${data.code}`);
  } else if (data) {
    console.log(JSON.stringify(data, null, 2));
  }
};

const plume = (wei) => ethers.utils.formatEther(wei);
const asDate = (seconds) => new Date(seconds * 1000).toISOString();

// "3h 12m" / "45m" / "20s" — for log lines about how far away something is.
function formatDuration(seconds) {
  if (seconds < 60) return `${Math.round(seconds)}s`;
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.round((seconds % 3600) / 60);
  return hours > 0 ? `${hours}h ${minutes}m` : `${minutes}m`;
}

// Chain time, not wall-clock time. rewardsCycleEnd and the timelock compare against the
// block timestamp, and syncRewards() reverts with SyncError if we are even a second early.
async function chainNow() {
  return (await provider.getBlock("latest")).timestamp;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Look for a transaction's receipt a few times before concluding it is not there.
// Returns the receipt if the transaction succeeded, or null if it never appeared.
// Throws if it appeared and reverted.
async function pollForReceipt(description, hash) {
  for (let attempt = 1; attempt <= RECEIPT_RECHECK_ATTEMPTS; attempt++) {
    await sleep(RECEIPT_RECHECK_DELAY_MS);

    let receipt;
    try {
      receipt = await provider.getTransactionReceipt(hash);
    } catch (lookupError) {
      // The RPC is still unhappy, so we have not learned anything. Keep trying.
      log("WARN", `${description}: receipt lookup ${attempt}/${RECEIPT_RECHECK_ATTEMPTS} failed (${lookupError.message}).`);
      continue;
    }

    if (receipt && receipt.status === 1) return receipt;
    if (receipt) throw new Error(`${description} was mined but reverted. Hash: ${hash}`);

    log("INFO", `${description}: still no receipt (${attempt}/${RECEIPT_RECHECK_ATTEMPTS}).`);
  }
  return null;
}

// Send a transaction and wait for it. In dry run, only log it.
async function sendTransaction(description, sendFn) {
  if (dryRun) {
    log("DRY", `Would send: ${description}`);
    return null;
  }
  const tx = await sendFn();
  log("INFO", `${description} sent. Hash: ${tx.hash}`);

  try {
    const receipt = await tx.wait();
    log("INFO", `${description} confirmed. Block: ${receipt.blockNumber}`);
    return receipt;
  } catch (error) {
    // tx.wait() can fail on a dropped connection or RPC timeout even though the transaction
    // landed. Check for the receipt before treating this as a failure, otherwise the caller
    // would retry a transaction that already succeeded.
    log("WARN", `${description}: wait failed (${error.reason || error.message}). Re-checking the receipt.`);

    const receipt = await pollForReceipt(description, tx.hash);
    if (receipt) {
      log("INFO", `${description} did land after all. Block: ${receipt.blockNumber}`);
      return receipt;
    }

    log("ERROR", `${description}: no receipt after ${RECEIPT_RECHECK_ATTEMPTS} checks. ` +
                 `Treating it as failed, but VERIFY ${tx.hash} on the explorer before assuming it did not land.`);
    throw error;
  }
}

// ---------------------------------------------------------------------------
//  Pending recycle state
//
//  Saved to disk so a restart resumes where it left off.
//
//  `resetDone` and `scheduled` record how far a proposal got. `scheduled: true` implies
//  `resetDone: true`, because Task B only schedules after the reset has landed.
//
//  Shape: { amount: "<wei>", salt: "0x..", readyAt: <unix seconds>|null,
//           resetDone: bool, scheduled: bool }
// ---------------------------------------------------------------------------

// Returns null ONLY when there is genuinely no pending recycle. A corrupt or unreadable
// file throws, because treating it as "nothing pending" would disarm Task B's in-flight
// guard and let it propose a second recycle over an already-cleared ledger.
function readPending() {
  let raw;
  try {
    raw = fs.readFileSync(PENDING_FILE, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw new Error(`Cannot read ${PENDING_FILE}: ${error.message}`);
  }
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(`${PENDING_FILE} is corrupt (${error.message}). ` +
                    `Inspect it by hand — a recycle may be in flight.`);
  }
}

function writePending(pending) {
  if (dryRun) return;
  if (pending === null) {
    if (fs.existsSync(PENDING_FILE)) fs.unlinkSync(PENDING_FILE);
    return;
  }
  // Write to a temp file and rename, so a crash mid-write cannot leave a truncated file.
  const tempFile = `${PENDING_FILE}.tmp`;
  fs.writeFileSync(tempFile, JSON.stringify(pending, null, 2));
  fs.renameSync(tempFile, PENDING_FILE);
}

// Clear the vault's reward ledger and record that it happened. Throws if the call fails,
// leaving resetDone false so the mint stays blocked.
// Clear the vault's reward ledger and record that it happened. Throws if the call fails,
// leaving resetDone false so the mint stays blocked.
async function clearVaultLedger(amount) {
  await sendTransaction(
    `stPlumeRewards.resetUserRewardsAfterClaim(vault) for ${plume(amount)} PLUME`,
    () => rewardsContract.resetUserRewardsAfterClaim(WMYPLUME_VAULT_ADDRESS)
  );
  const pending = readPending();
  if (pending) {
    pending.resetDone = true;
    writePending(pending);
  }
}

// The timelock operation is always the same call: myPLUME.minter_mint(vault, amount).
function mintOperation(amount, salt) {
  return {
    target: MYPLUME_TOKEN_ADDRESS,
    value: 0,
    data: tokenContract.interface.encodeFunctionData("minter_mint", [WMYPLUME_VAULT_ADDRESS, amount]),
    predecessor: ethers.constants.HashZero,
    salt,
  };
}

// ---------------------------------------------------------------------------
//  Task C: execute a scheduled mint once its delay has passed
// ---------------------------------------------------------------------------

async function executeRecycle() {
  try {
    const pending = readPending();
    if (!pending) {
      log("INFO", "Task C: no pending recycle.");
      return;
    }

    const amount = ethers.BigNumber.from(pending.amount);
    const op = mintOperation(amount, pending.salt);
    const id = await timelockContract.hashOperation(op.target, op.value, op.data, op.predecessor, op.salt);

    // The record may have been written before the schedule transaction was confirmed.
    // Ask the chain which it was.
    if (pending.scheduled !== true) {
      if (await timelockContract.isOperation(id)) {
        pending.scheduled = true;
        pending.readyAt = Number(await timelockContract.getTimestamp(id));
        writePending(pending);
        log("INFO", `Task C: the schedule for ${plume(amount)} PLUME did land. Ready at ${asDate(pending.readyAt)}.`);
      } else {
        log("INFO", `Task C: the schedule for ${plume(amount)} PLUME never landed. Clearing the record so Task B can propose again.`);
        writePending(null);
        return;
      }
    }

    if (await timelockContract.isOperationDone(id)) {
      // The mint is part of that same transaction, so "done" means the vault has the myPLUME.
      log("INFO", `Task C: recycle of ${plume(amount)} PLUME was already executed. Clearing the record.`);
      writePending(null);
      return;
    }

    if (!(await timelockContract.isOperation(id))) {
      // Scheduled earlier but no longer known to the timelock, so it was cancelled. The
      // vault's ledger is already reset, so this amount will never reach the vault unless
      // governance schedules the same mint again. Keep the record and keep shouting.
      log("ERROR", `Task C: the scheduled recycle of ${plume(amount)} PLUME was CANCELLED on the timelock. ` +
                   `The vault's ledger was already cleared, so governance must schedule ` +
                   `myPLUME.minter_mint(vault, ${amount.toString()}) again or those rewards are lost.`);
      return;
    }

    if (!(await timelockContract.isOperationReady(id))) {
      const away = Math.max(pending.readyAt - (await chainNow()), 0);
      log("INFO", `Task C: recycle of ${plume(amount)} PLUME is ready in ${formatDuration(away)} (${asDate(pending.readyAt)}).`);
      return;
    }

    // Belt and braces. Task B only schedules after the reset has landed, so this should
    // always be true; refuse to mint if it somehow is not.
    if (!pending.resetDone) {
      log("ERROR", "Task C: a mint is scheduled but the ledger was never cleared. NOT executing. " +
                   "Have the multisig cancel the scheduled operation.");
      return;
    }

    await sendTransaction(
      `timelock.execute(myPLUME.minter_mint(vault, ${plume(amount)} PLUME))`,
      () => timelockContract.execute(op.target, op.value, op.data, op.predecessor, op.salt)
    );

    writePending(null);
    log("INFO", `Task C: recycled ${plume(amount)} PLUME into the vault.`);
  } catch (error) {
    log("ERROR", "Task C failed. The pending record is kept and will be retried next tick.", error);
  }
}

// ---------------------------------------------------------------------------
//  Task A: unlock whatever the vault holds
// ---------------------------------------------------------------------------

async function syncVault() {
  try {
    // rewardsCycleEnd is uint32, which ethers decodes as a plain JS number (not a BigNumber).
    const cycleEnd = Number(await vaultContract.rewardsCycleEnd());
    const now = await chainNow();

    if (now < cycleEnd) {
      log("INFO", `Task A: vault cycle ends at ${asDate(cycleEnd)} (in ${formatDuration(cycleEnd - now)}). No sync needed yet.`);
      return;
    }

    await sendTransaction("vault.syncRewards()", () => vaultContract.syncRewards());
    log("INFO", `Task A: vault price per share is now ${plume(await vaultContract.pricePerShare())}`);
  } catch (error) {
    // A user deposit or withdrawal can inline syncRewards() (sfrxETH's andSync modifier) in
    // between our cycleEnd check and this transaction, in which case it reverts with
    // SyncError. Nothing is lost: next tick sees the new cycleEnd and skips.
    log("ERROR", "Task A failed.", error);
  }
}

// ---------------------------------------------------------------------------
//  Task B: schedule the mint and clear the vault's ledger
// ---------------------------------------------------------------------------

async function proposeRecycle() {
  try {
    // This is also what throttles the loop: while a recycle is in flight we never propose
    // another, so a new one only starts on the first tick after Task C finished the last.
    if (readPending()) {
      log("INFO", "Task B: a recycle is already in flight. Not proposing another.");
      return;
    }

    const owed = await rewardsContract.getUserRewards(WMYPLUME_VAULT_ADDRESS);
    const threshold = ethers.utils.parseEther(MIN_RECYCLE_AMOUNT);

    log("INFO", `Task B: vault has earned ${plume(owed)} PLUME. Threshold is ${plume(threshold)} PLUME.`);
    if (owed.lt(threshold)) {
      log("INFO", "Task B: below threshold. Nothing to recycle yet.");
      return;
    }

    const salt = ethers.utils.keccak256(ethers.utils.toUtf8Bytes(`wMyPlume-recycle-${Date.now()}`));
    const op = mintOperation(owed, salt);
    const delay = Number(await timelockContract.getMinDelay());

    // Record the amount and salt BEFORE sending anything, so nothing is lost if a
    // transaction lands but we do not see the receipt.
    writePending({ amount: owed.toString(), salt, readyAt: null, resetDone: false, scheduled: false });

    // Clear the ledger FIRST, then schedule. A mint can then only ever be scheduled against
    // an already cleared ledger, which makes the under-backed state unreachable instead of
    // something an interlock has to catch.
    await clearVaultLedger(owed);

    await sendTransaction(
      `timelock.schedule(myPLUME.minter_mint(vault, ${plume(owed)} PLUME))`,
      () => timelockContract.schedule(op.target, op.value, op.data, op.predecessor, op.salt, delay)
    );

    const readyAt = (await chainNow()) + delay;
    writePending({ amount: owed.toString(), salt, readyAt, resetDone: true, scheduled: true });

    log("INFO", `Task B: mint can be executed after ${asDate(readyAt)}. Task C picks it up on the next tick after that.`);
  } catch (error) {
    log("ERROR", "Task B failed.", error);
  }
}

// ---------------------------------------------------------------------------
//  Startup checks
// ---------------------------------------------------------------------------

// Fail with a readable message rather than a raw ethers revert blob.
async function requireContract(address, name) {
  const code = await provider.getCode(address);
  if (code === "0x") throw new Error(`${name} (${address}) is not a contract on this network`);
}

async function checkSetup() {
  const network = await provider.getNetwork();
  log("INFO", `Connected to chain id ${network.chainId}`);

  await requireContract(STPLUME_REWARDS_ADDRESS, "STPLUME_REWARDS_ADDRESS");
  await requireContract(MYPLUME_TOKEN_ADDRESS, "MYPLUME_TOKEN_ADDRESS");
  await requireContract(WMYPLUME_VAULT_ADDRESS, "WMYPLUME_VAULT_ADDRESS");

  let vaultAsset;
  try {
    vaultAsset = await vaultContract.asset();
  } catch {
    throw new Error(`WMYPLUME_VAULT_ADDRESS (${WMYPLUME_VAULT_ADDRESS}) does not look like an ERC-4626 vault: asset() failed`);
  }
  if (vaultAsset.toLowerCase() !== MYPLUME_TOKEN_ADDRESS.toLowerCase()) {
    throw new Error(`vault.asset() is ${vaultAsset} but MYPLUME_TOKEN_ADDRESS is ${MYPLUME_TOKEN_ADDRESS}`);
  }

  const minterRole = await rewardsContract.MINTER_ROLE();
  if (!(await rewardsContract.hasRole(minterRole, wallet.address))) {
    throw new Error("Keeper does not have MINTER_ROLE on stPlumeRewards (needed for resetUserRewardsAfterClaim)");
  }

  const timelockAddress = await tokenContract.timelock_address();
  await requireContract(timelockAddress, "myPLUME.timelock_address()");
  timelockContract = new ethers.Contract(timelockAddress, timelockABI, wallet);
  const delay = Number(await timelockContract.getMinDelay());
  log("INFO", `Timelock: ${timelockAddress} (delay ${formatDuration(delay)})`);

  // The unbounded minting right must sit with the timelock, never with this wallet.
  if (!(await tokenContract.minters(timelockAddress))) {
    throw new Error(`The timelock (${timelockAddress}) is not on the myPLUME minters whitelist. ` +
                    `Governance must call myPLUME.addMinter(${timelockAddress}) first.`);
  }
  if (await tokenContract.minters(wallet.address)) {
    throw new Error("The keeper wallet is on the myPLUME minters whitelist. Remove it: " +
                    "the minting right must stay behind the timelock.");
  }

  const proposerRole = await timelockContract.PROPOSER_ROLE();
  const executorRole = await timelockContract.EXECUTOR_ROLE();
  if (!(await timelockContract.hasRole(proposerRole, wallet.address))) {
    throw new Error("Keeper does not have PROPOSER_ROLE on the timelock");
  }
  if (!(await timelockContract.hasRole(executorRole, wallet.address))) {
    throw new Error("Keeper does not have EXECUTOR_ROLE on the timelock");
  }

  readPending(); // throws now, rather than mid-tick, if the pending file is unreadable

  log("INFO", `Keeper balance: ${plume(await provider.getBalance(wallet.address))} PLUME (gas only — this keeper never spends PLUME)`);
  log("INFO", "All startup checks passed.");
}

// ---------------------------------------------------------------------------
//  Main loop
// ---------------------------------------------------------------------------

// Guards against two ticks running at once. tx.wait() has no timeout, so a stuck
// transaction can hold a tick open past the next interval; without this, two ticks could
// both pass Task B's in-flight check and propose twice.
let tickInProgress = false;

async function runAllTasks() {
  if (tickInProgress) {
    log("WARN", "Previous tick is still running. Skipping this one.");
    return;
  }
  tickInProgress = true;
  try {
    // Order matters. Task C mints myPLUME into the vault, and Task A's syncRewards() only
    // measures the vault balance at the instant it runs and can only run once per cycle.
    // Syncing first would leave that myPLUME unrecognised until the next cycle end.
    await executeRecycle(); // Task C
    await syncVault();      // Task A
    await proposeRecycle(); // Task B
  } finally {
    tickInProgress = false;
  }
}

async function main() {
  log("INFO", "--- Starting Vault Keeper Main Loop ---");
  await checkSetup();
  await runAllTasks();

  if (dryRun) {
    log("INFO", "Dry run complete. Exiting without scheduling the main loop.");
    return;
  }

  setInterval(() => {
    log("INFO", "--- Periodic check ---");
    runAllTasks();
  }, checkIntervalMs);
}

main().catch((error) => {
  log("ERROR", `Startup failed: ${error.message || error}`);
  process.exit(1);
});

// Graceful shutdown
process.on("SIGINT", () => {
  log("INFO", "Shutting down vault keeper...");
  process.exit(0);
});
