const { ethers } = require("ethers");
require("dotenv").config();
const stPlumeMinterABI = require("./stPlumeMinterABI");
const stPlumeRewardsABI = require("./stPlumeRewardsABI");

const {
  RPC_URL,
  KEEPER_PRIVATE_KEY,
  STPLUME_MINTER_ADDRESS,
  STPLUME_REWARDS_ADDRESS,
} = process.env;

if (
  !RPC_URL ||
  !KEEPER_PRIVATE_KEY ||
  !STPLUME_MINTER_ADDRESS ||
  !STPLUME_REWARDS_ADDRESS
) {
  console.error(
    "Missing required environment variables. Please check your .env file."
  );
  process.exit(1);
}

const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(KEEPER_PRIVATE_KEY, provider);
const minterContract = new ethers.Contract(
  STPLUME_MINTER_ADDRESS,
  stPlumeMinterABI,
  wallet
);
const minterRewardsContract = new ethers.Contract(
  STPLUME_REWARDS_ADDRESS,
  stPlumeRewardsABI,
  wallet
);

console.log(`Keeper script started. Wallet address: ${wallet.address}`);
console.log(`Monitoring stPlumeMinter at: ${STPLUME_MINTER_ADDRESS}`);
console.log(`Monitoring stPlumeRewards at: ${STPLUME_REWARDS_ADDRESS}`);

const scheduledTasks = {
  syncRewards: null, // Stores the timestamp for the next scheduled sync
  processUnstake: new Map(), // Stores timestamps for each validator's unstake processing
};

const log = (level, message, data) => {
  const timestamp = new Date().toISOString();
  console.log(`${timestamp} [${level}] ${message}`);
  if (data) {
    console.log(JSON.stringify(data, null, 2));
  }
};

async function getAllValidatorIds() {
  try {
    const validatorIds = [];
    const numValidators = await minterContract.numValidators();
    console.log(`Number of validators: ${numValidators}`);
    for (let i = 0; i < numValidators; i++) {
      const validator = await minterContract.getValidator(i);
      console.log(`Validator ${i}: ${validator}`);
      validatorIds.push(validator + "");
    }
    return validatorIds;
  } catch (error) {
    log("ERROR", "Failed to get all validator IDs.", error);
    return [];
  }
}

async function checkAndScheduleRewardSync() {
  try {
    const rewardsCycleEnd = await minterRewardsContract.rewardsCycleEnd();
    const rewardsCycleEndTs = rewardsCycleEnd.toNumber() * 1000;

    if (scheduledTasks.syncRewards === rewardsCycleEndTs) {
      return;
    }

    if (rewardsCycleEnd == 0) {
      log("INFO", "Rewards cycle has not started yet.");
      return;
    }

    const now = Date.now();
    const delay = rewardsCycleEndTs - now;

    if (delay <= 0) {
      log(
        "INFO",
        "Reward cycle has already ended. Triggering syncRewards now."
      );
      scheduledTasks.syncRewards = null;
      await minterRewardsContract
        .syncRewards()
        .then((tx) => {
          log("INFO", `syncRewards transaction sent. Hash: ${tx.hash}`);
          return tx.wait();
        })
        .then((receipt) => {
          log(
            "INFO",
            `syncRewards transaction confirmed. Block: ${receipt.blockNumber}`
          );
        });
    } else {
      log(
        "INFO",
        `Next reward cycle ends at ${new Date(
          rewardsCycleEndTs
        ).toLocaleString()}. Scheduling syncRewards.`
      );
      scheduledTasks.syncRewards = rewardsCycleEndTs;

      setTimeout(async () => {
        try {
          log("INFO", "Executing scheduled syncRewards call.");
          const tx = await minterRewardsContract.syncRewards();
          log("INFO", `syncRewards transaction sent. Hash: ${tx.hash}`);
          const receipt = await tx.wait();
          log(
            "INFO",
            `syncRewards transaction confirmed. Block: ${receipt.blockNumber}`
          );
        } catch (e) {
          log("ERROR", "Scheduled syncRewards call failed.", e);
        }
      }, delay);
    }
  } catch (error) {
    log("ERROR", "Error in checkAndScheduleRewardSync:", error);
  }
}

async function checkAndScheduleBatchUnstake() {
  const validatorIds = await getAllValidatorIds();
  if (validatorIds.length === 0) {
    log("WARN", "No validators found to monitor for batch unstaking.");
    return;
  }

  log(
    "INFO",
    `Checking batch unstake times for ${validatorIds.length} validators...`
  );
  const validatorId = validatorIds[0];

  // for (const validatorId of validatorIds) {
  try {
    const nextBatchTime = await minterContract.nextBatchUnstakeTimePerValidator(
      validatorId
    );
    const nextBatchTimeTs = nextBatchTime.toNumber() * 1000;
    const now = Date.now();
    const delay = nextBatchTimeTs - now;

    if (delay <= 0) {
      // The time is in the past, but we should still check if a batch needs processing.
      // The contract logic handles whether to unstake, so it's safe to call.
      log(
        "INFO",
        `Batch unstake time for validator ${validatorId} is in the past. Triggering processBatchUnstake now.`
      );
      // Clear any old scheduled task
      scheduledTasks.processUnstake.delete(validatorId);
      await minterContract
        .processBatchUnstake()
        .then((tx) => {
          log("INFO", `processBatchUnstake transaction sent. Hash: ${tx.hash}`);
          return tx.wait();
        })
        .then((receipt) => {
          log(
            "INFO",
            `processBatchUnstake transaction confirmed. Block: ${receipt.blockNumber}`
          );
        });

      const nextBatchTime =
        await minterContract.nextBatchUnstakeTimePerValidator(validatorId);
      const nextBatchTimeTs = nextBatchTime.toNumber() * 1000; // Convert to milliseconds
      scheduledTasks.processUnstake.set(validatorId, nextBatchTimeTs);
    } else {
      log(
        "INFO",
        `Next batch unstake for validator ${validatorId} is at ${new Date(
          nextBatchTimeTs
        ).toLocaleString()}. Scheduling call.`
      );
      scheduledTasks.processUnstake.set(validatorId, nextBatchTimeTs);

      setTimeout(async () => {
        try {
          log(
            "INFO",
            `Executing scheduled processBatchUnstake for validator ${validatorId}.`
          );
          const tx = await minterContract.processBatchUnstake();
          log("INFO", `processBatchUnstake transaction sent. Hash: ${tx.hash}`);
          const receipt = await tx.wait();
          log(
            "INFO",
            `processBatchUnstake transaction confirmed. Block: ${receipt.blockNumber}`
          );
        } catch (e) {
          log(
            "ERROR",
            `Scheduled processBatchUnstake call for validator ${validatorId} failed.`,
            e
          );
        }
      }, delay);
    }
  } catch (error) {
    log("ERROR", `Failed to process validator ${validatorId}.`, error);
  }
  // }
}

async function main() {
  log("INFO", "--- Starting Keeper Main Loop ---");

  await checkAndScheduleRewardSync();
  await checkAndScheduleBatchUnstake();

  const checkInterval = 24 * 60 * 60 * 1000;
  setInterval(() => {
    log("INFO", "--- Periodic check for new tasks ---");
    checkAndScheduleRewardSync();
    checkAndScheduleBatchUnstake();
  }, checkInterval);
}

main().catch((error) => {
  log("ERROR", "An unhandled error occurred in the main loop.", error);
  process.exit(1);
});

// Graceful shutdown
process.on("SIGINT", () => {
  log("INFO", "Shutting down keeper script...");
  process.exit(0);
});
