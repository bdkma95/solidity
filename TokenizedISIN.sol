// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// =============================================================================
//  SMART CONTRACT TOKENIZED ISIN
// =============================================================================
//
//  Represents the LIABILITY side of the fund's balance sheet ("Gestion du
//  passif" in the architecture diagram): the fund SHARES themselves, i.e.
//  one ERC20 token per ISIN, together with the shareholder register that a
//  regulated fund is required to maintain.
//
//  This contract is the on-chain shareholder register:
//   - It inherits OpenZeppelin's ERC20 implementation for balances, transfers,
//     approvals, and total supply.
//   - It layers a shareholder register on top (whitelist / blacklist / KYC
//     status, first and last operation timestamps, cumulative amount
//     invested), and every mint/burn/transfer updates that register.
//   - Transfers are restricted to whitelisted, non-blacklisted addresses,
//     which closes the gap noted in the previous version of the fund
//     contract (direct peer-to-peer transfers used to bypass compliance
//     checks).
//
//  The FUND contract (TokenizedFundPOC) is expected to be granted FUND_ROLE
//  so it can mint new shares on subscription and burn shares on redemption.
//  Compliance actions (whitelist/blacklist) are granted COMPLIANCE_ROLE,
//  which in practice is also granted to the fund contract so that investors
//  can keep calling whitelistInvestor()/blacklistInvestor() directly on the
//  fund, which simply forwards the call here.
// =============================================================================

