// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// =============================================================================
//  _____ ___  _   _ ____    ____   ___   ____
// |  ___/ _ \| \ | |  _ \  |  _ \ / _ \ / ___|
// | |_ | | | |  \| | | | | | |_) | | | | |
// |  _|| |_| | |\  | |_| | |  __/| |_| | |___
// |_|   \___/|_| \_|____/  |_|    \___/ \____|
//
//  Smart Contract TOKENIZED FUND — POC Phase 1  (v4.0 — EMT as cash / TokenizedISIN as shares)
//
//  ═══════════════════════════════════════════════════════════════════════════
//  WHAT CHANGES COMPARED TO v3.0
//  ═══════════════════════════════════════════════════════════════════════════
//
//  - The fund SHARES are no longer minted from EMT.sol. They are now the
//    tokens of the external contract TokenizedISIN.sol, an OpenZeppelin
//    ERC20 that also maintains the on-chain shareholder register (KYC
//    whitelist/blacklist, invested amounts, operation timestamps). The fund
//    calls sharesToken.mint()/burnFrom() to issue/destroy shares, and
//    forwards whitelistInvestor()/blacklistInvestor() calls to it.
//
//  - EMT.sol no longer represents fund shares: it now represents CASH (EUR)
//    on the ASSET side of the balance sheet. The fund calls
//    cashToken.mint()/burnFrom() whenever cash enters/leaves the fund, so
//    that EMT's ERC20 total supply always matches the fund's real cash
//    position. There is no more internal cash counter.
//
//  - The tokenized SECURITIES held in the portfolio are still represented
//    by the external contract TokenizedAssets.sol (formerly
//    ActifsTokenises.sol, simply translated). The fund holds these tokens
//    itself (address(this)) and calls assetToken.mint()/burn() when it
//    buys/sells securities.
//
//  - DEPLOYMENT PREREQUISITES (important):
//      1. Deploy EMT.sol                  → deployer becomes its "owner"
//      2. Deploy TokenizedAssets.sol       → deployer becomes its "owner"
//      3. Deploy TokenizedISIN.sol         → deployer gets DEFAULT_ADMIN_ROLE /
//                                             ADMIN_ROLE / COMPLIANCE_ROLE
//      4. Deploy TokenizedFundPOC.sol with the addresses of EMT,
//         TokenizedAssets and TokenizedISIN
//      5. Call EMT.transferOwnership(fundAddress)
//      6. Call TokenizedAssets.transferOwnership(fundAddress)
//      7. Call TokenizedISIN.grantRole(FUND_ROLE, fundAddress)
//      8. Call TokenizedISIN.grantRole(COMPLIANCE_ROLE, fundAddress)
//         → steps 7-8 let the fund mint/burn shares and maintain the
//           shareholder register (whitelist/blacklist) on investors' behalf
//      9. Call TokenizedFundPOC.initializeBalanceSheet() (ADMIN_ROLE, once)
//         → only at this point can the fund mint, since it must first have
//           become "owner"/role-holder on all three token contracts
//
//  ═══════════════════════════════════════════════════════════════════════════
//  FUND BALANCE SHEET AT T0 (after initializeBalanceSheet())
//  ═══════════════════════════════════════════════════════════════════════════
//
//  LIABILITIES (funding sources)
//  ┌─────────────────────────────────────────────────────────────────────┐
//  │  Initial subscription             +100 EUR (10 shares x 10 EUR)    │
//  │  Shares issued (TokenizedISIN)      10 shares                      │
//  │  Subscription price per share       10 EUR                         │
//  └─────────────────────────────────────────────────────────────────────┘
//
//  ASSETS (uses of capital)
//  ┌─────────────────────────────────────────────────────────────────────┐
//  │  Cash received at subscription    +100 EUR                          │
//  │  Investment in securities          -50 EUR (purchase of 50 units)   │
//  │  ─────────────────────────────────────────────────────────────────  │
//  │  Residual cash (EMT held by fund)   50 EUR                          │
//  │  TokenizedAssets held               50 units x 1 EUR = 50 EUR       │
//  │  ─────────────────────────────────────────────────────────────────  │
//  │  Total assets                       100 EUR                         │
//  └─────────────────────────────────────────────────────────────────────┘
//
//  NAV AT T0
//  ┌─────────────────────────────────────────────────────────────────────┐
//  │  Total NAV = Cash + (Assets x Asset_Price)                          │
//  │            = 50 + (50 x 1) = 100 EUR                                │
//  │  NAV/share = 100 EUR / 10 shares = 10 EUR per share                 │
//  └─────────────────────────────────────────────────────────────────────┘
//
//  ═══════════════════════════════════════════════════════════════════════
//  POC RULES (Phase 1) — unchanged
//  ═══════════════════════════════════════════════════════════════════════
//
//  [POC-1]  NO TOOLBOX — all logic is inline.
//  [POC-2]  NO FEES — neither entry, exit, nor management fees.
//  [POC-3]  A SINGLE ASSET whose unit price is ALWAYS 1 EUR.
//  [POC-4]  ORDERS IN WHOLE UNITS (EMT, TokenizedAssets and TokenizedISIN use
//           18 decimals natively, but this fund reasons in whole units:
//           1 "fund unit" = 1 whole token, no fractions).
//  [POC-5]  FIXED INVESTMENT STRATEGY: 50% of subscribed cash is invested
//           in securities, 50% remains in cash.
//  [POC-6]  INITIAL SUBSCRIPTION PRICE: 10 EUR per share.
//  [POC-7]  NAV CALCULATION: Total NAV = Cash + (Assets x ASSET_PRICE)
//  [POC-8]  BALANCE SHEET INVARIANT: Total assets == Total liabilities
//
//  What is KEPT from v3.0:
//  - CEI pattern (Checks-Effects-Interactions)
//  - ReentrancyGuard on all financial functions
//  - Shareholder register (whitelist / blacklist), now delegated to
//    TokenizedISIN so it also protects secondary transfers
//  - Immutable archival of every NAV cycle (keccak256 fingerprint)
//  - Events on all state mutations
//  - AccessControl (ADMIN, COMPLIANCE, AUDITOR)
//  - Emergency pause mechanism
//  - Integrity verification of past cycles (tamper-proof)
//
//  KNOWN LIMITATION OF THIS INTEGRATION (to document for Phase 2):
//  - EMT.sol being a standalone "in-house" ERC20 for cash, its transfer()
//    and transferFrom() functions do not go through this fund contract.
//    This is considered acceptable for cash (EMT never leaves the fund's
//    own wallet in this POC), but should be revisited in Phase 2 if EMT is
//    ever transferred directly between wallets outside of subscribe()/
//    redeem().
// =============================================================================

