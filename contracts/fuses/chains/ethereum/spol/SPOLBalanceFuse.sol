// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../../../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../../../libraries/PlasmaVaultLib.sol";
import {ISPOLController, FullNonceDetails} from "./ext/ISPOLController.sol";
import {SPOLUnstakeExecutorStorageLib} from "./lib/SPOLUnstakeExecutorStorageLib.sol";

/// @title Balance fuse for POL pending in the sPOLController unstake cooldown queue via the vault's executor
/// @notice Values the vault's SPOLUnstakeExecutor position: open unstake nonces in the sPOLController
///         (~80 checkpoints / ~3 days cooldown) PLUS POL currently held by the executor
/// @dev SPOLUnstakeFuse routes sellSPOL/withdrawPOL through a per-vault executor, so the unstake queue and
///      any permissionless third-party withdrawPOL(executor) payout attribute to the EXECUTOR, never the
///      vault wallet. Queue amounts are POL-denominated and fixed at sell time, so a third-party claim
///      converts "pending nonce POL" one-for-one into "executor wallet POL" — both terms of this fuse —
///      leaving this market's balance and totalAssets() INVARIANT under third-party claims. Value reaches
///      the vault wallet (ERC20 balance market) only inside execute(), where the dependency graph refreshes
///      both market snapshots atomically.
///
///      This market supports EXACTLY ONE substrate: the sPOLController address. balanceOf() reverts when
///      more are granted (fail-loud on misconfiguration; the mainnet controller is a singleton and both
///      fuse terms assume a single POL token). sPOL resting on the executor is deliberately NOT counted:
///      legitimate flows leave zero sPOL there (sellSPOL burns the exact amount, no partial fills), and
///      donations are flushed to the vault by the sweep action, surfacing in the ERC20 balance market
///      like any other donation.
///
///      Returns 0 before the executor exists (nothing can be pending). The POL price must be available in
///      the vault's PriceOracleMiddleware. Note: pending valuation uses queued amounts; validator slashing
///      during the unbond can realize less at claim time (inherent position risk).
contract SPOLBalanceFuse is IMarketBalanceFuse {
    /// @notice Thrown when market ID is zero
    error SPOLBalanceFuseInvalidMarketId();

    /// @notice Thrown when more than one controller substrate is granted; this fuse values a single controller
    error SPOLBalanceFuseMultipleSubstratesNotSupported();

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

    /// @notice Calculates the USD value of the vault's executor position in the granted controller
    /// @return balanceInUsd Pending POL (open nonces) + executor-held POL, in USD normalized to WAD (18 decimals)
    function balanceOf() external view override returns (uint256 balanceInUsd) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        if (substrates.length == 0) {
            return 0;
        }
        if (substrates.length > 1) {
            revert SPOLBalanceFuseMultipleSubstratesNotSupported();
        }

        address executor = SPOLUnstakeExecutorStorageLib.getExecutor();

        if (executor == address(0)) {
            return 0;
        }

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        if (priceOracleMiddleware == address(0)) {
            revert SPOLBalanceFusePriceOracleNotSet();
        }

        ISPOLController controller = ISPOLController(PlasmaVaultConfigLib.bytes32ToAddress(substrates[0]));

        FullNonceDetails[] memory openNonces = controller.getUserOpenNonces(executor);

        uint256 polBalance;
        for (uint256 i; i < openNonces.length; i++) {
            polBalance += openNonces[i].amount;
        }

        address polToken = controller.polToken();

        // executor-held POL, e.g. parked by permissionless third-party withdrawPOL(executor) payouts
        polBalance += IERC20(polToken).balanceOf(executor);

        if (polBalance == 0) {
            return 0;
        }

        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(
            polToken
        );

        if (price == 0) {
            revert SPOLBalanceFusePolPriceIsZero(polToken);
        }

        balanceInUsd = IporMath.convertToWad(polBalance * price, IERC20Metadata(polToken).decimals() + priceDecimals);
    }
}
