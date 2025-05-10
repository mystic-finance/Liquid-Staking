# To run all the fork tests
test-all :; forge test --match-path "test-new/*.t.sol" --fork-url <your_rpc_url>

# To run a specific test file
test-run-staked:; forge test --mc StPlumeMinterForkTest --fork-url https://rpc.plume.org -vvv
test-run-wrapped:; forge test --mc sfrxETHForkTest --fork-url https://rpc.plume.org -vvv
test-run-operator:; forge test --mc OperatorRegistryForkTest --fork-url https://rpc.plume.org -vvv
test-run-all:; make test-run-staked && make test-run-wrapped && make test-run-operator

test-run-specific:; forge test --mc StPlumeMinterForkTest --fork-url https://rpc.plume.org --mt test_addRole -vvv

test-run-specific2:; forge test --mc sfrxETHForkTest --fork-url https://rpc.plume.org --mt test_multipleRewardCycles -vvv

deploy-minter:; forge script script/deployMinter.s.sol:Deploy --rpc-url https://rpc.plume.org --broadcast --verify --verifier blockscout --verifier-url https://explorer.plume.org/api? --account deployer --sender 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c --gas-estimate-multiplier 150 --delay 5 -vvvv 
