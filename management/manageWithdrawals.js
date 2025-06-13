const { ethers } = require('ethers');
require('dotenv').config();
const stPlumeMinterABI = require('./stPlumeMinterABI');

// --- Configuration ---
const { RPC_URL, KEEPER_PRIVATE_KEY, STPLUME_MINTER_ADDRESS } = process.env;

if (!RPC_URL || !KEEPER_PRIVATE_KEY || !STPLUME_MINTER_ADDRESS) {
    console.error("Missing required environment variables. Please check your .env file.");
    process.exit(1);
}

// --- Ethers Setup ---
const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(KEEPER_PRIVATE_KEY, provider);
const minterContract = new ethers.Contract(STPLUME_MINTER_ADDRESS, stPlumeMinterABI, wallet);

console.log(`Keeper script started. Wallet address: ${wallet.address}`);
console.log(`Monitoring stPlumeMinter at: ${STPLUME_MINTER_ADDRESS}`);

// --- State to prevent scheduling duplicate tasks ---
const scheduledTasks = {
    syncRewards: null, // Stores the timestamp for the next scheduled sync
    processUnstake: new Map() // Stores timestamps for each validator's unstake processing
};

/**
 * A simple logging wrapper
 * @param {string} level - e.g., 'INFO', 'WARN', 'ERROR'
 * @param {string} message
 * @param {any} [data] - Optional data to log
 */
const log = (level, message, data) => {
    const timestamp = new Date().toISOString();
    console.log(`${timestamp} [${level}] ${message}`);
    if (data) {
        console.log(JSON.stringify(data, null, 2));
    }
};

/**
 * Fetches all validator IDs from the contract.
 * This function iterates through the public `validators` array.
 * @returns {Promise<number[]>} A list of validator IDs.
 */
async function getAllValidatorIds() {
    try {
        const validatorIds = [];
        const numValidators = await minterContract.numValidators();
        for (let i = 0; i < numValidators; i++) {
            const validator = await minterContract.validators(i);
            validatorIds.push(validator.validatorId);
        }
        return validatorIds;
    } catch (error) {
        log('ERROR', 'Failed to get all validator IDs.', error);
        return [];
    }
}

// --- Main Keeper Logic ---

/**
 * Checks the rewards cycle and schedules a call to syncRewards if needed.
 */
async function checkAndScheduleRewardSync() {
    try {
        const rewardsCycleEnd = await minterContract.rewardsCycleEnd(); // Returns a BigNumber (timestamp in seconds)
        const rewardsCycleEndTs = rewardsCycleEnd.toNumber() * 1000; // Convert to milliseconds

        if (scheduledTasks.syncRewards === rewardsCycleEndTs) {
            // Task for this exact timestamp is already scheduled
            return;
        }

        const now = Date.now();
        const delay = rewardsCycleEndTs - now;

        if (delay <= 0) {
            log('INFO', 'Reward cycle has already ended. Triggering syncRewards now.');
            // Clear any old scheduled task
            scheduledTasks.syncRewards = null;
            await minterContract.syncRewards().then(tx => {
                log('INFO', `syncRewards transaction sent. Hash: ${tx.hash}`);
                return tx.wait();
            }).then(receipt => {
                log('INFO', `syncRewards transaction confirmed. Block: ${receipt.blockNumber}`);
            });
        } else {
            log('INFO', `Next reward cycle ends at ${new Date(rewardsCycleEndTs).toLocaleString()}. Scheduling syncRewards.`);
            scheduledTasks.syncRewards = rewardsCycleEndTs;

            setTimeout(async () => {
                try {
                    log('INFO', 'Executing scheduled syncRewards call.');
                    const tx = await minterContract.syncRewards();
                    log('INFO', `syncRewards transaction sent. Hash: ${tx.hash}`);
                    const receipt = await tx.wait();
                    log('INFO', `syncRewards transaction confirmed. Block: ${receipt.blockNumber}`);
                } catch (e) {
                    log('ERROR', 'Scheduled syncRewards call failed.', e);
                }
            }, delay);
        }
    } catch (error) {
        log('ERROR', 'Error in checkAndScheduleRewardSync:', error);
    }
}

