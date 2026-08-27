// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {UniversalReader, ReadResult} from "../universal_reader/UniversalReader.sol";
import {SPOLUnstakeExecutorStorageLib} from "../fuses/chains/ethereum/spol/lib/SPOLUnstakeExecutorStorageLib.sol";

/// @title ReadSPOLUnstakeExecutor
/// @notice Reads a Plasma Vault's SPOLUnstakeExecutor address from its vault-local ERC-7201 storage
/// @dev The executor owns the vault's sPOLController unstake queue. Keepers resolve it here to call the
///      permissionless sPOLController.withdrawPOL(executor) — the POL lands on the executor and is flushed
///      to the vault by the SPOLUnstakeFuse sweep action. Returns address(0) before the first enter.
contract ReadSPOLUnstakeExecutor {
    /// @notice Reads the executor address from storage (delegatecall target for UniversalReader)
    /// @return executorAddress The vault's SPOLUnstakeExecutor, or address(0) if not yet deployed
    function readSPOLUnstakeExecutorAddress() external view returns (address executorAddress) {
        executorAddress = SPOLUnstakeExecutorStorageLib.getExecutor();
    }

    /// @notice Reads the executor address of a specific Plasma Vault via the UniversalReader pattern
    /// @param plasmaVault_ Address of the Plasma Vault to read from
    /// @return executorAddress The vault's SPOLUnstakeExecutor, or address(0) if not yet deployed
    function getSPOLUnstakeExecutorAddress(address plasmaVault_) external view returns (address executorAddress) {
        ReadResult memory readResult = UniversalReader(address(plasmaVault_)).read(
            address(this),
            abi.encodeWithSignature("readSPOLUnstakeExecutorAddress()")
        );
        executorAddress = abi.decode(readResult.data, (address));
    }
}