// =============================================================================
// OPENZEPPELIN LIBRARY IMPORTS (restricted — no more ERC20 inheritance here)
// =============================================================================

import "@openzeppelin/contracts/access/AccessControl.sol";
// AccessControl (RBAC): separation of ADMIN / COMPLIANCE / AUDITOR roles.

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// ReentrancyGuard: protection against re-entrancy attacks.
// Essential because this contract calls external contracts (EMT,
// TokenizedAssets, TokenizedISIN).

import "@openzeppelin/contracts/utils/Pausable.sol";
// Pausable (standalone, not ERC20Pausable): allows freezing subscribe()/
// redeem() in case of an anomaly. Does not freeze TokenizedISIN transfers
// directly (those are protected by TokenizedISIN's own Pausable/register).

// =============================================================================
// EXTERNAL TOKEN INTERFACES (EMT.sol and TokenizedAssets.sol)
// =============================================================================

/// @notice Minimal interface exposed by EMT.sol and TokenizedAssets.sol.
/// @dev Both contracts share exactly the same function signatures (mint,
///   burn, burnFrom, balanceOf, totalSupply, etc.), which allows using a
///   single interface to interact with either one.
interface IExternalToken {
    function mint(address to, uint256 amount) external returns (bool);
    function burn(uint256 amount) external returns (bool);
    function burnFrom(address from, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address tokenOwner, address spender) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function owner() external view returns (address);
}

/// @notice Minimal interface exposed by TokenizedISIN.sol — the fund SHARES
///   token, which also maintains the shareholder register.
/// @dev The struct layout below must mirror TokenizedISIN.ShareholderRecord
///   field-for-field: ABI encoding matches by structure, not by name, so
///   this local declaration decodes external calls correctly.
interface ITokenizedISIN {
    struct ShareholderRecord {
        address holder;
        uint256 sharesHeld;
        uint256 amountInvested;
        uint256 firstEntryTimestamp;
        uint256 lastOperationTimestamp;
        bool    isWhitelisted;
        bool    isBlacklisted;
    }

