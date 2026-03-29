// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {LitePSMSupplyFuse} from "../contracts/fuses/chains/ethereum/litepsm/LitePSMSupplyFuse.sol";
import {ZeroBalanceFuse} from "../contracts/fuses/ZeroBalanceFuse.sol";
import {IPlasmaVaultGovernance} from "../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {InstantWithdrawalFusesParamsStruct} from "../contracts/libraries/PlasmaVaultLib.sol";

interface IFuseMarketId {
    function MARKET_ID() external view returns (uint256);
}

/// @title Deploy & configure LitePSMSupplyFuse on a PlasmaVault
/// @notice Reads configuration from .env — see .env.deploy.example
///
///   Required env vars:
///     VAULT_ADDRESS           - PlasmaVault proxy address
///     ETHEREUM_PROVIDER_URL   - Mainnet RPC
///     MARKET_ID               - Market ID for the new fuse
///     SUSDS_MARKET_ID         - Existing sUSDS market ID (for dependency graph)
///     PRIVATE_KEY             - Deployer/admin private key (real broadcast only)
///
///   Real broadcast:
///     source .env && forge script script/DeployLitePSMSupplyFuse.s.sol \
///       --rpc-url $ETHEREUM_PROVIDER_URL --broadcast -vvvv
///
///   Fork test with impersonation (no private key needed):
///     source .env && forge script script/DeployLitePSMSupplyFuse.s.sol \
///       --fork-url $ETHEREUM_PROVIDER_URL --sender <admin_address> --unlocked -vvvv
contract DeployLitePSMSupplyFuse is Script {
    function run() external {
        address vault = vm.envAddress("VAULT_ADDRESS");
        uint256 marketId = vm.envUint("MARKET_ID");
        uint256 susdsMarketId = vm.envUint("SUSDS_MARKET_ID");

        IPlasmaVaultGovernance governance = IPlasmaVaultGovernance(vault);

        // Use PRIVATE_KEY if set, otherwise rely on --sender --unlocked
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast();
        }

        // 1. Deploy LitePSMSupplyFuse
        LitePSMSupplyFuse litePsmFuse = new LitePSMSupplyFuse(marketId);
        console.log("LitePSMSupplyFuse deployed at:", address(litePsmFuse));

        // 2. Deploy ZeroBalanceFuse (same market ID)
        ZeroBalanceFuse zeroBalanceFuse = new ZeroBalanceFuse(marketId);
        console.log("ZeroBalanceFuse deployed at:", address(zeroBalanceFuse));

        // 3. Register supply fuse
        address[] memory fuses = new address[](1);
        fuses[0] = address(litePsmFuse);
        governance.addFuses(fuses);
        console.log("Supply fuse registered");

        // 4. Register balance fuse
        governance.addBalanceFuse(marketId, address(zeroBalanceFuse));
        console.log("Balance fuse registered for market:", marketId);

        // 5. Configure dependency balance graph: litePSM market -> sUSDS market
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = marketId;

        uint256[][] memory dependencies = new uint256[][](1);
        dependencies[0] = new uint256[](1);
        dependencies[0][0] = susdsMarketId;

        governance.updateDependencyBalanceGraphs(marketIds, dependencies);
        console.log("Dependency graph: market", marketId, "->", susdsMarketId);

        // 6. Configure instant withdrawal fuse (allowedTout = 0)
        InstantWithdrawalFusesParamsStruct[] memory iwFuses = new InstantWithdrawalFusesParamsStruct[](1);
        iwFuses[0].fuse = address(litePsmFuse);
        iwFuses[0].params = new bytes32[](2);
        iwFuses[0].params[0] = bytes32(0); // amount placeholder (overwritten at runtime)
        iwFuses[0].params[1] = bytes32(0); // allowedTout = 0
        governance.configureInstantWithdrawalFuses(iwFuses);
        console.log("Instant withdrawal fuse configured");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment complete ===");
        console.log("LitePSMSupplyFuse:", address(litePsmFuse));
        console.log("ZeroBalanceFuse:  ", address(zeroBalanceFuse));
        console.log("Market ID:        ", marketId);
        console.log("sUSDS Market ID:  ", susdsMarketId);
    }
}
