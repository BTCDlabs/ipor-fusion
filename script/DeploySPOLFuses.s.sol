// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {SPOLUnstakeFuse} from "../contracts/fuses/chains/ethereum/spol/SPOLUnstakeFuse.sol";
import {SPOLBalanceFuse} from "../contracts/fuses/chains/ethereum/spol/SPOLBalanceFuse.sol";

/// @title Deploy SPOLUnstakeFuse and SPOLBalanceFuse
/// @notice Deploys both fuse contracts without configuring governance.
///
///   Governance wiring (per vault, FUSE_MANAGER):
///     - addFuses([SPOLUnstakeFuse])
///     - addBalanceFuse(marketId, SPOLBalanceFuse)
///     - grantMarketSubstrates(marketId, [addressToBytes32(0xEaadA411F2600570796c341552b9869DA708a28B)])
///     - dependency graph: marketId -> ERC20_VAULT_BALANCE (append, updateDependencyBalanceGraphs replaces the array)
///     - prerequisites: POL price source in PriceOracleMiddleware; sPOL + POL granted on the ERC20 balance market
///
///   Required env vars:
///     MARKET_ID             - Market ID for both fuses (300001; registered in IporFusionMarkets upstream after the fact)
///     ETHEREUM_PROVIDER_URL - RPC endpoint
///     PRIVATE_KEY           - Deployer private key (real broadcast only)
///
///   Real broadcast (deploy + verify):
///     source .env && MARKET_ID=300001 forge script script/DeploySPOLFuses.s.sol \
///       --rpc-url $ETHEREUM_PROVIDER_URL --broadcast --verify \
///       --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
///
///   Fork test:
///     source .env && MARKET_ID=300001 forge script script/DeploySPOLFuses.s.sol \
///       --fork-url $ETHEREUM_PROVIDER_URL --sender <deployer> --unlocked -vvvv
///
///   Verify (after broadcast):
///     source .env && forge verify-contract <SPOLUnstakeFuse_address> \
///       contracts/fuses/chains/ethereum/spol/SPOLUnstakeFuse.sol:SPOLUnstakeFuse \
///       --constructor-args $(cast abi-encode "constructor(uint256)" $MARKET_ID) \
///       --etherscan-api-key $ETHERSCAN_API_KEY --rpc-url $ETHEREUM_PROVIDER_URL --watch
///
///     source .env && forge verify-contract <SPOLBalanceFuse_address> \
///       contracts/fuses/chains/ethereum/spol/SPOLBalanceFuse.sol:SPOLBalanceFuse \
///       --constructor-args $(cast abi-encode "constructor(uint256)" $MARKET_ID) \
///       --etherscan-api-key $ETHERSCAN_API_KEY --rpc-url $ETHEREUM_PROVIDER_URL --watch
contract DeploySPOLFuses is Script {
    function run() external {
        uint256 marketId = vm.envUint("MARKET_ID");

        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast();
        }

        SPOLUnstakeFuse unstakeFuse = new SPOLUnstakeFuse(marketId);
        SPOLBalanceFuse balanceFuse = new SPOLBalanceFuse(marketId);

        vm.stopBroadcast();

        console.log("SPOLUnstakeFuse:", address(unstakeFuse));
        console.log("SPOLBalanceFuse:", address(balanceFuse));
        console.log("Market ID:      ", marketId);
    }
}
