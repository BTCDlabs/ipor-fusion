// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IporMath} from "../../../../libraries/math/IporMath.sol";
import {TypeConversionLib} from "../../../../libraries/TypeConversionLib.sol";
import {PlasmaVaultConfigLib} from "../../../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../../../IFuseCommon.sol";
import {ISPOLController} from "./ext/ISPOLController.sol";

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

/// @notice Data structure for exiting the sPOL unstake fuse (claim matured POL)
struct SPOLUnstakeFuseExitData {
    /// @dev sPOLController address; must be granted as a substrate of MARKET_ID
    address controller;
    /// @dev caller-supplied timestamp echoed in the exit event for off-chain correlation; 0 = block.timestamp
    uint256 timestamp;
}

/// @notice Thrown when the controller is not granted as a substrate of the fuse's market
error SPOLUnstakeFuseUnsupportedController(address controller);

/// @notice Thrown when the POL amount queued for the unstake would be below the minimum required
error SPOLUnstakeFuseInsufficientPolOut(uint256 polAmount, uint256 minPolAmountOut);

/// @title Fuse for unstaking sPOL into POL via the sPOLController
/// @notice Enter burns the vault's sPOL through sellSPOL and queues a fixed POL amount in the controller's
///         per-address FIFO cooldown queue (~80 checkpoints / ~3 days). Exit claims all matured POL.
/// @dev Fuses execute via delegatecall, so the vault itself is msg.sender on the controller: the unstake
///      nonces accrue to the vault and withdrawPOL pays the vault directly. No approval is needed —
///      the controller has direct burn rights on sPOL.
///
///      withdrawPOL(vault) on the controller is permissionless and always pays the vault, so keepers can
///      claim matured POL without this fuse; exit() exists for alpha-driven atomic flows.
///
///      BALANCE & ACCOUNTING DEPENDENCY:
///      After enter(), sPOL disappears from the vault's token balance and the pending POL claim appears
///      on this fuse's market via SPOLBalanceFuse (sums getUserOpenNonces amounts). After exit() (or a
///      keeper claim), the pending claim shrinks and POL appears in the vault's token balance.
///
///      Required configuration:
///        - SPOLBalanceFuse on this fuse's market (values the pending POL queue)
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
    /// @notice Address of this fuse contract
    address public immutable VERSION;

    /// @notice Market ID for the fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when entering (sPOL -> pending POL in the cooldown queue)
    /// @param version Address of the fuse
    /// @param controller sPOLController the unstake was sent to
    /// @param spolAmount Amount of sPOL burned
    /// @param polAmount Amount of POL queued (fixed at the current rate)
    /// @param timestamp Caller-supplied timestamp for off-chain correlation (block.timestamp when 0 was given)
    event SPOLUnstakeFuseEnter(
        address version,
        address controller,
        uint256 spolAmount,
        uint256 polAmount,
        uint256 timestamp
    );

    /// @notice Emitted when exiting (claiming matured POL)
    /// @param version Address of the fuse
    /// @param controller sPOLController the claim was sent to
    /// @param polAmount Amount of POL received by the vault
    /// @param timestamp Caller-supplied timestamp for off-chain correlation (block.timestamp when 0 was given)
    event SPOLUnstakeFuseExit(address version, address controller, uint256 polAmount, uint256 timestamp);

    /// @notice Constructor
    /// @param marketIdInput Market ID
    constructor(uint256 marketIdInput) {
        VERSION = address(this);
        MARKET_ID = marketIdInput;
    }

    /// @notice Enters by unstaking sPOL via sellSPOL, queueing the POL equivalent in the cooldown queue
    /// @dev Validator routing is left to the controller (most-overfunded first, possibly multiple nonces)
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

        uint256 finalAmount = IporMath.min(
            data.spolAmount,
            IERC20(controller.sPOLToken()).balanceOf(address(this))
        );
        if (finalAmount == 0) {
            return 0;
        }

        // sellSPOL queues exactly convertSPOLtoPOL(finalAmount) at the same rate in the same tx
        polAmount = controller.convertSPOLtoPOL(finalAmount);
        if (polAmount < data.minPolAmountOut) {
            revert SPOLUnstakeFuseInsufficientPolOut(polAmount, data.minPolAmountOut);
        }

        controller.sellSPOL(finalAmount);

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

    /// @notice Exits by claiming all matured POL from the cooldown queue (FIFO, stops at the first non-matured nonce)
    /// @dev Reverts on the controller with NoOpenNonces(vault) when the queue is empty and NoNoncesReady(vault)
    ///      when nonces exist but none matured — only call exit when a claim is known to be withdrawable
    /// @param data The input data containing the controller
    /// @return polAmount The amount of POL received by the vault
    function exit(SPOLUnstakeFuseExitData memory data) public returns (uint256 polAmount) {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.controller)) {
            revert SPOLUnstakeFuseUnsupportedController(data.controller);
        }

        ISPOLController controller = ISPOLController(data.controller);
        IERC20 polToken = IERC20(controller.polToken());

        uint256 polBefore = polToken.balanceOf(address(this));

        controller.withdrawPOL();

        polAmount = polToken.balanceOf(address(this)) - polBefore;

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
}
