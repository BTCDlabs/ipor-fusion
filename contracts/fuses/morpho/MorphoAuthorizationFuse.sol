// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IMorpho} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/// @notice Structure for entering the Morpho Authorization Fuse
/// @param authorized The account to authorize to manage the Plasma Vault's Morpho positions
struct MorphoAuthorizationFuseEnterData {
    /// @notice The account to authorize to manage the Plasma Vault's Morpho positions
    address authorized;
}

/// @notice Structure for exiting the Morpho Authorization Fuse
/// @param authorized The account whose authorization over the Plasma Vault's Morpho positions is revoked
struct MorphoAuthorizationFuseExitData {
    /// @notice The account whose authorization over the Plasma Vault's Morpho positions is revoked
    address authorized;
}

/**
 * @title Fuse for managing Morpho Blue position authorizations
 * @notice Enables the Plasma Vault to grant (enter) and revoke (exit) another account's permission
 *         to manage the vault's Morpho positions via Morpho's setAuthorization mechanism
 * @dev Morpho authorization is global across all Morpho markets: an authorized account may call
 *      withdraw, borrow and withdrawCollateral with the vault as onBehalf — i.e. move the vault's
 *      supply and debt. Because this fuse runs via delegatecall from the Plasma Vault, the vault is
 *      the authorizer (msg.sender inside Morpho). Governance controls who may ever be authorized by
 *      granting the candidate addresses as substrates on MARKET_ID.
 */
contract MorphoAuthorizationFuse is IFuseCommon {
    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates (authorized account addresses)
    uint256 public immutable MARKET_ID;

    /// @notice Morpho protocol contract address
    /// @dev Immutable value set in constructor, used for Morpho protocol interactions
    IMorpho public immutable MORPHO;

    /// @notice Thrown when the account is not granted as a substrate for this market
    /// @param action The action that was attempted ("enter" or "exit")
    /// @param authorized The address of the account that is not supported
    /// @custom:error MorphoAuthorizationFuseUnsupportedAccount
    error MorphoAuthorizationFuseUnsupportedAccount(string action, address authorized);

    /// @notice Emitted when an account is authorized to manage the vault's Morpho positions
    /// @param version The address of this fuse contract version
    /// @param authorized The account that was authorized
    /// @param isAuthorized The resulting authorization status (always true)
    event MorphoAuthorizationFuseEnter(address version, address authorized, bool isAuthorized);

    /// @notice Emitted when an account's authorization to manage the vault's Morpho positions is revoked
    /// @param version The address of this fuse contract version
    /// @param authorized The account whose authorization was revoked
    /// @param isAuthorized The resulting authorization status (always false)
    event MorphoAuthorizationFuseExit(address version, address authorized, bool isAuthorized);

    /**
     * @notice Initializes the MorphoAuthorizationFuse with a market ID and Morpho address
     * @param marketId_ The market ID used to identify the authorized account substrates
     * @param morpho_ The address of the Morpho protocol contract
     * @dev Sets VERSION to the address of this contract instance for tracking purposes
     */
    constructor(uint256 marketId_, address morpho_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MORPHO = IMorpho(morpho_);
    }

    /**
     * @notice Authorizes an account to manage the Plasma Vault's Morpho positions
     * @param data_ Struct containing the account to authorize
     * @return authorized The account that was authorized
     * @return isAuthorized The resulting authorization status (true)
     * @dev Validates the account against the market substrates, then calls
     *      MORPHO.setAuthorization(account, true). Skips the Morpho call when the account is already
     *      authorized (Morpho reverts with "already set" on a no-op toggle).
     */
    function enter(
        MorphoAuthorizationFuseEnterData memory data_
    ) public returns (address authorized, bool isAuthorized) {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.authorized)) {
            revert MorphoAuthorizationFuseUnsupportedAccount("enter", data_.authorized);
        }

        if (!MORPHO.isAuthorized(address(this), data_.authorized)) {
            MORPHO.setAuthorization(data_.authorized, true);
        }

        authorized = data_.authorized;
        isAuthorized = true;

        emit MorphoAuthorizationFuseEnter(VERSION, authorized, isAuthorized);
    }

    /// @notice Enters the Morpho Authorization Fuse using transient storage for parameters
    /// @dev Input format: inputs[0] = authorized account address. Writes (authorized, isAuthorized) to outputs.
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        (address returnedAuthorized, bool returnedIsAuthorized) = enter(
            MorphoAuthorizationFuseEnterData({authorized: TypeConversionLib.toAddress(inputs[0])})
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAuthorized);
        outputs[1] = TypeConversionLib.toBytes32(returnedIsAuthorized);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /**
     * @notice Revokes an account's authorization to manage the Plasma Vault's Morpho positions
     * @param data_ Struct containing the account whose authorization is revoked
     * @return authorized The account whose authorization was revoked
     * @return isAuthorized The resulting authorization status (false)
     * @dev Validates the account against the market substrates, then calls
     *      MORPHO.setAuthorization(account, false). Skips the Morpho call when the account is not
     *      authorized (Morpho reverts with "already set" on a no-op toggle).
     */
    function exit(MorphoAuthorizationFuseExitData memory data_) public returns (address authorized, bool isAuthorized) {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.authorized)) {
            revert MorphoAuthorizationFuseUnsupportedAccount("exit", data_.authorized);
        }

        if (MORPHO.isAuthorized(address(this), data_.authorized)) {
            MORPHO.setAuthorization(data_.authorized, false);
        }

        authorized = data_.authorized;
        isAuthorized = false;

        emit MorphoAuthorizationFuseExit(VERSION, authorized, isAuthorized);
    }

    /// @notice Exits the Morpho Authorization Fuse using transient storage for parameters
    /// @dev Input format: inputs[0] = authorized account address. Writes (authorized, isAuthorized) to outputs.
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        (address returnedAuthorized, bool returnedIsAuthorized) = exit(
            MorphoAuthorizationFuseExitData({authorized: TypeConversionLib.toAddress(inputs[0])})
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAuthorized);
        outputs[1] = TypeConversionLib.toBytes32(returnedIsAuthorized);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
