// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {MorphoAuthorizationFuse} from "../contracts/fuses/morpho/MorphoAuthorizationFuse.sol";
import {ZeroBalanceFuse} from "../contracts/fuses/ZeroBalanceFuse.sol";

/// @title Deploy MorphoAuthorizationFuse and its ZeroBalanceFuse
/// @notice Deploys the fuse contracts without configuring governance.
///
///   The fuse lets a Plasma Vault grant (enter) / revoke (exit) Morpho Blue authorization for a
///   delegate account via MORPHO.setAuthorization. Authorization is global across all Morpho
///   markets: an authorized account may withdraw, borrow and withdrawCollateral with the vault as
///   onBehalf — i.e. move the vault's supply and debt. Substrates on MARKET_ID are the delegate
///   account addresses allowed to be authorized.
///
///   Governance wiring (per vault, FUSE_MANAGER):
///     - addFuses([MorphoAuthorizationFuse])
///     - addBalanceFuse(marketId, ZeroBalanceFuse)
///     - grantMarketSubstrates(marketId, [addressToBytes32(delegateAccount)])
///
///   Required env vars:
///     MARKET_ID             - Dedicated market ID for the authorization substrates (do NOT reuse
///                             the Morpho market-id market; its substrates are bytes32 market ids)
///     MORPHO_ADDRESS        - Morpho Blue address (0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb on mainnet)
///     ETHEREUM_PROVIDER_URL - RPC endpoint
///     PRIVATE_KEY           - Deployer private key (real broadcast only)
///
///   Real broadcast (deploy + verify):
///     source .env && MARKET_ID=<id> MORPHO_ADDRESS=0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb \
///       forge script script/DeployMorphoAuthorizationFuse.s.sol \
///       --rpc-url $ETHEREUM_PROVIDER_URL --broadcast --verify \
///       --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
///
///   Fork test:
///     source .env && MARKET_ID=<id> MORPHO_ADDRESS=0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb \
///       forge script script/DeployMorphoAuthorizationFuse.s.sol \
///       --fork-url $ETHEREUM_PROVIDER_URL --sender <deployer> --unlocked -vvvv
///
///   Verify (after broadcast):
///     source .env && forge verify-contract <MorphoAuthorizationFuse_address> \
///       contracts/fuses/morpho/MorphoAuthorizationFuse.sol:MorphoAuthorizationFuse \
///       --constructor-args $(cast abi-encode "constructor(uint256,address)" $MARKET_ID $MORPHO_ADDRESS) \
///       --etherscan-api-key $ETHERSCAN_API_KEY --rpc-url $ETHEREUM_PROVIDER_URL --watch
///
///     source .env && forge verify-contract <ZeroBalanceFuse_address> \
///       contracts/fuses/ZeroBalanceFuse.sol:ZeroBalanceFuse \
///       --constructor-args $(cast abi-encode "constructor(uint256)" $MARKET_ID) \
///       --etherscan-api-key $ETHERSCAN_API_KEY --rpc-url $ETHEREUM_PROVIDER_URL --watch
contract DeployMorphoAuthorizationFuse is Script {
    function run() external {
        uint256 marketId = vm.envUint("MARKET_ID");
        address morpho = vm.envAddress("MORPHO_ADDRESS");

        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast();
        }

        MorphoAuthorizationFuse authorizationFuse = new MorphoAuthorizationFuse(marketId, morpho);
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(marketId);

        vm.stopBroadcast();

        console.log("MorphoAuthorizationFuse:", address(authorizationFuse));
        console.log("ZeroBalanceFuse:        ", address(balanceFuse));
        console.log("Market ID:              ", marketId);
        console.log("Morpho:                 ", morpho);
    }
}
