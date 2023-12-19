# DOGAMÍ EVM Smart Contracts
This is the offical repository for the DOGAMÍ projects smart contracts.

## Project Structure

These contracts have been developed using the Foundry Framework https://book.getfoundry.sh/
We recommend that you install foundry locally before proceeding to the testing / deployment: https://book.getfoundry.sh/getting-started/installation

## Initiliaztion

``forge build`` Compile the contracts, the command will try to detect the latest version that can compile the project by looking at the version requirements of all the contracts and dependencies.

## Tests

Tests are found in the ``./test/`` folder.

``forge coverage`` Displays which parts of the code are covered by tests.

``forge test`` Run the test for all the contracts

## Contracts

Contracts are found in ``./src/`` folder

## Deployment

The ``script`` folder hold all the deployment script for the contract. For example if we want to deploy the StackingFlex contract:

``cp .env-example .env`` Copy the example .env file and fill it the correct values.

``source .env`` To load the variables in the .env file

``forge script script/StackingFlex.s.sol:DeployDev --rpc-url https://polygon-mumbai.g.alchemy.com/v2/xxx `` Will run a deployment simulation for the StackingFlex contract.

If the simulation is correct:

``forge script script/StackingFlex.s.sol:DeployDev --rpc-url https://polygon-mumbai.g.alchemy.com/v2/xxx --broadcast`` To deploy it to referred RPC.
