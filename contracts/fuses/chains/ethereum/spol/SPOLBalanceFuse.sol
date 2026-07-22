// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../../../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../../../libraries/PlasmaVaultLib.sol";
import {ISPOLController, FullNonceDetails} from "./ext/ISPOLController.sol";

/// @title Balance fuse for POL pending in the sPOLController unstake cooldown queue
/// @notice Values the Plasma Vault's open unstake nonces in the sPOLController (~80 checkpoints / ~3 days cooldown)
/// @dev When SPOLUnstakeFuse executes sellSPOL, sPOL is burned immediately and a fixed POL amount is queued
///      under the vault's address (fuses run via delegatecall, so the vault is msg.sender on the controller).
///      During cooldown the vault holds no token for the position — without this fuse totalAssets() would
///      drop by the full unstaked value at sellSPOL time.
///
///      Sums ALL open nonces (in-cooldown + matured-but-unclaimed): a nonce closes only when withdrawPOL
///      pays POL to the vault wallet, where the ERC20 balance fuse (ERC20_VAULT_BALANCE market) picks it
///      up — so there is no double counting.
///
///      Substrates: sPOLController addresses. The POL token used for pricing is derived from
///      controller.polToken(), so it must have a price source in the vault's PriceOracleMiddleware.
contract SPOLBalanceFuse is IMarketBalanceFuse {
    /// @notice Thrown when market ID is zero
    error SPOLBalanceFuseInvalidMarketId();

    /// @notice Thrown when the price oracle middleware is not set in the vault
    error SPOLBalanceFusePriceOracleNotSet();

    /// @notice Thrown when the POL price from the oracle is zero; under-reporting pending POL
    ///         would misprice vault shares, so revert instead of returning a partial balance
    error SPOLBalanceFusePolPriceIsZero(address polToken);

    /// @notice Address of this fuse contract version
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert SPOLBalanceFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Calculates the USD value of all POL queued for this vault across granted controllers
    /// @return balanceInUsd Total pending POL value in USD, normalized to WAD (18 decimals)
    function balanceOf() external view override returns (uint256 balanceInUsd) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = substrates.length;

        if (len == 0) {
            return 0;
        }

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        if (priceOracleMiddleware == address(0)) {
            revert SPOLBalanceFusePriceOracleNotSet();
        }

        address controller;
        uint256 pendingPol;
        address polToken;
        uint256 price;
        uint256 priceDecimals;

        for (uint256 i; i < len; ++i) {
            controller = PlasmaVaultConfigLib.bytes32ToAddress(substrates[i]);

            FullNonceDetails[] memory openNonces = ISPOLController(controller).getUserOpenNonces(address(this));

            pendingPol = 0;
            for (uint256 j; j < openNonces.length; ++j) {
                pendingPol += openNonces[j].amount;
            }

            if (pendingPol == 0) {
                continue;
            }

            polToken = ISPOLController(controller).polToken();
            (price, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(polToken);

            if (price == 0) {
                revert SPOLBalanceFusePolPriceIsZero(polToken);
            }

            balanceInUsd += IporMath.convertToWad(
                pendingPol * price,
                IERC20Metadata(polToken).decimals() + priceDecimals
            );
        }
    }
}
