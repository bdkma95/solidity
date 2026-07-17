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

    /// @dev Used for mint, burn, complianceBurn
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

    /// @dev Forbidden Operation because the address is blacklisted
    error Blacklisted(address account);

    /// @dev Attempt to blacklist an address that has already been blacklisted
    error AlreadyBlacklisted(address account);

    /// @dev Attempt to operate on an address that is NOT blacklisted
    ///      (ex: complianceBurn ou unblacklist)
    error NotBlacklisted(address account);

    error CannotRenounceLastRole(bytes32 role);

    error InsufficientBalance(address account, uint256 amount);

    /// @dev Error raised when a burn attempt is made from an address
    ///   which is not the authorized redemption address.
    /// @param attempted The address from which the burn was attempted.
    /// @param expected The expected redemption address.
    error BurnOnlyAllowedFromRedemptionAddress(address attempted, address expected);
    
    /// @dev Error raised when a burn attempt is made from an address
    ///   unauthorized (in the case of an address list).
    /// @param account The unauthorized address.
    error BurnNotAllowedFromAddress(address account);

}
