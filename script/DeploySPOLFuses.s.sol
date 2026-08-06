// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {SPOLUnstakeFuse} from "../contracts/fuses/chains/ethereum/spol/SPOLUnstakeFuse.sol";
import {SPOLBalanceFuse} from "../contracts/fuses/chains/ethereum/spol/SPOLBalanceFuse.sol";
import {ReadSPOLUnstakeExecutor} from "../contracts/readers/ReadSPOLUnstakeExecutor.sol";

/// @title Deploy SPOLUnstakeFuse, SPOLBalanceFuse and ReadSPOLUnstakeExecutor
/// @notice Deploys the fuse contracts and the executor reader without configuring governance.
///
///   The per-vault SPOLUnstakeExecutor is NOT deployed here - it is born lazily on the vault's first
///   enter and recorded in vault-local ERC-7201 storage. Resolve it off-chain via
///   ReadSPOLUnstakeExecutor.getSPOLUnstakeExecutorAddress(vault) (e.g. for keeper
///   sPOLController.withdrawPOL(executor) calls).
///
///   Governance wiring (per vault, FUSE_MANAGER):
///     - addFuses([SPOLUnstakeFuse])
///     - addBalanceFuse(marketId, SPOLBalanceFuse)
///     - grantMarketSubstrates(marketId, [addressToBytes32(0xEaadA411F2600570796c341552b9869DA708a28B)])
///     - dependency graph: marketId -> ERC20_VAULT_BALANCE (append, updateDependencyBalanceGraphs replaces the array)
///     - prerequisites: POL price source in PriceOracleMiddleware; sPOL + POL granted on the ERC20 balance market
///
///   MIGRATION from the v2 fuses (0xF7379E4D... unstake, 0x69A206f6... balance): v2 nonces are keyed to
///   the VAULT, and the v3 balance fuse only counts the EXECUTOR - swapping the balance fuse while vault
///   nonces are open drops totalAssets instantly. Before swapping: wait out maturity, drain via the
///   permissionless withdrawPOL(vault), run updateMarketsBalances([marketId, ERC20_VAULT_BALANCE]), and
///   verify getUserOpenNonces(vault) is empty.
///
///   Required env vars:
///     MARKET_ID             - Market ID for both fuses (424243; registered in IporFusionMarkets upstream after the fact)
///     ETHEREUM_PROVIDER_URL - RPC endpoint
///     PRIVATE_KEY           - Deployer private key (real broadcast only)
///
///   Real broadcast (deploy + verify):
///     source .env && MARKET_ID=424243 forge script script/DeploySPOLFuses.s.sol \
///       --rpc-url $ETHEREUM_PROVIDER_URL --broadcast --verify \
///       --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
///
///   Fork test:
///     source .env && MARKET_ID=424243 forge script script/DeploySPOLFuses.s.sol \
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
///
///     source .env && forge verify-contract <ReadSPOLUnstakeExecutor_address> \
///       contracts/readers/ReadSPOLUnstakeExecutor.sol:ReadSPOLUnstakeExecutor \
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
        ReadSPOLUnstakeExecutor executorReader = new ReadSPOLUnstakeExecutor();

        vm.stopBroadcast();

        console.log("SPOLUnstakeFuse:        ", address(unstakeFuse));
        console.log("SPOLBalanceFuse:        ", address(balanceFuse));
        console.log("ReadSPOLUnstakeExecutor:", address(executorReader));
        console.log("Market ID:              ", marketId);
    }
}
