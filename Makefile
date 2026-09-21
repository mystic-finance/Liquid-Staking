# To run all the fork tests
test-all :; forge test --match-path "test-new/*.t.sol" --fork-url <your_rpc_url>

# To run a specific test file
test-run-staked:; forge test --mc StPlumeMinterForkTestMain --fork-url https://rpc.plume.org -vvv
test-run-staked-alt:; forge test --mc StPlumeMinterForkTestLegacy --fork-url https://rpc.plume.org -vvv
test-run-upgrade:; forge test --mc UpgradeTests --fork-url https://rpc.plume.org -vvv
test-run-wrapped:; forge test --mc sfrxETHForkTest --fork-url https://rpc.plume.org -vvv
test-run-operator:; forge test --mc OperatorRegistryForkTest --fork-url https://rpc.plume.org -vvv
test-run-myPlumeFeed:; forge test --mc MyPlumeFeedForkTest --fork-url https://rpc.plume.org -vvvvv
test-run-all:; make test-run-upgrade && make test-run-operator &&  make test-run-staked && make test-run-myPlumeFeed

test-run-specific:; forge test --mc StPlumeMinterForkTestMain --fork-url https://rpc.plume.org --mt test_integration_flow4_1 -vvvvv

test-run-specific2:; forge test --mc UpgradeTests --fork-url https://rpc.plume.org --mt test_statePreservationDuringUpgrade -vvvvv

deploy-minter:; forge script script/deployMinter.s.sol:Deploy --rpc-url https://rpc.plume.org --broadcast --verify --verifier blockscout --verifier-url https://explorer.plume.org/api? --account deployer --sender 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c --delay 5 -vvvv 

upgrade-minter:; forge script script/upgradeMinter.s.sol:Deploy --rpc-url https://rpc.plume.org --broadcast --verify --verifier blockscout --verifier-url https://explorer.plume.org/api? --account deployer --sender 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c --delay 5 -vvvv 

deploy-splitter:; forge script script/deployFeeSplitter.s.sol:Deploy --rpc-url https://rpc.plume.org --broadcast --verify --verifier blockscout --verifier-url https://explorer.plume.org/api? --account deployer --sender 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c --delay 5 -vvvv 

deploy-minter-continue:; forge script script/deployMinter.s.sol:Deploy --rpc-url https://rpc.plume.org --broadcast --verify --verifier blockscout --verifier-url https://explorer.plume.org/api? --account deployer --sender 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c --delay 5 -vvvv --resume 

deploy-periphery:; forge script script/deployPeriphery.s.sol:Deploy --rpc-url https://rpc.plume.org --broadcast --verify --verifier blockscout --verifier-url https://explorer.plume.org/api? --account deployer --sender 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c --delay 5 -vvvv 
