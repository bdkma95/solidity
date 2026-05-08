// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library LibErrors {
    // -------------------------
    // Initialization
    // -------------------------
    error EmptyString();

    // -------------------------
    // Adresses
    // -------------------------

    error ZeroAddress();
    error InvalidTokenAddress(address token);

    // -------------------------
    // Montants
    // -------------------------

    /// @dev Utilisé pour mint, burn, complianceBurn
    error ZeroAmount();

    /// @notice Thrown when a mint would push the total supply above MAX_SUPPLY.
    /// @param attempted The total supply that would result from the mint.
    /// @param cap       The maximum allowed supply.
    error SupplyCapExceeded(uint256 attempted, uint256 cap);
    // -------------------------
    // Rescue
    // -------------------------

    error RescueAmountZero();

    // -------------------------
    // Pause
    // -------------------------

    error TokenPaused();

    // -------------------------
    // Blacklist
    // -------------------------

    /// @dev Opération interdite car l'adresse est blacklistée
    error Blacklisted(address account);

    /// @dev Tentative de blacklister une adresse déjà blacklistée
    error AlreadyBlacklisted(address account);

    /// @dev Tentative d'opérer sur une adresse qui n'est PAS blacklistée
    ///      (ex: complianceBurn ou unblacklist)
    error NotBlacklisted(address account);

    error CannotRenounceLastRole(bytes32 role);

    error InsufficientBalance(address account, uint256 amount);
}