/**
 * Checks all validators and schedules calls to processBatchUnstake.
 */
async function checkAndScheduleBatchUnstake() {
    const validatorIds = await getAllValidatorIds();
    if (validatorIds.length === 0) {
        log('WARN', 'No validators found to monitor for batch unstaking.');
        return;
    }

    log('INFO', `Checking batch unstake times for ${validatorIds.length} validators...`);

    for (const validatorId of validatorIds) {
        try {
            const nextBatchTime = await minterContract.nextBatchUnstakeTimePerValidator(validatorId);
            const nextBatchTimeTs = nextBatchTime.toNumber() * 1000; // Convert to milliseconds

            // if (scheduledTasks.processUnstake.get(validatorId) === nextBatchTimeTs) {
            //     continue; // Already scheduled for this time
            // }

            const now = Date.now();
            const delay = nextBatchTimeTs - now;

            if (delay <= 0) {
                // The time is in the past, but we should still check if a batch needs processing.
                // The contract logic handles whether to unstake, so it's safe to call.
                log('INFO', `Batch unstake time for validator ${validatorId} is in the past. Triggering processBatchUnstake now.`);
                // Clear any old scheduled task
                scheduledTasks.processUnstake.delete(validatorId);
                await minterContract.processBatchUnstake().then(tx => {
                    log('INFO', `processBatchUnstake transaction sent. Hash: ${tx.hash}`);
                    return tx.wait();
                }).then(receipt => {
                    log('INFO', `processBatchUnstake transaction confirmed. Block: ${receipt.blockNumber}`);
                });
                
                const nextBatchTime = await minterContract.nextBatchUnstakeTimePerValidator(validatorId);
                const nextBatchTimeTs = nextBatchTime.toNumber() * 1000; // Convert to milliseconds
                scheduledTasks.processUnstake.set(validatorId, nextBatchTimeTs);
            } else {
                log('INFO', `Next batch unstake for validator ${validatorId} is at ${new Date(nextBatchTimeTs).toLocaleString()}. Scheduling call.`);
                scheduledTasks.processUnstake.set(validatorId, nextBatchTimeTs);

                setTimeout(async () => {
                    try {
                        log('INFO', `Executing scheduled processBatchUnstake for validator ${validatorId}.`);
                        const tx = await minterContract.processBatchUnstake();
                        log('INFO', `processBatchUnstake transaction sent. Hash: ${tx.hash}`);
                        const receipt = await tx.wait();
                        log('INFO', `processBatchUnstake transaction confirmed. Block: ${receipt.blockNumber}`);
                    } catch (e) {
                        log('ERROR', `Scheduled processBatchUnstake call for validator ${validatorId} failed.`, e);
                    }
                }, delay);
            }
        } catch (error) {
            log('ERROR', `Failed to process validator ${validatorId}.`, error);
        }
    }
}

// --- Main Loop ---

async function main() {
    log('INFO', '--- Starting Keeper Main Loop ---');
    
    // Run checks immediately on start
    await checkAndScheduleRewardSync();
    await checkAndScheduleBatchUnstake();

    // Periodically re-check for new state (e.g., every 15 minutes)
    const checkInterval = 15 * 60 * 1000;
    setInterval(() => {
        log('INFO', '--- Periodic check for new tasks ---');
        checkAndScheduleRewardSync();
        checkAndScheduleBatchUnstake();
    }, checkInterval);
}

main().catch(error => {
    log('ERROR', 'An unhandled error occurred in the main loop.', error);
    process.exit(1);
});

// Graceful shutdown
process.on('SIGINT', () => {
    log('INFO', 'Shutting down keeper script...');
    process.exit(0);
});