contract TokenizedISIN is ERC20, AccessControl, Pausable {
    // =========================================================================
    // ROLES
    // =========================================================================

    /// @dev Granted to the tokenized fund contract: allowed to mint/burn shares.
    bytes32 public constant FUND_ROLE = keccak256("FUND_ROLE");

    /// @dev Compliance officer: whitelist / blacklist of shareholders.
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    /// @dev Administrator: pause/unpause, role management.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // =========================================================================
    // ISIN IDENTIFICATION
    // =========================================================================

    /// @notice ISIN code represented by this contract (purely informative).
    string public isin;

    // =========================================================================
    // SHAREHOLDER REGISTER
    // =========================================================================

    /// @notice One entry of the on-chain shareholder register.
    struct ShareholderRecord {
        address holder;                 // Blockchain address of the shareholder
        uint256 sharesHeld;              // Shares held (kept in sync with balanceOf)
        uint256 amountInvested;          // Total amount invested in EUR (cumulative)
        uint256 firstEntryTimestamp;     // Timestamp of the first subscription
        uint256 lastOperationTimestamp;  // Timestamp of the last operation
        bool    isWhitelisted;           // True once KYC has been validated
        bool    isBlacklisted;           // True if under regulatory freeze
    }

    /// @notice Shareholder register: address => ShareholderRecord.
    mapping(address => ShareholderRecord) private _register;

    /// @notice Ordered list of shareholder addresses (for audit iteration).
    address[] private _shareholders;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event ShareholderWhitelisted(address indexed shareholder, uint256 timestamp);
    event ShareholderBlacklisted(address indexed shareholder, string reason, uint256 timestamp);

    event RegisterUpdated(
        address indexed shareholder,
        uint256 previousSharesBalance,
        uint256 newSharesBalance,
        string  reason,
        uint256 timestamp
    );

    event SharesMinted(address indexed to, uint256 amount, uint256 investedAmount, uint256 timestamp);
    event SharesBurned(address indexed from, uint256 amount, uint256 timestamp);

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyWhitelisted(address account) {
        // Blacklist is checked FIRST: a blacklisted account always has
        // isWhitelisted == false (see blacklistShareholder), so checking
        // whitelist first would always report "not whitelisted" and mask
        // the real reason. Checking blacklist first gives the accurate
        // error message.
        require(!_register[account].isBlacklisted, "TokenizedISIN: account is blacklisted");
        require(_register[account].isWhitelisted, "TokenizedISIN: account not whitelisted");
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /// @param name_ ERC20 name of the share token (e.g. "Fund XYZ Shares").
    /// @param symbol_ ERC20 symbol of the share token (e.g. "XYZ").
    /// @param isin_ ISIN code represented by this contract (informative).
    /// @param admin Address receiving DEFAULT_ADMIN_ROLE / ADMIN_ROLE / COMPLIANCE_ROLE
    ///   at deployment. This is typically the deployer, who will later grant
    ///   FUND_ROLE to the tokenized fund contract.
    constructor(
        string memory name_,
        string memory symbol_,
        string memory isin_,
        address admin
    ) ERC20(name_, symbol_) {
        require(admin != address(0), "TokenizedISIN: invalid admin address");
        isin = isin_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE,         admin);
        _grantRole(COMPLIANCE_ROLE,    admin);
    }

    // =========================================================================
    // SHAREHOLDER REGISTER MANAGEMENT — WHITELIST / BLACKLIST
    // =========================================================================

    /// @notice Whitelists an investor (KYC validated) and creates a register
    ///   entry for them if this is their first appearance in the register.
    function whitelistShareholder(address shareholder)
        external
        onlyRole(COMPLIANCE_ROLE)
        whenNotPaused
    {
        require(shareholder != address(0), "TokenizedISIN: invalid shareholder address");
        require(
            !_register[shareholder].isBlacklisted,
            "TokenizedISIN: cannot whitelist a blacklisted shareholder"
        );

        bool isNew = (_register[shareholder].firstEntryTimestamp == 0);

        if (isNew) {
            _register[shareholder] = ShareholderRecord({
                holder:                shareholder,
                sharesHeld:            0,
                amountInvested:        0,
                firstEntryTimestamp:   block.timestamp,
                lastOperationTimestamp: block.timestamp,
                isWhitelisted:         true,
                isBlacklisted:         false
            });
            _shareholders.push(shareholder);
        } else {
            _register[shareholder].isWhitelisted = true;
        }

        emit ShareholderWhitelisted(shareholder, block.timestamp);
    }

    /// @notice Blacklists an investor (regulatory freeze). Blocks future
    ///   mints, burns, and transfers involving this address.
    function blacklistShareholder(address shareholder, string calldata reason)
        external
        onlyRole(COMPLIANCE_ROLE)
    {
        require(shareholder != address(0), "TokenizedISIN: invalid address");
        require(bytes(reason).length > 0,  "TokenizedISIN: reason required for blacklisting");

        _register[shareholder].isBlacklisted = true;
        _register[shareholder].isWhitelisted = false;

        emit ShareholderBlacklisted(shareholder, reason, block.timestamp);
    }

    // =========================================================================
    // MINT / BURN — RESTRICTED TO THE FUND CONTRACT (FUND_ROLE)
    // =========================================================================

    /// @notice Mints new shares to an investor and updates their register
    ///   entry (invested amount, operation timestamps).
    /// @dev Called by the fund contract during subscribe().
    function mint(address to, uint256 amount, uint256 investedAmount)
        external
        onlyRole(FUND_ROLE)
        whenNotPaused
        onlyWhitelisted(to)
        returns (bool)
    {
        uint256 previousBalance = balanceOf(to);

        ShareholderRecord storage record = _register[to];
        record.sharesHeld            += amount;
        record.amountInvested        += investedAmount;
        record.lastOperationTimestamp = block.timestamp;

        _mint(to, amount);

        emit SharesMinted(to, amount, investedAmount, block.timestamp);
        emit RegisterUpdated(to, previousBalance, balanceOf(to), "SUBSCRIPTION", block.timestamp);
        return true;
    }

    /// @notice Burns shares from an investor and updates their register entry.
    /// @dev Called by the fund contract during redeem().
    function burnFrom(address from, uint256 amount)
        external
        onlyRole(FUND_ROLE)
        whenNotPaused
        returns (bool)
    {
        require(!_register[from].isBlacklisted, "TokenizedISIN: shareholder is blacklisted");

        uint256 previousBalance = balanceOf(from);

        ShareholderRecord storage record = _register[from];
        record.sharesHeld             = previousBalance >= amount ? previousBalance - amount : 0;
        record.lastOperationTimestamp = block.timestamp;

        _burn(from, amount);

        emit SharesBurned(from, amount, block.timestamp);
        emit RegisterUpdated(from, previousBalance, balanceOf(from), "REDEMPTION", block.timestamp);
        return true;
    }

    // =========================================================================
    // TRANSFER RESTRICTIONS (OpenZeppelin v5 hook)
    // =========================================================================

    /// @dev Enforces the shareholder register on every balance movement,
    ///   including direct peer-to-peer transfers (unlike the previous
    ///   architecture, where secondary transfers of fund shares could
    ///   bypass compliance checks).
    ///   - Minting (from == address(0)) and burning (to == address(0)) are
    ///     handled by mint()/burnFrom() above, which already check the
    ///     register, so they are allowed to pass through here.
    ///   - Direct transfers between two shareholders require both sides to
    ///     be whitelisted and neither to be blacklisted.
    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        bool isMint = (from == address(0));
        bool isBurn = (to == address(0));

        if (!isMint && !isBurn) {
            require(!_register[from].isBlacklisted, "TokenizedISIN: sender is blacklisted");
            require(!_register[to].isBlacklisted,   "TokenizedISIN: recipient is blacklisted");
            require(_register[from].isWhitelisted,  "TokenizedISIN: sender not whitelisted");
            require(_register[to].isWhitelisted,    "TokenizedISIN: recipient not whitelisted");

            uint256 previousFromBalance = balanceOf(from);
            uint256 previousToBalance   = balanceOf(to);

            super._update(from, to, value);

            _register[from].sharesHeld = balanceOf(from);
            _register[to].sharesHeld   = balanceOf(to);
            _register[from].lastOperationTimestamp = block.timestamp;
            _register[to].lastOperationTimestamp   = block.timestamp;

            emit RegisterUpdated(from, previousFromBalance, balanceOf(from), "TRANSFER_OUT", block.timestamp);
            emit RegisterUpdated(to,   previousToBalance,   balanceOf(to),   "TRANSFER_IN",  block.timestamp);
            return;
        }

        super._update(from, to, value);
    }

    // =========================================================================
    // READ FUNCTIONS — AUDITABILITY
    // =========================================================================

    /// @notice Returns the full register entry for a given shareholder.
    function getShareholderRecord(address shareholder) external view returns (ShareholderRecord memory) {
        return _register[shareholder];
    }

    /// @notice Returns the number of distinct addresses ever recorded in the register.
    function shareholderCount() external view returns (uint256) {
        return _shareholders.length;
    }

    /// @notice Returns the shareholder address at a given index (for iteration).
    function shareholderAt(uint256 index) external view returns (address) {
        return _shareholders[index];
    }

    // =========================================================================
    // ADMINISTRATION
    // =========================================================================

    function pauseContract() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpauseContract() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @dev Required override: both AccessControl and ERC20 do not conflict,
    ///   but Solidity requires this contract to declare it supports the
    ///   combined interface set explicitly when multiple bases are used.
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
