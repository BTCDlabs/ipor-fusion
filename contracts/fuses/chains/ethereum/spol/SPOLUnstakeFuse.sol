// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IporMath} from "../../../../libraries/math/IporMath.sol";
import {TypeConversionLib} from "../../../../libraries/TypeConversionLib.sol";
import {PlasmaVaultConfigLib} from "../../../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../../../IFuseCommon.sol";
import {ISPOLController} from "./ext/ISPOLController.sol";
import {SPOLUnstakeExecutor} from "./SPOLUnstakeExecutor.sol";
import {SPOLUnstakeExecutorStorageLib} from "./lib/SPOLUnstakeExecutorStorageLib.sol";

/// @notice Data structure for entering the sPOL unstake fuse (sPOL -> pending POL)
struct SPOLUnstakeFuseEnterData {
    /// @dev sPOLController address; must be granted as a substrate of MARKET_ID
    address controller;
    /// @dev amount of sPOL (18 decimals) to unstake; capped at the vault's sPOL balance
    uint256 spolAmount;
    /// @dev minimum POL (18 decimals) to be queued for the unstaked sPOL; reverts if the current rate yields less
    uint256 minPolAmountOut;
    /// @dev caller-supplied timestamp echoed in the enter event for off-chain correlation; 0 = block.timestamp
    uint256 timestamp;
}

/// @notice Data structure for exiting the sPOL unstake fuse (claim matured POL to the vault)
struct SPOLUnstakeFuseExitData {
    /// @dev sPOLController address; must be granted as a substrate of MARKET_ID
    address controller;
    /// @dev caller-supplied timestamp echoed in the exit event for off-chain correlation; 0 = block.timestamp
    uint256 timestamp;
}

/// @notice Data structure for the sweep action (flush executor-held tokens to the vault)
struct SPOLUnstakeFuseSweepData {
    /// @dev token to sweep from the vault's executor to the vault (POL, sPOL, or any stranded token)
    address token;
    /// @dev caller-supplied timestamp echoed in the sweep event for off-chain correlation; 0 = block.timestamp
    uint256 timestamp;
}

/// @notice Thrown when the controller is not granted as a substrate of the fuse's market
error SPOLUnstakeFuseUnsupportedController(address controller);

/// @notice Thrown when the POL amount queued for the unstake would be below the minimum required
error SPOLUnstakeFuseInsufficientPolOut(uint256 polAmount, uint256 minPolAmountOut);

/// @notice Thrown when exit/sweep runs before any enter deployed the vault's executor
error SPOLUnstakeFuseExecutorNotDeployed();