    function mint(address to, uint256 amount, uint256 investedAmount) external returns (bool);
    function burnFrom(address from, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function whitelistShareholder(address shareholder) external;
    function blacklistShareholder(address shareholder, string calldata reason) external;
    function getShareholderRecord(address shareholder) external view returns (ShareholderRecord memory);
    function shareholderCount() external view returns (uint256);
}

// =============================================================================
// SMART CONTRACT TOKENIZED FUND — POC PHASE 1 v4.0
// =============================================================================

contract TokenizedFundPOC is
    AccessControl,
    ReentrancyGuard,
    Pausable
{
    // =========================================================================
    // ROLES
    // =========================================================================

    /// @dev Administrator: deployment, pause, role management
    bytes32 public constant ADMIN_ROLE      = keccak256("ADMIN");

    /// @dev Compliance: whitelist / blacklist of investors
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE");

    /// @dev Auditor: read-only access to the register and NAV cycles
    bytes32 public constant AUDITOR_ROLE    = keccak256("AUDITOR");

    // =========================================================================
    // EXTERNAL TOKEN CONTRACTS
    // =========================================================================

    /// @notice EMT.sol contract — represents the fund's CASH (asset side).
    /// @dev The fund must be the "owner" of this contract to mint EMT when
    ///   cash enters the fund (subscription) and burn EMT when cash leaves
    ///   the fund (redemption), via mint() and burnFrom().
    IExternalToken public cashToken;

    /// @notice TokenizedAssets.sol contract — represents the tokenized
    ///   securities held in the fund's portfolio (asset side).
    /// @dev The fund must be the "owner" of this contract to mint securities
    ///   (purchase) and burn them (sale). The securities are held directly
    ///   by the fund (address(this)).
    IExternalToken public assetToken;

    /// @notice TokenizedISIN.sol contract — represents the fund SHARES
    ///   (liability side) and maintains the on-chain shareholder register.
    /// @dev The fund must hold FUND_ROLE (to mint/burn shares) and
    ///   COMPLIANCE_ROLE (to whitelist/blacklist investors) on this contract.
    ITokenizedISIN public sharesToken;

    /// @notice Common name of the fund (informative only, distinct from the
    ///   ERC20 name of the shares token).
    string public fundName;

    /// @notice True once initializeBalanceSheet() has been executed.
    /// @dev Prevents a double initialization of the T0 balance sheet.
    bool public isInitialized;

    // =========================================================================
    // POC BALANCE SHEET CONSTANTS
    // =========================================================================

    /// @notice [POC-3] Unit price of the tokenized security: always 1 EUR.
    uint256 public constant ASSET_PRICE = 1;

    /// @notice [POC-6] Initial subscription price per share: 10 EUR.
    uint256 public constant INITIAL_SUBSCRIPTION_PRICE = 10;

    /// @notice [POC-5] Investment ratio in securities: 50% of subscribed cash.
    uint256 public constant INVESTMENT_RATIO_PERCENT = 50;

    /// @notice [POC-6] Number of shares issued at initialization: 10 shares.
    uint256 public constant INITIAL_SHARES = 10;

    /// @notice [POC-6] Securities bought at initialization: 50 units.
    uint256 public constant INITIAL_ASSETS = 50;

    /// @notice [POC-6] Residual cash at initialization: 50 EUR.
    uint256 public constant INITIAL_CASH = 50;

    // =========================================================================
    // DATA STRUCTURES
    // =========================================================================

    /// @notice Full snapshot of a NAV cycle — archived immutably.
    struct NAVCycle {
        uint256 cycleNumber;          // Sequential number (0 = initial state)
        uint256 timestamp;            // Unix timestamp at cycle close
        uint256 navPerShare;          // NAV per share in EUR at close
        uint256 totalNAV;             // Total fund NAV in EUR (cash + assets)
        uint256 assetsHeld;           // TokenizedAssets held after the cycle
        uint256 cashAvailable;        // Cash (EMT) held by the fund after the cycle
        uint256 sharesOutstanding;    // Total TokenizedISIN shares outstanding after the cycle
        OperationType operationType;  // SUBSCRIPTION or REDEMPTION
        uint256 shareQuantity;        // Shares exchanged in this cycle
        uint256 assetsBought;         // Assets bought in this cycle (subscription)
        uint256 assetsSold;           // Assets sold in this cycle (redemption)
        address investor;             // Investor address
        bytes32 stateFingerprint;     // keccak256 hash of the state — tamper-proof
        bool    isFinalized;          // True once the cycle is irreversibly closed
    }

    // =========================================================================
    // ENUMERATIONS
    // =========================================================================

    enum OperationType {
        SUBSCRIPTION, // Investor entry: mint shares + mint securities
        REDEMPTION    // Investor exit: burn shares + burn securities
    }

    // =========================================================================
    // BALANCE SHEET STATE VARIABLES
    // =========================================================================

    /// @notice Cycle counter — starts at 1 (cycle 0 = initial state).
    uint256 private _currentCycleNumber;

    /// @notice Immutable history of NAV cycles: number => NAVCycle.
    mapping(uint256 => NAVCycle) private _navCycles;

    /// @notice Application-level lock: prevents re-entrancy at the NAV-cycle level.
    bool private _processingInProgress;

    // =========================================================================
    // EVENTS — IMMUTABLE ON-CHAIN TRACEABILITY
    // =========================================================================

    event NAVCycleClosed(
        uint256 indexed cycleNumber,
        OperationType operationType,
        address indexed investor,
        uint256 shareQuantity,
        uint256 assetsBought,
        uint256 assetsSold,
        uint256 cashAfter,
        uint256 assetsAfter,
        uint256 navPerShareAfter,
        bytes32 stateFingerprint,
        uint256 timestamp
    );

    event SubscriptionExecuted(
        address indexed investor,
        uint256 sharesIssued,
        uint256 amountSubscribed,
        uint256 assetsBought,
        uint256 cashRetained,
        uint256 navPerShareAfter,
        uint256 cycleNumber,
        uint256 timestamp
    );

    event RedemptionExecuted(
        address indexed investor,
        uint256 sharesRedeemed,
        uint256 amountRepaid,
        uint256 assetsSold,
        uint256 cashUsed,
        uint256 navPerShareAfter,
        uint256 cycleNumber,
        uint256 timestamp
    );

    event SecurityAlert(string description, address indexed trigger, uint256 timestamp);

    /// @notice Emitted when the T0 balance sheet is initialized (mint shares
    ///   + mint cash + mint assets).
    event FundInitialized(
        address indexed admin,
        uint256 initialShares,
        uint256 initialAssets,
        uint256 initialCash,
        uint256 timestamp
    );

    /// @notice Emitted at the very start of subscribe() or redeem(), as soon
    ///   as the order is received and BEFORE any processing (checks,
    ///   calculations, state mutations).
    /// @dev This timestamp is the official on-chain order-receipt time. It
    ///   can be used as a regulatory reference (cut-off).
    event OrderReceived(
        address indexed investor,      // Address that placed the order
        OperationType operationType,   // SUBSCRIPTION or REDEMPTION
        uint256 shareQuantity,         // Requested share quantity
        uint256 startTimestamp         // block.timestamp at order receipt
    );

    /// @notice Emitted at the very end of subscribe() or redeem(), after the
    ///   final mint/burn on the external cash/asset/shares contracts has
    ///   succeeded.
    /// @dev This timestamp marks the irreversible finalization of the
    ///   operation. The difference (startTimestamp → endTimestamp) can be
    ///   used to measure the processing time of a full NAV cycle.
    event OperationFinalized(
        address indexed investor,      // Address whose order was executed
        OperationType operationType,   // SUBSCRIPTION or REDEMPTION
        uint256 shareQuantity,         // Share quantity actually processed
        uint256 cycleNumber,           // Associated NAV cycle number
        uint256 endTimestamp           // block.timestamp after external interactions
    );

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier notProcessing() {
        require(
            !_processingInProgress,
            "POC: NAV cycle in progress - please retry after the cycle closes"
        );
        _;
    }

    /// @dev Guarantees that the T0 balance sheet has been initialized before
    ///   any operation.
    modifier onlyIfInitialized() {
        require(isInitialized, "POC: Fund not initialized - call initializeBalanceSheet() first");
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /// @notice Deploys the fund contract and links it to the EMT,
    ///   TokenizedAssets and TokenizedISIN contracts.
    /// @param fundName_ Official name of the fund (informative only).
    /// @param cashTokenAddress Address of the already-deployed EMT.sol contract (cash).
    /// @param assetTokenAddress Address of the already-deployed TokenizedAssets.sol contract (securities).
    /// @param sharesTokenAddress Address of the already-deployed TokenizedISIN.sol contract (shares/register).
    ///
    /// @dev The constructor performs NO mint: at this stage, this contract is
    ///   neither "owner" of EMT/TokenizedAssets nor a role-holder on
    ///   TokenizedISIN (these rights must be transferred/granted after
    ///   deployment). The T0 balance sheet is initialized via
    ///   initializeBalanceSheet().
    constructor(
        string memory fundName_,
        address cashTokenAddress,
        address assetTokenAddress,
        address sharesTokenAddress
    ) {
        require(bytes(fundName_).length > 0, "POC: Fund name is empty");
        require(cashTokenAddress != address(0), "POC: Invalid cash token address");
        require(assetTokenAddress != address(0), "POC: Invalid asset token address");
        require(sharesTokenAddress != address(0), "POC: Invalid shares token address");
        require(cashTokenAddress != assetTokenAddress, "POC: Cash and asset tokens must be distinct");

        fundName    = fundName_;
        cashToken   = IExternalToken(cashTokenAddress);
        assetToken  = IExternalToken(assetTokenAddress);
        sharesToken = ITokenizedISIN(sharesTokenAddress);

        // ─────────────────────────────────────────────────────────────────────
        // Founding role assignment
        // ─────────────────────────────────────────────────────────────────────
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE,         msg.sender);
        _grantRole(COMPLIANCE_ROLE,    msg.sender);
        _grantRole(AUDITOR_ROLE,       msg.sender);
    }

    // =========================================================================
    // T0 BALANCE SHEET INITIALIZATION (separate from the constructor)
    // =========================================================================

    /// @notice Initializes the fund's T0 balance sheet: mints EMT (cash),
    ///   TokenizedAssets (securities) and TokenizedISIN shares, and archives
    ///   NAV cycle 0.
    ///
    /// @dev Must be called EXACTLY ONCE by an ADMIN_ROLE account, and only
    ///   AFTER this contract has been made "owner" of cashToken/assetToken
    ///   and granted FUND_ROLE + COMPLIANCE_ROLE on sharesToken (otherwise
    ///   the mint() calls will revert with "caller is not authorized" /
    ///   "AccessControl: account is missing role").
    ///
    ///   Final T0 balance sheet:
    ///     Assets:      50 EUR cash + 50 assets x 1 EUR = 100 EUR
    ///     Liabilities: 10 shares x 10 EUR NAV           = 100 EUR
    ///     NAV/share = 100 / 10 = 10 EUR ✓
    function initializeBalanceSheet() external onlyRole(ADMIN_ROLE) {
        require(!isInitialized, "POC: Balance sheet already initialized");
        require(
            cashToken.owner() == address(this),
            "POC: This contract must own the cash token (call EMT.transferOwnership first)"
        );
        require(
            assetToken.owner() == address(this),
            "POC: This contract must own the asset token (call transferOwnership first)"
        );

        isInitialized = true;

        // ── Whitelist the deployer as the first shareholder ─────────────────
        sharesToken.whitelistShareholder(msg.sender);

        // ── INTERACTIONS — mint on the three external contracts ─────────────
        // The fund becomes the holder of the tokenized securities (fund's assets).
        assetToken.mint(address(this), INITIAL_ASSETS); // 50 units at 1 EUR
        // The fund mints EMT to itself to represent the residual cash held.
        cashToken.mint(address(this), INITIAL_CASH); // 50 EUR
        // The deployer receives the 10 initial shares (the fund's liabilities).
        sharesToken.mint(msg.sender, INITIAL_SHARES, INITIAL_SHARES * INITIAL_SUBSCRIPTION_PRICE);

        // ── Archival of NAV cycle 0 (T0 reference state) ─────────────────────
        uint256 navT0Total    = _computeTotalNAV();     // 50 + 50x1 = 100 EUR
        uint256 navT0PerShare = _computeNAVPerShare();  // 100 / 10  = 10 EUR

        bytes32 fingerprintT0 = _computeStateFingerprint(
            0,
            navT0PerShare,
            navT0Total,
            INITIAL_ASSETS,
            cashToken.balanceOf(address(this)),
            sharesToken.totalSupply()
        );

        _navCycles[0] = NAVCycle({
            cycleNumber:        0,
            timestamp:          block.timestamp,
            navPerShare:        navT0PerShare,
            totalNAV:           navT0Total,
            assetsHeld:         INITIAL_ASSETS,
            cashAvailable:      cashToken.balanceOf(address(this)),
            sharesOutstanding:  sharesToken.totalSupply(),
            operationType:      OperationType.SUBSCRIPTION,
            shareQuantity:      INITIAL_SHARES,
            assetsBought:       INITIAL_ASSETS,
            assetsSold:         0,
            investor:           msg.sender,
            stateFingerprint:   fingerprintT0,
            isFinalized:        true
        });

        _currentCycleNumber = 0;

        emit FundInitialized(
            msg.sender,
            INITIAL_SHARES,
            INITIAL_ASSETS,
            INITIAL_CASH,
            block.timestamp
        );

        emit NAVCycleClosed(
            0,
            OperationType.SUBSCRIPTION,
            msg.sender,
            INITIAL_SHARES,
            INITIAL_ASSETS,
            0,
            cashToken.balanceOf(address(this)),
            INITIAL_ASSETS,
            navT0PerShare,
            fingerprintT0,
            block.timestamp
        );
    }

    // =========================================================================
    // INVESTOR MANAGEMENT — WHITELIST / BLACKLIST (forwarded to TokenizedISIN)
    // =========================================================================

    /// @notice Whitelists an investor by forwarding the call to the
    ///   TokenizedISIN shareholder register.
    /// @dev Requires this fund contract to hold COMPLIANCE_ROLE on
    ///   sharesToken (see deployment prerequisites).
    function whitelistInvestor(address investor)
        external
        onlyRole(COMPLIANCE_ROLE)
        whenNotPaused
    {
        sharesToken.whitelistShareholder(investor);
    }

    /// @notice Blacklists an investor by forwarding the call to the
    ///   TokenizedISIN shareholder register.
    function blacklistInvestor(address investor, string calldata reason)
        external
        onlyRole(COMPLIANCE_ROLE)
    {
        sharesToken.blacklistShareholder(investor, reason);

        emit SecurityAlert(
            string(abi.encodePacked("Blacklisting: ", reason)),
            investor,
            block.timestamp
        );
    }

    // =========================================================================
    // SUBSCRIPTION — MINT SHARES (TokenizedISIN) + MINT CASH & ASSETS
    // =========================================================================

    /// @notice Subscribes N shares and applies the 50/50 investment strategy.
    /// @param shareAmount Whole number of shares to subscribe (>= 1).
    ///
    /// @dev Strict CEI pattern: all internal state mutations BEFORE the
    ///   external calls to assetToken.mint(), cashToken.mint() and
    ///   sharesToken.mint().
    function subscribe(uint256 shareAmount)
        external
        whenNotPaused
        nonReentrant
        notProcessing
        onlyIfInitialized
    {
        // =====================================================================
        // ORDER-RECEIPT TIMESTAMP — before any processing
        // =====================================================================
        // Emitted first, before business checks and state mutations.
        // Constitutes the official on-chain time of subscription order receipt.
        emit OrderReceived(msg.sender, OperationType.SUBSCRIPTION, shareAmount, block.timestamp);

        // =====================================================================
        // CHECKS
        // =====================================================================
        require(shareAmount >= 1, "POC: Share quantity must be a whole number >= 1");

        // =====================================================================
        // EFFECTS — All state modifications BEFORE interactions
        // =====================================================================
        _processingInProgress = true;

        uint256 cashIn         = shareAmount * INITIAL_SUBSCRIPTION_PRICE;
        uint256 cashInvested   = (cashIn * INVESTMENT_RATIO_PERCENT) / 100;
        uint256 assetsBought   = cashInvested / ASSET_PRICE;
        uint256 cashRetained   = cashIn - cashInvested;

        // ── NAV CYCLE ARCHIVAL ────────────────────────────────────────────────
        _currentCycleNumber += 1;
        uint256 cycleNumber = _currentCycleNumber;

        // "After" states computed from the external contracts' current
        // balances + the amounts that will be minted right after (CEI
        // pattern: interactions last, but the archive must reflect the
        // final state of the cycle).
        uint256 assetsAfter = assetToken.balanceOf(address(this)) + assetsBought;
        uint256 cashAfter    = cashToken.balanceOf(address(this)) + cashRetained;
        uint256 sharesAfter  = sharesToken.totalSupply() + shareAmount;

        uint256 totalNAVAfter   = cashAfter + (assetsAfter * ASSET_PRICE);
        uint256 navPerShareAfter = sharesAfter > 0
            ? totalNAVAfter / sharesAfter
            : INITIAL_SUBSCRIPTION_PRICE;

        bytes32 stateFingerprint = _computeStateFingerprint(
            cycleNumber,
            navPerShareAfter,
            totalNAVAfter,
            assetsAfter,
            cashAfter,
            sharesAfter
        );

        _navCycles[cycleNumber] = NAVCycle({
            cycleNumber:        cycleNumber,
            timestamp:          block.timestamp,
            navPerShare:        navPerShareAfter,
            totalNAV:           totalNAVAfter,
            assetsHeld:         assetsAfter,
            cashAvailable:      cashAfter,
            sharesOutstanding:  sharesAfter,
            operationType:      OperationType.SUBSCRIPTION,
            shareQuantity:      shareAmount,
            assetsBought:       assetsBought,
            assetsSold:         0,
            investor:           msg.sender,
            stateFingerprint:   stateFingerprint,
            isFinalized:        true
        });

        // ── EVENT EMISSION ────────────────────────────────────────────────────
        emit SubscriptionExecuted(
            msg.sender,
            shareAmount,
            cashIn,
            assetsBought,
            cashRetained,
            navPerShareAfter,
            cycleNumber,
            block.timestamp
        );

        emit NAVCycleClosed(
            cycleNumber,
            OperationType.SUBSCRIPTION,
            msg.sender,
            shareAmount,
            assetsBought,
            0,
            cashAfter,
            assetsAfter,
            navPerShareAfter,
            stateFingerprint,
            block.timestamp
        );

        // =====================================================================
        // INTERACTIONS — EXTERNAL calls last (CEI pattern)
        // =====================================================================
        // The fund buys securities: mint on TokenizedAssets, held by the fund.
        require(assetToken.mint(address(this), assetsBought), "POC: TokenizedAssets mint failed");
        // The fund mints EMT to itself to represent the cash retained.
        require(cashToken.mint(address(this), cashRetained), "POC: EMT mint failed");
        // The fund issues the new TokenizedISIN shares to the investor; the
        // shareholder register is updated atomically inside sharesToken.mint().
        require(sharesToken.mint(msg.sender, shareAmount, cashIn), "POC: TokenizedISIN mint failed");

        // =====================================================================
        // FINALIZATION TIMESTAMP — after all external interactions
        // =====================================================================
        // Emitted last, once the shares mint is confirmed on-chain.
        // Marks the instant from which the investor actually holds their shares.
        emit OperationFinalized(msg.sender, OperationType.SUBSCRIPTION, shareAmount, cycleNumber, block.timestamp);

        _processingInProgress = false;
    }

    // =========================================================================
    // REDEMPTION — BURN SHARES (TokenizedISIN) + BURN CASH & ASSETS
    // =========================================================================

    /// @notice Redeems N shares at the current NAV and returns the cash.
    /// @param shareAmount Whole number of shares to redeem (>= 1).
    function redeem(uint256 shareAmount)
        external
        whenNotPaused
        nonReentrant
        notProcessing
        onlyIfInitialized
    {
        // =====================================================================
        // ORDER-RECEIPT TIMESTAMP — before any processing
        // =====================================================================
        // Emitted first, before business checks and state mutations.
        // Constitutes the official on-chain time of redemption order receipt.
        emit OrderReceived(msg.sender, OperationType.REDEMPTION, shareAmount, block.timestamp);

        // =====================================================================
        // CHECKS
        // =====================================================================
        require(shareAmount >= 1, "POC: Share quantity must be a whole number >= 1");

        uint256 sharesOutstanding = sharesToken.totalSupply();
        require(
            sharesOutstanding > shareAmount,
            "POC: Full fund redemption is forbidden - use liquidation instead"
        );
        require(
            sharesToken.balanceOf(msg.sender) >= shareAmount,
            "POC: Insufficient share balance for this redemption"
        );

        // =====================================================================
        // EFFECTS — All state modifications BEFORE interactions
        // =====================================================================
        _processingInProgress = true;

        uint256 assetsBefore   = assetToken.balanceOf(address(this));
        uint256 cashBefore     = cashToken.balanceOf(address(this));
        uint256 totalNAVBefore = cashBefore + (assetsBefore * ASSET_PRICE);
        uint256 navPerShareBefore = sharesOutstanding > 0
            ? totalNAVBefore / sharesOutstanding
            : INITIAL_SUBSCRIPTION_PRICE;

        uint256 amountRepaid = shareAmount * navPerShareBefore;

        uint256 assetsValue = assetsBefore * ASSET_PRICE;

        uint256 assetsSold;
        uint256 cashUsed;

        if (totalNAVBefore > 0 && assetsValue > 0) {
            // Assets to sell = amount x assetsValue / totalNAVBefore / ASSET_PRICE
            assetsSold = (amountRepaid * assetsValue) / totalNAVBefore / ASSET_PRICE;
            cashUsed   = amountRepaid - (assetsSold * ASSET_PRICE);
        } else {
            assetsSold = 0;
            cashUsed   = amountRepaid;
        }

        require(assetsBefore >= assetsSold, "POC: Insufficient assets to honor the redemption");
        require(cashBefore >= cashUsed,      "POC: Insufficient cash to honor the redemption");

        // ── NAV CYCLE ARCHIVAL ────────────────────────────────────────────────
        _currentCycleNumber += 1;
        uint256 cycleNumber = _currentCycleNumber;

        uint256 assetsAfter = assetsBefore - assetsSold;
        uint256 cashAfter    = cashBefore - cashUsed;
        uint256 sharesAfter  = sharesOutstanding - shareAmount;
        uint256 totalNAVAfter   = cashAfter + (assetsAfter * ASSET_PRICE);
        uint256 navPerShareAfter = sharesAfter > 0
            ? totalNAVAfter / sharesAfter
            : 0;

        bytes32 stateFingerprint = _computeStateFingerprint(
            cycleNumber,
            navPerShareAfter,
            totalNAVAfter,
            assetsAfter,
            cashAfter,
            sharesAfter
        );

        _navCycles[cycleNumber] = NAVCycle({
            cycleNumber:        cycleNumber,
            timestamp:          block.timestamp,
            navPerShare:        navPerShareAfter,
            totalNAV:           totalNAVAfter,
            assetsHeld:         assetsAfter,
            cashAvailable:      cashAfter,
            sharesOutstanding:  sharesAfter,
            operationType:      OperationType.REDEMPTION,
            shareQuantity:      shareAmount,
            assetsBought:       0,
            assetsSold:         assetsSold,
            investor:           msg.sender,
            stateFingerprint:   stateFingerprint,
            isFinalized:        true
        });

        // ── EVENT EMISSION ────────────────────────────────────────────────────
        emit RedemptionExecuted(
            msg.sender,
            shareAmount,
            amountRepaid,
            assetsSold,
            cashUsed,
            navPerShareAfter,
            cycleNumber,
            block.timestamp
        );

        emit NAVCycleClosed(
            cycleNumber,
            OperationType.REDEMPTION,
            msg.sender,
            shareAmount,
            0,
            assetsSold,
            cashAfter,
            assetsAfter,
            navPerShareAfter,
            stateFingerprint,
            block.timestamp
        );

        // =====================================================================
        // INTERACTIONS — EXTERNAL calls last (CEI pattern)
        // =====================================================================
        // The fund sells securities: burns its own TokenizedAssets tokens.
        if (assetsSold > 0) {
            require(assetToken.burn(assetsSold), "POC: TokenizedAssets burn failed");
        }
        // The fund burns the EMT cash it pays out to the investor off-chain.
        if (cashUsed > 0) {
            require(cashToken.burnFrom(address(this), cashUsed), "POC: EMT burn failed");
        }
        // The fund destroys the investor's TokenizedISIN shares; the
        // shareholder register is updated atomically inside
        // sharesToken.burnFrom().
        require(sharesToken.burnFrom(msg.sender, shareAmount), "POC: TokenizedISIN burn failed");

        // =====================================================================
        // FINALIZATION TIMESTAMP — after all external interactions
        // =====================================================================
        // Emitted last, once the shares burn is confirmed on-chain. The EUR
        // reimbursement can be triggered off-chain by the custodian.
        emit OperationFinalized(msg.sender, OperationType.REDEMPTION, shareAmount, cycleNumber, block.timestamp);

        _processingInProgress = false;
    }

    // =========================================================================
    // NAV CALCULATION
    // =========================================================================

    /// @notice Computes the fund's total NAV in EUR.
    /// @dev [POC-7] Total NAV = Cash + (TokenizedAssets held x ASSET_PRICE)
    function computeTotalNAV() external view returns (uint256) {
        return _computeTotalNAV();
    }

    /// @notice Computes the NAV per share in EUR.
    /// @dev [POC-7] NAV/share = Total NAV / TokenizedISIN shares outstanding
    function computeNAVPerShare() external view returns (uint256) {
        return _computeNAVPerShare();
    }

    /// @notice Returns the fund's complete balance sheet state at this instant.
    function readFundBalanceSheet()
        external
        view
        returns (
            uint256 cash,
            uint256 assets,
            uint256 assetsValue,
            uint256 totalNAV,
            uint256 shares,
            uint256 navPerShare
        )
    {
        cash        = cashToken.balanceOf(address(this));
        assets      = assetToken.balanceOf(address(this));
        assetsValue = assets * ASSET_PRICE;
        totalNAV    = _computeTotalNAV();
        shares      = sharesToken.totalSupply();
        navPerShare = _computeNAVPerShare();
    }

    /// @notice Verifies the balance sheet invariant: assets == liabilities.
    function verifyBalanceSheet()
        external
        view
        returns (
            uint256 totalAssets,
            uint256 totalLiabilities,
            bool    balanced
        )
    {
        totalAssets      = _computeTotalNAV();
        totalLiabilities = sharesToken.totalSupply() * _computeNAVPerShare();
        balanced         = (totalAssets == totalLiabilities);
    }

    // =========================================================================
    // READ (VIEW) FUNCTIONS — AUDITABILITY
    // =========================================================================

    function readNAVCycle(uint256 cycleNumber) external view returns (NAVCycle memory) {
        return _navCycles[cycleNumber];
    }

    function readRegisterEntry(address investor)
        external
        view
        onlyRole(AUDITOR_ROLE)
        returns (ITokenizedISIN.ShareholderRecord memory)
    {
        return sharesToken.getShareholderRecord(investor);
    }

    /// @notice Returns the fund's global metrics.
    function readFundMetrics()
        external
        view
        returns (
            uint256 cashAvailable,
            uint256 assetsHeld,
            uint256 totalNAV,
            uint256 navPerShare,
            uint256 sharesOutstanding,
            uint256 cycleNumber,
            uint256 shareholderCount
        )
    {
        return (
            cashToken.balanceOf(address(this)),
            assetToken.balanceOf(address(this)),
            _computeTotalNAV(),
            _computeNAVPerShare(),
            sharesToken.totalSupply(),
            _currentCycleNumber,
            sharesToken.shareholderCount()
        );
    }

    /// @notice Verifies the cryptographic integrity of an archived NAV cycle.
    function verifyCycleIntegrity(uint256 cycleNumber)
        external
        view
        returns (
            bool    integrity,
            bytes32 computedFingerprint,
            bytes32 storedFingerprint
        )
    {
        NAVCycle storage cycle = _navCycles[cycleNumber];
        computedFingerprint = _computeStateFingerprint(
            cycle.cycleNumber,
            cycle.navPerShare,
            cycle.totalNAV,
            cycle.assetsHeld,
            cycle.cashAvailable,
            cycle.sharesOutstanding
        );
        storedFingerprint = cycle.stateFingerprint;
        integrity          = (computedFingerprint == storedFingerprint);
    }

    function currentCycleNumber() external view returns (uint256) {
        return _currentCycleNumber;
    }

    // =========================================================================
    // ADMINISTRATION
    // =========================================================================

    /// @notice Pauses the contract (emergency circuit breaker).
    /// @dev Blocks subscribe() and redeem().
    function pauseContract() external onlyRole(ADMIN_ROLE) {
        _pause();
        emit SecurityAlert("Contract paused", msg.sender, block.timestamp);
    }

    /// @notice Resumes the contract after a pause.
    function unpauseContract() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // =========================================================================
    // INTERNAL UTILITY FUNCTIONS
    // =========================================================================

    /// @notice Computes the fund's total NAV (internal logic).
    function _computeTotalNAV() internal view returns (uint256) {
        return cashToken.balanceOf(address(this)) + (assetToken.balanceOf(address(this)) * ASSET_PRICE);
    }

    /// @notice Computes the NAV per share (internal logic).
    function _computeNAVPerShare() internal view returns (uint256) {
        uint256 supply = sharesToken.totalSupply();
        if (supply == 0) return INITIAL_SUBSCRIPTION_PRICE;
        return _computeTotalNAV() / supply;
    }

    /// @notice Computes the tamper-proof keccak256 fingerprint of a full NAV state.
    function _computeStateFingerprint(
        uint256 cycleNumber,
        uint256 navPerShare,
        uint256 totalNAV,
        uint256 assetsHeld,
        uint256 cashParam,
        uint256 sharesOutstanding
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            cycleNumber,
            navPerShare,
            totalNAV,
            assetsHeld,
            cashParam,
            sharesOutstanding,
            address(this)
        ));
    }
}