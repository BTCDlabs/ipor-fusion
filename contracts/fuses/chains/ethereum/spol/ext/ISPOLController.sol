// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

/// @notice Details of an open (unclaimed) unstake nonce in the sPOLController FIFO queue
/// @dev Field order must match the sPOLController struct (github.com/0xPolygon/sPOL-contracts)
struct FullNonceDetails {
    /// @dev Polygon validator the unstake was routed through
    uint16 validatorId;
    /// @dev POL amount (18 decimals) fixed at sellSPOL time via convertSPOLtoPOL
    uint128 amount;
    /// @dev nonce within the validator's unbond queue
    uint96 validatorNonce;
    /// @dev global per-user nonce
    uint256 nonce;
}

/// @title Minimal interface of the sPOLController (mainnet: 0xEaadA411F2600570796c341552b9869DA708a28B)
/// @notice sPOL is a liquid staking token for POL; selling burns sPOL immediately (the controller has
///         direct burn rights, no approval needed) and queues a fixed POL amount per msg.sender.
///         POL matures after the Polygon StakeManager withdrawal delay (~80 checkpoints, ~3 days).
interface ISPOLController {
    /// @notice Unstake sPOL routed across validators (most-overfunded first). Burns msg.sender's sPOL,
    ///         queues the POL equivalent under msg.sender.
    /// @param _amount Amount of sPOL (18 decimals) to unstake
    /// @return nonces Created unstake queue nonces (one per validator used)
    function sellSPOL(uint256 _amount) external returns (uint256[] memory nonces);

    /// @notice Withdraw all matured POL for msg.sender (FIFO; stops at the first non-matured nonce)
    function withdrawPOL() external;

    /// @notice Withdraw all matured POL for `_user` — permissionless, always pays `_user`
    function withdrawPOL(address _user) external;

    /// @notice All open unstake nonces for a user: still-in-cooldown AND matured-but-unclaimed.
    /// @dev A nonce closes only when withdrawPOL pays it out.
    function getUserOpenNonces(address _user) external view returns (FullNonceDetails[] memory);

    /// @notice Convert an sPOL amount to POL at the current exchange rate
    function convertSPOLtoPOL(uint256 _amountSPOL) external view returns (uint256);

    /// @notice POL token address (mainnet: 0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6)
    function polToken() external view returns (address);

    /// @notice sPOL token address (mainnet: 0x3B790d651e950497c7723D47B24E6f61534f7969)
    function sPOLToken() external view returns (address);
}
