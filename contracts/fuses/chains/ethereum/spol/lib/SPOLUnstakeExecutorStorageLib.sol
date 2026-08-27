// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SPOLUnstakeExecutor} from "../SPOLUnstakeExecutor.sol";

/// @title SPOLUnstakeExecutorStorageLib
/// @notice ERC-7201 namespaced storage for the per-vault SPOLUnstakeExecutor address
/// @dev All functions are internal and run in the Plasma Vault's delegatecall context, so the slot lives in
///      EACH VAULT'S own storage — one executor per vault while the fuses stay shared singletons.
///      The slot is written once on first deployment and never overwritten (no setter is exposed to
///      governance); the executor address is permanent for the vault's lifetime.
library SPOLUnstakeExecutorStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.spolUnstake.Executor")) - 1)) & ~bytes32(uint256(0xff))
    ///      Verify with: cast index-erc7201 "io.ipor.spolUnstake.Executor"
    bytes32 private constant SPOL_UNSTAKE_EXECUTOR_SLOT =
        0xa56afc2a6b08675c3b996ba4937d309d4c4219c04c5fbdd338969f8501e0d200;

    /// @custom:storage-location erc7201:io.ipor.spolUnstake.Executor
    struct SPOLUnstakeExecutorStorage {
        /// @dev Address of the vault's SPOLUnstakeExecutor; zero until the first enter deploys it
        address executor;
    }

    /// @notice Returns the vault's executor address, or address(0) if never deployed
    function getExecutor() internal view returns (address executorAddress) {
        executorAddress = _getExecutorStorage().executor;
    }

    /// @notice Returns the vault's executor, deploying and recording it on first use
    /// @param plasmaVault_ The Plasma Vault the executor is bound to (address(this) under delegatecall)
    function getOrDeployExecutor(address plasmaVault_) internal returns (address executorAddress) {
        executorAddress = getExecutor();

        if (executorAddress == address(0)) {
            executorAddress = address(new SPOLUnstakeExecutor(plasmaVault_));
            _getExecutorStorage().executor = executorAddress;
        }
    }

    function _getExecutorStorage() private pure returns (SPOLUnstakeExecutorStorage storage storagePtr) {
        assembly {
            storagePtr.slot := SPOL_UNSTAKE_EXECUTOR_SLOT
        }
    }
}
