// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISPOLController} from "./ext/ISPOLController.sol";

/// @title SPOLUnstakeExecutor
/// @notice Per-vault sidecar that owns the sPOLController unstake queue on behalf of one Plasma Vault
/// @dev NOT a fuse: called directly by the PlasmaVault (SPOLUnstakeFuse code delegatecall-runs as the vault,
///      so msg.sender here is the vault). Deployed lazily by the fuse and recorded in vault-local ERC-7201
///      storage (SPOLUnstakeExecutorStorageLib); the address is permanent — the slot is written once and
///      there is no setter.
///
///      WHY THIS CONTRACT EXISTS: sPOLController.withdrawPOL(address user) is permissionless and always
///      pays `user`. If the vault itself owned the queue, anyone could land POL in the vault wallet
///      OUTSIDE vault execution; Plasma Vault market balances are lazy snapshots, so the next refresh
///      touching the ERC20 market but not this fuse's market would double-count that POL (and the reverse
///      order under-counts), corrupting share quotes. With this executor as the queue owner, a third-party
///      withdrawPOL(executor) can only move POL onto this contract — and since queue amounts are
///      POL-denominated and fixed at sellSPOL time, `pending nonces + POL held here` (what SPOLBalanceFuse
///      counts) is invariant under third-party claims. Value reaches the vault wallet only inside a vault
///      execution, where the dependency graph refreshes both market snapshots atomically.
///
///      Holds no tokens in legitimate flows: unstake burns the exact sPOL amount in the same transaction
///      (sellSPOL cannot partially fill — the controller reverts NotEnoughStake), and claim forwards the
///      freshly-claimed POL to the vault immediately. Tokens can rest here only from third-party claims or
///      donations; the fuse's sweep action flushes those to the vault.
contract SPOLUnstakeExecutor {
    using SafeERC20 for IERC20;

    /// @notice Thrown when a function is called by anyone other than the bound Plasma Vault
    error SPOLUnstakeExecutorUnauthorizedCaller();

    /// @notice Thrown when the constructor receives a zero Plasma Vault address
    error SPOLUnstakeExecutorInvalidPlasmaVaultAddress();

    /// @notice The Plasma Vault this executor is bound to; sole authorized caller and sole payout destination
    address public immutable PLASMA_VAULT;

    modifier onlyPlasmaVault() {
        if (msg.sender != PLASMA_VAULT) {
            revert SPOLUnstakeExecutorUnauthorizedCaller();
        }
        _;
    }

    constructor(address plasmaVault_) {
        if (plasmaVault_ == address(0)) {
            revert SPOLUnstakeExecutorInvalidPlasmaVaultAddress();
        }
        PLASMA_VAULT = plasmaVault_;
    }

    /// @notice Unstakes sPOL held by this executor via sellSPOL; the unstake nonces accrue to this executor
    /// @dev The fuse transfers the exact sPOL amount here in the same transaction before calling.
    ///      sellSPOL burns this executor's sPOL directly (the controller has burn rights, no approval)
    ///      and cannot partially fill — it reverts NotEnoughStake when validators cannot cover the amount,
    ///      so no sPOL residue is possible.
    /// @param controller_ The sPOLController
    /// @param spolAmount_ Amount of sPOL (18 decimals) to unstake
    /// @return nonces Created unstake queue nonces (one per validator used)
    function unstake(
        address controller_,
        uint256 spolAmount_
    ) external onlyPlasmaVault returns (uint256[] memory nonces) {
        nonces = ISPOLController(controller_).sellSPOL(spolAmount_);
    }

    /// @notice Claims all matured POL from the cooldown queue and forwards exactly that amount to the vault
    /// @dev Every controller revert bubbles unchanged (NoOpenNonces / NoNoncesReady / pause): when the queue
    ///      is empty or immature the alpha runs the fuse's sweep action instead. The forwarded amount is the
    ///      measured balance delta, NOT the queued amount — the payout is the ValidatorShare `shares` value
    ///      at claim time, and validator slashing during the unbond can pay less than what was queued
    ///      (inherent position risk). POL already resting here (third-party claims, donations) is
    ///      deliberately left untouched for the sweep action.
    /// @param controller_ The sPOLController
    /// @return polAmount POL claimed and forwarded to the vault
    function claim(address controller_) external onlyPlasmaVault returns (uint256 polAmount) {
        IERC20 polToken = IERC20(ISPOLController(controller_).polToken());

        uint256 polBefore = polToken.balanceOf(address(this));

        ISPOLController(controller_).withdrawPOL();

        polAmount = polToken.balanceOf(address(this)) - polBefore;

        if (polAmount > 0) {
            polToken.safeTransfer(PLASMA_VAULT, polAmount);
        }
    }

    /// @notice Transfers this executor's full balance of a token to the vault
    /// @dev Anomaly flush and rescue hatch: POL parked by third-party withdrawPOL(executor) calls,
    ///      donation attacks, or any stranded token. Always pays the vault, so sweeping an arbitrary
    ///      token is harmless by construction.
    /// @param token_ Token to sweep
    /// @return amount Amount transferred to the vault
    function sweep(address token_) external onlyPlasmaVault returns (uint256 amount) {
        amount = IERC20(token_).balanceOf(address(this));
        if (amount > 0) {
            IERC20(token_).safeTransfer(PLASMA_VAULT, amount);
        }
    }
}