/// @title Fuse for unstaking sPOL into POL via the sPOLController, routed through a per-vault executor
/// @notice Enter burns the vault's sPOL through sellSPOL and queues a fixed POL amount in the controller's
///         per-address FIFO cooldown queue (~80 checkpoints / ~3 days). Exit claims matured POL to the vault.
///         Sweep flushes anomalously parked tokens from the executor to the vault.
/// @dev WHY AN EXECUTOR: sPOLController.withdrawPOL(address user) is permissionless and always pays `user`.
///      If the vault owned the queue, anyone could land POL in the vault wallet OUTSIDE vault execution;
///      market balances are lazy snapshots, so a refresh touching the ERC20 market but not this market would
///      double-count that POL, corrupting share quotes. Both enter and exit therefore route through a
///      per-vault SPOLUnstakeExecutor that is msg.sender on the controller: the queue and payouts attribute
///      to the executor, so a third-party withdrawPOL(executor) can only move POL onto the executor — which
///      SPOLBalanceFuse counts in this same market (queue amounts are POL-denominated, so the market balance
///      is invariant under third-party claims). Value reaches the vault wallet only inside execute(), where
///      the dependency graph refreshes both market snapshots atomically.
///
///      The executor is deployed lazily on the first enter and recorded in vault-local ERC-7201 storage
///      (SPOLUnstakeExecutorStorageLib); resolve it off-chain via ReadSPOLUnstakeExecutor. Keepers may call
///      the permissionless controller.withdrawPOL(executor) — the POL lands on the executor and is flushed
///      to the vault by the sweep action.
///
///      Required configuration:
///        - SPOLBalanceFuse on this fuse's market (values the executor's pending queue + executor-held POL)
///        - sPOL and POL granted as substrates of the ERC20 balance market to track wallet balances
///        - POL price source configured in the vault's PriceOracleMiddleware
///        - Dependency graph: this fuse's market -> ERC20_VAULT_BALANCE market
///
///      Balance Update Dependency Graph:
///        ┌──────────────────┐         ┌──────────────────┐
///        │  Market N        │ depends │  ERC20_VAULT_    │
///        │  (sPOLController)│───on───>│  BALANCE         │
///        │  SPOLBalanceFuse │         │  (sPOL/POL)      │
///        └──────────────────┘         └──────────────────┘
contract SPOLUnstakeFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice Address of this fuse contract
    address public immutable VERSION;

    /// @notice Market ID for the fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when entering (sPOL -> pending POL in the executor's cooldown queue)
    /// @param version Address of the fuse
    /// @param controller sPOLController the unstake was sent to
    /// @param spolAmount Amount of sPOL burned
    /// @param polAmount POL expected from the sale (fixed at the current rate; the queued amount).
    ///        The realized amount is reported by the exit event and can be lower under validator slashing.
    /// @param timestamp Caller-supplied timestamp for off-chain correlation (block.timestamp when 0 was given)
    event SPOLUnstakeFuseEnter(
        address version,
        address controller,
        uint256 spolAmount,
        uint256 polAmount,
        uint256 timestamp
    );

    /// @notice Emitted when exiting (claiming matured POL to the vault)
    /// @param version Address of the fuse
    /// @param controller sPOLController the claim was sent to
    /// @param polAmount POL actually claimed and delivered to the vault (measured, slashing-aware)
    /// @param timestamp Caller-supplied timestamp for off-chain correlation (block.timestamp when 0 was given)
    event SPOLUnstakeFuseExit(address version, address controller, uint256 polAmount, uint256 timestamp);

    /// @notice Emitted when sweeping a token from the vault's executor to the vault
    /// @param version Address of the fuse
    /// @param token Token swept
    /// @param amount Amount transferred to the vault
    /// @param timestamp Caller-supplied timestamp for off-chain correlation (block.timestamp when 0 was given)
    event SPOLUnstakeFuseSweep(address version, address token, uint256 amount, uint256 timestamp);

    /// @notice Emitted once per vault when the executor is deployed on the first enter
    /// @param version Address of the fuse
    /// @param executor The vault's SPOLUnstakeExecutor address (permanent)
    event SPOLUnstakeFuseExecutorCreated(address version, address executor);

    /// @notice Constructor
    /// @param marketIdInput Market ID
    constructor(uint256 marketIdInput) {
        VERSION = address(this);
        MARKET_ID = marketIdInput;
    }

    /// @notice Enters by unstaking sPOL via the vault's executor, queueing the POL equivalent in the cooldown queue
    /// @dev Deploys the executor on first use (after all guards, so failing calls never deploy). Validator
    ///      routing is left to the controller (most-overfunded first, possibly multiple nonces).
    /// @param data The input data containing the controller, sPOL amount and rate guard
    /// @return polAmount The amount of POL queued for withdrawal after the cooldown
    function enter(SPOLUnstakeFuseEnterData memory data) public returns (uint256 polAmount) {
        if (data.spolAmount == 0) {
            return 0;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.controller)) {
            revert SPOLUnstakeFuseUnsupportedController(data.controller);
        }

        ISPOLController controller = ISPOLController(data.controller);
        IERC20 spolToken = IERC20(controller.sPOLToken());

        uint256 finalAmount = IporMath.min(data.spolAmount, spolToken.balanceOf(address(this)));
        if (finalAmount == 0) {
            return 0;
        }

        // sellSPOL queues exactly convertSPOLtoPOL(finalAmount) at the same rate in the same tx
        polAmount = controller.convertSPOLtoPOL(finalAmount);
        if (polAmount < data.minPolAmountOut) {
            revert SPOLUnstakeFuseInsufficientPolOut(polAmount, data.minPolAmountOut);
        }

        address executor = SPOLUnstakeExecutorStorageLib.getExecutor();
        if (executor == address(0)) {
            executor = SPOLUnstakeExecutorStorageLib.getOrDeployExecutor(address(this));
            emit SPOLUnstakeFuseExecutorCreated(VERSION, executor);
        }

        spolToken.safeTransfer(executor, finalAmount);
        SPOLUnstakeExecutor(executor).unstake(data.controller, finalAmount);

        emit SPOLUnstakeFuseEnter(
            VERSION,
            data.controller,
            finalAmount,
            polAmount,
            data.timestamp == 0 ? block.timestamp : data.timestamp
        );
    }

    /// @notice Enters using transient storage for input/output
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        uint256 polAmount = enter(
            SPOLUnstakeFuseEnterData({
                controller: TypeConversionLib.toAddress(inputs[0]),
                spolAmount: TypeConversionLib.toUint256(inputs[1]),
                minPolAmountOut: TypeConversionLib.toUint256(inputs[2]),
                timestamp: TypeConversionLib.toUint256(inputs[3])
            })
        );

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(polAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits by claiming all matured POL from the executor's cooldown queue to the vault
    /// @dev Fail-loud: controller reverts bubble unchanged — NoOpenNonces(executor) when the queue is empty,
    ///      NoNoncesReady(executor) when nonces exist but none matured, and pause errors. When POL is parked
    ///      on the executor with nothing claimable (third-party claim), run the sweep action instead.
    /// @param data The input data containing the controller
    /// @return polAmount The amount of POL claimed and delivered to the vault
    function exit(SPOLUnstakeFuseExitData memory data) public returns (uint256 polAmount) {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.controller)) {
            revert SPOLUnstakeFuseUnsupportedController(data.controller);
        }

        address executor = SPOLUnstakeExecutorStorageLib.getExecutor();
        if (executor == address(0)) {
            revert SPOLUnstakeFuseExecutorNotDeployed();
        }

        polAmount = SPOLUnstakeExecutor(executor).claim(data.controller);

        emit SPOLUnstakeFuseExit(
            VERSION,
            data.controller,
            polAmount,
            data.timestamp == 0 ? block.timestamp : data.timestamp
        );
    }

    /// @notice Exits using transient storage for input/output
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        uint256 polAmount = exit(
            SPOLUnstakeFuseExitData({
                controller: TypeConversionLib.toAddress(inputs[0]),
                timestamp: TypeConversionLib.toUint256(inputs[1])
            })
        );

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(polAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Sweeps a token from the vault's executor to the vault
    /// @dev Anomaly flush, not part of the normal enter/exit flow: POL parked by third-party permissionless
    ///      withdrawPOL(executor) calls, donation attacks, or any stranded token. Safe for arbitrary tokens
    ///      by construction — the executor only ever pays the vault. Runs as a regular FuseAction inside
    ///      execute(), so this market and its dependency graph refresh atomically with the transfer.
    /// @param data The input data containing the token to sweep
    /// @return amount The amount transferred to the vault
    function sweep(SPOLUnstakeFuseSweepData memory data) public returns (uint256 amount) {
        address executor = SPOLUnstakeExecutorStorageLib.getExecutor();
        if (executor == address(0)) {
            revert SPOLUnstakeFuseExecutorNotDeployed();
        }

        amount = SPOLUnstakeExecutor(executor).sweep(data.token);

        emit SPOLUnstakeFuseSweep(
            VERSION,
            data.token,
            amount,
            data.timestamp == 0 ? block.timestamp : data.timestamp
        );
    }
}
