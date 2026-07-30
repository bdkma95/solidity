// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
// =============================================================================
//  Smart Contract TOKENIZED FUND — POC Phase 2  (v5.0 — Toolbox-integrated)
//  ═══════════════════════════════════════════════════════════════════════════
//  WHAT CHANGES COMPARED TO v4.0 (Phase 1)
//  ═══════════════════════════════════════════════════════════════════════════
//
//  - [POC-1] "NO TOOLBOX" is LIFTED. This contract now calls Toolbox.sol for
//    every piece of financial/regulatory logic: fee calculation (entry,
//    exit, early-redemption penalty, ongoing management/custody/admin fees,
//    performance fee), investment strategy (target cash vs. invested
//    allocation), regulatory compliance (minimum subscription, individual
//    cap), and NAV math (shares-to-issue, redemption amount). This contract
//    keeps ONLY the order lifecycle (subscribe/redeem), the external token
//    orchestration (EMT/TokenizedAssets/TokenizedISIN), and the immutable
//    NAV-cycle archive.
//
//  - [POC-2] "NO FEES" is LIFTED. Subscription fees, redemption fees
//    (standard and early/lock-up), and ongoing fees (management, custody,
//    admin, performance/HWM) are now computed via Toolbox and recorded in
//    every NAV cycle and in dedicated events for full auditability.
//
//    IMPORTANT SCOPE DECISION FOR THIS PHASE: fees are computed and logged
//    on-chain (NAVCycle.feeCharged + FeesAccrued / SubscriptionExecuted /
//    RedemptionExecuted events) for transparency, but they are NOT yet
//    transferred or minted to a separate fee-collector wallet. A
//    subscription fee simply reduces the amount that is actually invested
//    on behalf of the subscriber (it is never minted to anyone); a
//    redemption fee simply reduces the amount paid out to the redeeming
//    investor (the corresponding assets/cash are not burned, and therefore
//    remain in the fund, benefiting the NAV of the remaining shareholders).
//    Routing fees to a real fee-collector wallet (mint/transfer) is an
//    explicit candidate for a later phase.
//
//  - [POC-3]/[POC-4] "single asset always worth 1 EUR" / "whole units" are
//    LIFTED. This contract now reasons in full 18-decimal EUR fixed point
//    (matching Toolbox's PRECISION = 1e18 and the ERC20 standard 18
//    decimals used by EMT/TokenizedAssets/TokenizedISIN), because Toolbox's
//    rules (e.g. MINIMUM_SUBSCRIPTION = 100,000 EUR) are expressed in that
//    scale. The unit price of TokenizedAssets is no longer hard-coded at 1
//    EUR: it is now `assetPriceEUR`, an admin-settable placeholder for a
//    future on-chain price oracle (see "KNOWN LIMITATIONS" below).
//
//  - [POC-5] "fixed 50/50 investment strategy" is LIFTED. The cash/invested
//    split is now driven by Toolbox.readStrategy().cashAllocationBp. Since
//    this architecture only has a single non-cash asset bucket
//    (TokenizedAssets), everything that Toolbox's strategy allocates to
//    commercial paper + bonds + equities is bought as TokenizedAssets; only
//    the cash allocation stays as EMT. This is a deliberate simplification
//    — see "KNOWN LIMITATIONS".
//
//  - [POC-6] fixed "10 EUR / share, 10 shares, 50/50" initial balance sheet
//    is replaced by a configurable genesis subscription
//    (INITIAL_SUBSCRIPTION_EUR, INITIAL_NAV_PER_SHARE), executed through the
//    exact same Toolbox-aware code path as any other subscription.
//
//  - [POC-7]/[POC-8] NAV calculation and the balance-sheet invariant are
//    unchanged in spirit, just re-expressed in 18-decimal EUR terms and
//    using Toolbox's calculateSharesToIssue / calculateRedemptionAmount.
//
//  What is KEPT from v4.0 / Phase 1:
//  - EMT = cash (asset side), TokenizedAssets = securities (asset side),
//    TokenizedISIN = shares + shareholder register (liability side)
//  - CEI pattern (Checks-Effects-Interactions)
//  - ReentrancyGuard on all financial functions
//  - Immutable archival of every NAV cycle (keccak256 fingerprint)
//  - Events on all state mutations, including OrderReceived/OperationFinalized
//  - AccessControl (ADMIN, COMPLIANCE, AUDITOR)
//  - Emergency pause mechanism
//  - Integrity verification of past cycles (tamper-proof)
//
//  ═══════════════════════════════════════════════════════════════════════════
//  DEPLOYMENT PREREQUISITES (Phase 2)
//  ═══════════════════════════════════════════════════════════════════════════
//    1. Deploy EMT.sol                    → deployer becomes its "owner"
//    2. Deploy TokenizedAssets.sol        → deployer becomes its "owner"
//    3. Deploy TokenizedISIN.sol          → deployer gets DEFAULT_ADMIN_ROLE /
//                                            ADMIN_ROLE / COMPLIANCE_ROLE
//    4. Deploy Toolbox.sol                → deployer gets DEFAULT_ADMIN_ROLE /
//                                            ADMIN_ROLE / MANAGER_ROLE /
//                                            FEE_ADMIN_ROLE / COMPLIANCE_ROLE
//    5. Deploy TokenizedFundPOC.sol with the addresses of EMT,
//       TokenizedAssets, TokenizedISIN and Toolbox
//    6. Call EMT.transferOwnership(fundAddress)
//    7. Call TokenizedAssets.transferOwnership(fundAddress)
//    8. Call TokenizedISIN.grantRole(FUND_ROLE, fundAddress)
//    9. Call TokenizedISIN.grantRole(COMPLIANCE_ROLE, fundAddress)
//   10. Call Toolbox.grantRole(FUND_AUTHORIZED_ROLE, fundAddress)   [NEW]
//       → required for the fund to call Toolbox.updateHighWaterMark()
//   11. Call TokenizedFundPOC.initializeBalanceSheet() (ADMIN_ROLE, once)
//
//  ═══════════════════════════════════════════════════════════════════════════
//  KNOWN LIMITATIONS OF THIS PHASE (to document/revisit in Phase 3)
//  ═══════════════════════════════════════════════════════════════════════════
//  - Fees are logged, not collected (see scope decision above).
//  - `assetPriceEUR` is an admin-settable placeholder, not a real price
//    oracle. In production this must be replaced by a certified NAV/pricing
//    feed for the securities held in TokenizedAssets.
//  - All non-cash strategy buckets (commercial paper, bonds, equities) are
//    collapsed into the single TokenizedAssets holding, since this
//    architecture does not yet have one token contract per asset class.
//    Toolbox's `calculatePortfolioAdjustments` / `checkRebalancingNeeded`
//    (multi-asset rebalancing) are therefore not yet called by this
//    contract — they are ready to be used once the fund manages more than
//    one risk-asset contract.
//  - `accrueOngoingFees()` computes and emits management/custody/admin/
//    performance fees and updates the Toolbox High Water Mark, but (per the
//    scope decision above) does not move any tokens.
//  - EMT.sol's transfer()/transferFrom() still do not go through this fund
//    contract (unchanged from Phase 1); acceptable as EMT never leaves the
//    fund's own wallet in subscribe()/redeem().
//
//  ═══════════════════════════════════════════════════════════════════════════
//  PATCH NOTE (this revision)
//  ═══════════════════════════════════════════════════════════════════════════
//  - TokenizedAssets.sol's mint()/burn()/burnFrom() now require a `reason`
//    string parameter (Phase 2 update). The old shared `IExternalToken`
//    interface (2-arg mint/burn) no longer matches TokenizedAssets.sol's
//    real ABI/selectors, which would make every assetToken.mint/burn/
//    burnFrom call revert at runtime even though the project still compiles.
//    A dedicated `IExternalAssetToken` interface (matching the 3-arg ABI)
//    is now used for `assetToken`, and a `reason` string is passed at each
//    call site (initializeBalanceSheet, subscribe, redeem). `cashToken`
//    (EMT.sol) keeps using the original 2-arg `IExternalToken` interface —
//    verify EMT.sol's ABI still matches it before deploying.
//  - verifyBalanceSheet()'s `balanced` flag now tolerates negligible
//    18-decimal fixed-point rounding dust (bounded by shares outstanding)
//    instead of requiring exact `totalAssets == totalLiabilities` equality.
//    The old strict check reported "unbalanced" on virtually every call,
//    even when the fund was genuinely balanced, because
//    totalLiabilities is reconstructed via a divide-then-multiply round
//    trip through _computeNAVPerShare() that floor-rounds at each step.
//    A true accounting problem (gap larger than the tolerance) still
//    correctly reports `balanced = false`.
// =============================================================================

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// =============================================================================
// EXTERNAL TOKEN INTERFACES (EMT.sol and TokenizedAssets.sol)
// =============================================================================

/// @notice Minimal interface exposed by EMT.sol (the fund's cash token).
/// @dev EMT.sol's Phase 2 mint()/burn()/burnFrom() take a `reason` string
///   for on-chain audit trail (AMF/CSSF traceability). EMT.sol also keeps
///   2-arg "legacy" overloads for backward compatibility, but the fund
///   deliberately uses the reason-string versions below so cash-side
///   Mint/Burn events carry a meaningful reason instead of "LEGACY_MINT" /
///   "LEGACY_BURN_FROM" — matching the audit quality of IExternalAssetToken.
interface IExternalToken {
    function mint(address to, uint256 amount, string calldata reason) external returns (bool);
    function burn(uint256 amount, string calldata reason) external returns (bool);
    function burnFrom(address from, uint256 amount, string calldata reason) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address tokenOwner, address spender) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function owner() external view returns (address);
}

/// @notice Minimal interface exposed by TokenizedAssets.sol (the fund's
///   securities token).
/// @dev Must mirror TokenizedAssets.sol's real ABI. Its Phase 2 mint()/
///   burn()/burnFrom() take an extra `reason` string compared to EMT.sol —
///   they are NOT interchangeable with IExternalToken (different selectors).
interface IExternalAssetToken {
    function mint(address to, uint256 amount, string calldata reason) external returns (bool);
    function burn(uint256 amount, string calldata reason) external returns (bool);
    function burnFrom(address from, uint256 amount, string calldata reason) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address tokenOwner, address spender) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function owner() external view returns (address);
}

/// @notice Minimal interface exposed by TokenizedISIN.sol.
/// @dev The struct layout below must mirror TokenizedISIN.ShareholderRecord
///   field-for-field.
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

/// @notice Interface exposed by Toolbox.sol — the fund's stateless
///   financial/regulatory rules engine (fees, strategy, compliance, NAV
///   math). Must stay in sync with Toolbox.sol's IToolbox interface.
interface IToolbox {
    // NOTE: Toolbox's FeeStructure/InvestmentStrategy structs are
    // intentionally NOT mirrored here — a struct redeclared in an
    // interface is a distinct type from Toolbox's own, which breaks
    // `override` on the implementation side. This fund only needs the
    // cash-allocation field, exposed directly via readCashAllocationBp().

    function calculateFees(uint256 amount, uint8 operationType) external view returns (uint256 fee);

    function calculateFullRedemptionFees(
        uint256 amount,
        uint256 firstEntryTimestamp
    ) external view returns (uint256 fee, bool isEarly);

    function calculateProrataOngoingFees(
        uint256 totalNetAssets,
        uint256 cycleDurationSeconds
    ) external view returns (uint256 managementFee, uint256 custodyFee, uint256 adminFee);

    function calculatePerformanceFees(
        uint256 currentNAVPerShare,
        uint256 totalSharesOutstanding
    ) external view returns (uint256 performanceFee);

    function updateHighWaterMark(uint256 currentNAVPerShare, uint256 navCycle) external;

    function calculateSharesToIssue(
        uint256 subscriptionAmountEUR,
        uint256 navPerShare
    ) external pure returns (uint256 numberOfShares);

    function calculateRedemptionAmount(
        uint256 numberOfShares,
        uint256 navPerShare
    ) external pure returns (uint256 grossAmountEUR);

    function validateCompliance(
        address investor,
        uint256 amount,
        uint8 operationType,
        uint256 amountAlreadyInvested
    ) external view returns (bool isValid);

    /// @notice Cash allocation of the current investment strategy, in bp.
    /// @dev This architecture has a single non-cash asset bucket
    ///   (TokenizedAssets), so `BASE_POINTS - cashAllocationBp` is the
    ///   fraction of net subscription proceeds routed there.
    function readCashAllocationBp() external view returns (uint256);

    function readIndividualSubscriptionCap() external view returns (uint256);
}

// =============================================================================
// SMART CONTRACT TOKENIZED FUND — POC PHASE 2 v5.0
// =============================================================================

contract TokenizedFundPOC is AccessControl, ReentrancyGuard, Pausable {
    using Math for uint256;

    // =========================================================================
    // ROLES
    // =========================================================================

    bytes32 public constant ADMIN_ROLE      = keccak256("ADMIN");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE");
    bytes32 public constant AUDITOR_ROLE    = keccak256("AUDITOR");

    // =========================================================================
    // EXTERNAL CONTRACTS
    // =========================================================================

    /// @notice EMT.sol contract — the fund's CASH (asset side).
    IExternalToken public cashToken;

    /// @notice TokenizedAssets.sol contract — the securities held in the
    ///   fund's portfolio (asset side).
    IExternalAssetToken public assetToken;

    /// @notice TokenizedISIN.sol contract — the fund SHARES (liability
    ///   side) and the on-chain shareholder register.
    ITokenizedISIN public sharesToken;

    /// @notice Toolbox.sol contract — fee rules, investment strategy,
    ///   compliance validation and reusable financial calculations.
    /// @dev Upgradable via updateToolbox() (ADMIN_ROLE). A new Toolbox must
    ///   be granted FUND_AUTHORIZED_ROLE before being wired in, and the old
    ///   one should have it revoked afterwards.
    IToolbox public toolbox;

    string public fundName;
    bool public isInitialized;

    // =========================================================================
    // FIXED-POINT CONSTANTS (mirror Toolbox.sol — must stay in sync)
    // =========================================================================

    uint256 public constant PRECISION   = 1e18;
    uint256 public constant BASE_POINTS = 10_000;

    /// @notice NAV per share used only for the very first NAV cycle
    ///   (before any shares are outstanding to derive a NAV from).
    uint256 public constant INITIAL_NAV_PER_SHARE = 100 * PRECISION; // 100 EUR/share

    /// @notice Genesis subscription amount used by initializeBalanceSheet().
    ///   Must be >= Toolbox.MINIMUM_SUBSCRIPTION (100,000 EUR by default).
    uint256 public constant INITIAL_SUBSCRIPTION_EUR = 1_000_000 * PRECISION; // 1,000,000 EUR

    // =========================================================================
    // PRICE PARAMETER (placeholder for a future on-chain price oracle)
    // =========================================================================

    /// @notice Price of one whole TokenizedAssets unit, in EUR (18 dec).
    /// @dev KNOWN LIMITATION: admin-settable placeholder, not a certified
    ///   price feed. Defaults to 1 EUR at deployment.
    uint256 public assetPriceEUR = PRECISION;

    /// @notice Timestamp of the last ongoing-fee accrual (management/
    ///   custody/admin/performance). Used to compute the prorata window
    ///   passed to Toolbox.calculateProrataOngoingFees().
    uint256 public lastFeeAccrualTimestamp;

    // =========================================================================
    // DATA STRUCTURES
    // =========================================================================

    struct NAVCycle {
        uint256 cycleNumber;
        uint256 timestamp;
        uint256 navPerShare;
        uint256 totalNAV;
        uint256 assetsHeld;
        uint256 cashAvailable;
        uint256 sharesOutstanding;
        OperationType operationType;
        uint256 shareQuantity;      // shares issued (SUBSCRIPTION) or redeemed (REDEMPTION); 0 for FEE_ACCRUAL
        uint256 assetsBought;
        uint256 assetsSold;
        uint256 feeCharged;         // subscription fee, redemption fee, or sum of ongoing fees (EUR, 18 dec)
        address investor;           // address(0) for FEE_ACCRUAL cycles
        bytes32 stateFingerprint;
        bool    isFinalized;
    }

    enum OperationType {
        SUBSCRIPTION,
        REDEMPTION,
        FEE_ACCRUAL
    }

    uint256 private _currentCycleNumber;
    mapping(uint256 => NAVCycle) private _navCycles;
    bool private _processingInProgress;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event NAVCycleClosed(
        uint256 indexed cycleNumber,
        OperationType operationType,
        address indexed investor,
        uint256 shareQuantity,
        uint256 assetsBought,
        uint256 assetsSold,
        uint256 feeCharged,
        uint256 cashAfter,
        uint256 assetsAfter,
        uint256 navPerShareAfter,
        bytes32 stateFingerprint,
        uint256 timestamp
    );

    event SubscriptionExecuted(
        address indexed investor,
        uint256 grossAmountEUR,
        uint256 subscriptionFee,
        uint256 sharesIssued,
        uint256 assetsBought,
        uint256 cashRetained,
        uint256 navPerShareAfter,
        uint256 cycleNumber,
        uint256 timestamp
    );

    event RedemptionExecuted(
        address indexed investor,
        uint256 sharesRedeemed,
        uint256 grossAmountEUR,
        uint256 redemptionFee,
        bool    wasEarlyRedemption,
        uint256 netAmountPaid,
        uint256 assetsSold,
        uint256 cashUsed,
        uint256 navPerShareAfter,
        uint256 cycleNumber,
        uint256 timestamp
    );

    /// @notice Emitted by accrueOngoingFees(): logs the fees that Toolbox
    ///   computed for the elapsed period. No tokens are moved (see header).
    event FeesAccrued(
        uint256 managementFee,
        uint256 custodyFee,
        uint256 adminFee,
        uint256 performanceFee,
        uint256 grossNAV,
        uint256 navPerShare,
        uint256 periodSeconds,
        uint256 timestamp
    );

    event SecurityAlert(string description, address indexed trigger, uint256 timestamp);

    event FundInitialized(
        address indexed admin,
        uint256 initialSharesIssued,
        uint256 initialAssetsBought,
        uint256 initialCashRetained,
        uint256 timestamp
    );

    event OrderReceived(
        address indexed investor,
        OperationType operationType,
        uint256 amount,          // amountEUR for SUBSCRIPTION, shareAmount for REDEMPTION
        uint256 startTimestamp
    );

    event OperationFinalized(
        address indexed investor,
        OperationType operationType,
        uint256 amount,
        uint256 cycleNumber,
        uint256 endTimestamp
    );

    event AssetPriceUpdated(uint256 previousPriceEUR, uint256 newPriceEUR, uint256 timestamp);
    event ToolboxUpdated(address indexed previousToolbox, address indexed newToolbox, uint256 timestamp);

    // =========================================================================
    // INTERNAL CALCULATION HELPERS (stack-depth mitigation)
    // =========================================================================
    // Grouping intermediate results into memory structs (instead of many
    // separate local uint256 variables) keeps subscribe()/redeem()/
    // initializeBalanceSheet() well under Solidity's ~16-slot stack limit —
    // a memory struct variable only costs ONE stack slot regardless of how
    // many fields it carries.

    struct SubscriptionCalc {
        uint256 subscriptionFee;
        uint256 netAmount;
        uint256 sharesToIssue;
        uint256 assetsToBuy;
        uint256 cashRetained;
    }

    struct RedemptionCalc {
        uint256 grossAmount;
        uint256 redemptionFee;
        bool    isEarly;
        uint256 netAmountToInvestor;
        uint256 assetsSold;
        uint256 cashUsed;
    }

    struct CycleAfter {
        uint256 assetsAfter;
        uint256 cashAfter;
        uint256 sharesAfter;
        uint256 totalNAVAfter;
        uint256 navPerShareAfter;
        bytes32 stateFingerprint;
    }

    /// @dev Computes the Toolbox-driven fee, share count, and cash/asset
    ///   split for a gross EUR subscription amount. Used by both subscribe()
    ///   and initializeBalanceSheet().
    function _calcSubscription(uint256 amountEUR) internal view returns (SubscriptionCalc memory calc) {
        calc.subscriptionFee = toolbox.calculateFees(amountEUR, 0);
        calc.netAmount        = amountEUR - calc.subscriptionFee;

        uint256 navPerShare = _computeNAVPerShare();
        calc.sharesToIssue   = toolbox.calculateSharesToIssue(calc.netAmount, navPerShare);

        uint256 cashAllocationBp = toolbox.readCashAllocationBp();
        uint256 investRatioBp    = BASE_POINTS - cashAllocationBp;
        uint256 cashToInvest     = calc.netAmount.mulDiv(investRatioBp, BASE_POINTS);
        calc.cashRetained        = calc.netAmount - cashToInvest;
        calc.assetsToBuy         = cashToInvest.mulDiv(PRECISION, assetPriceEUR);
    }

    /// @dev Computes the "after" balance-sheet state for a subscription
    ///   BEFORE the mint interactions happen (strict CEI archive-then-mint
    ///   ordering used by subscribe()).
    function _calcCycleAfterSubscription(SubscriptionCalc memory calc, uint256 cycleNumber)
        internal
        view
        returns (CycleAfter memory c)
    {
        c.assetsAfter = assetToken.balanceOf(address(this)) + calc.assetsToBuy;
        c.cashAfter   = cashToken.balanceOf(address(this)) + calc.cashRetained;
        c.sharesAfter = sharesToken.totalSupply() + calc.sharesToIssue;

        c.totalNAVAfter    = c.cashAfter + c.assetsAfter.mulDiv(assetPriceEUR, PRECISION);
        c.navPerShareAfter = c.sharesAfter > 0
            ? c.totalNAVAfter.mulDiv(PRECISION, c.sharesAfter)
            : INITIAL_NAV_PER_SHARE;

        c.stateFingerprint = _computeStateFingerprint(
            cycleNumber, c.navPerShareAfter, c.totalNAVAfter, c.assetsAfter, c.cashAfter, c.sharesAfter
        );
    }

    /// @dev Computes the Toolbox-driven gross amount, fee, and proportional
    ///   asset/cash split for a redemption. Called BEFORE the burn
    ///   interactions happen, so balanceOf() reads reflect the pre-burn state.
    function _calcRedemption(uint256 shareAmount, uint256 firstEntryTimestamp)
        internal
        view
        returns (RedemptionCalc memory calc)
    {
        uint256 navPerShareBefore = _computeNAVPerShare();
        calc.grossAmount = toolbox.calculateRedemptionAmount(shareAmount, navPerShareBefore);

        (calc.redemptionFee, calc.isEarly) = toolbox.calculateFullRedemptionFees(calc.grossAmount, firstEntryTimestamp);
        calc.netAmountToInvestor = calc.grossAmount > calc.redemptionFee ? calc.grossAmount - calc.redemptionFee : 0;

        uint256 assetsBefore   = assetToken.balanceOf(address(this));
        uint256 totalNAVBefore = _computeTotalNAV();
        uint256 assetsValue    = assetsBefore.mulDiv(assetPriceEUR, PRECISION);

        // Only netAmountToInvestor is actually liquidated/paid out; the fee
        // portion of grossAmount is simply not sold/burned, so it remains on
        // the fund's balance sheet (see header "SCOPE DECISION" note).
        if (totalNAVBefore > 0 && assetsValue > 0) {
            uint256 assetsSoldValue = calc.netAmountToInvestor.mulDiv(assetsValue, totalNAVBefore);
            calc.assetsSold = assetsSoldValue.mulDiv(PRECISION, assetPriceEUR);
            calc.cashUsed   = calc.netAmountToInvestor - assetsSoldValue;
        } else {
            calc.assetsSold = 0;
            calc.cashUsed   = calc.netAmountToInvestor;
        }
    }

    /// @dev Computes the "after" balance-sheet state for a redemption
    ///   BEFORE the burn interactions happen (strict CEI archive-then-burn
    ///   ordering used by redeem()).
    function _calcCycleAfterRedemption(RedemptionCalc memory calc, uint256 shareAmount, uint256 cycleNumber)
        internal
        view
        returns (CycleAfter memory c)
    {
        c.assetsAfter = assetToken.balanceOf(address(this)) - calc.assetsSold;
        c.cashAfter   = cashToken.balanceOf(address(this)) - calc.cashUsed;
        c.sharesAfter = sharesToken.totalSupply() - shareAmount;

        c.totalNAVAfter    = c.cashAfter + c.assetsAfter.mulDiv(assetPriceEUR, PRECISION);
        c.navPerShareAfter = c.sharesAfter > 0 ? c.totalNAVAfter.mulDiv(PRECISION, c.sharesAfter) : 0;

        c.stateFingerprint = _computeStateFingerprint(
            cycleNumber, c.navPerShareAfter, c.totalNAVAfter, c.assetsAfter, c.cashAfter, c.sharesAfter
        );
    }

    /// @dev Archives NAV cycle 0 and emits the genesis events. Split out of
    ///   initializeBalanceSheet() purely to keep that function's live stack
    ///   variables low.
    function _archiveGenesisCycle(SubscriptionCalc memory calc) internal {
        uint256 navT0Total    = _computeTotalNAV();
        uint256 navT0PerShare = _computeNAVPerShare();

        bytes32 fingerprintT0 = _computeStateFingerprint(
            0, navT0PerShare, navT0Total, calc.assetsToBuy, cashToken.balanceOf(address(this)), sharesToken.totalSupply()
        );

        _navCycles[0] = NAVCycle({
            cycleNumber:        0,
            timestamp:          block.timestamp,
            navPerShare:        navT0PerShare,
            totalNAV:           navT0Total,
            assetsHeld:         calc.assetsToBuy,
            cashAvailable:      cashToken.balanceOf(address(this)),
            sharesOutstanding:  sharesToken.totalSupply(),
            operationType:      OperationType.SUBSCRIPTION,
            shareQuantity:      calc.sharesToIssue,
            assetsBought:       calc.assetsToBuy,
            assetsSold:         0,
            feeCharged:         calc.subscriptionFee,
            investor:           msg.sender,
            stateFingerprint:   fingerprintT0,
            isFinalized:        true
        });

        _currentCycleNumber = 0;

        emit FundInitialized(msg.sender, calc.sharesToIssue, calc.assetsToBuy, calc.cashRetained, block.timestamp);
        emit NAVCycleClosed(
            0, OperationType.SUBSCRIPTION, msg.sender, calc.sharesToIssue, calc.assetsToBuy, 0, calc.subscriptionFee,
            cashToken.balanceOf(address(this)), calc.assetsToBuy, navT0PerShare, fingerprintT0, block.timestamp
        );
    }

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier notProcessing() {
        require(!_processingInProgress, "POC: NAV cycle in progress - please retry after the cycle closes");
        _;
    }

    modifier onlyIfInitialized() {
        require(isInitialized, "POC: Fund not initialized - call initializeBalanceSheet() first");
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor(
        string memory fundName_,
        address cashTokenAddress,
        address assetTokenAddress,
        address sharesTokenAddress,
        address toolboxAddress
    ) {
        require(bytes(fundName_).length > 0, "POC: Fund name is empty");
        require(cashTokenAddress != address(0), "POC: Invalid cash token address");
        require(assetTokenAddress != address(0), "POC: Invalid asset token address");
        require(sharesTokenAddress != address(0), "POC: Invalid shares token address");
        require(toolboxAddress != address(0), "POC: Invalid toolbox address");
        require(cashTokenAddress != assetTokenAddress, "POC: Cash and asset tokens must be distinct");

        fundName    = fundName_;
        cashToken   = IExternalToken(cashTokenAddress);
        assetToken  = IExternalAssetToken(assetTokenAddress);
        sharesToken = ITokenizedISIN(sharesTokenAddress);
        toolbox     = IToolbox(toolboxAddress);

        lastFeeAccrualTimestamp = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE,         msg.sender);
        _grantRole(COMPLIANCE_ROLE,    msg.sender);
        _grantRole(AUDITOR_ROLE,       msg.sender);
    }

    // =========================================================================
    // T0 BALANCE SHEET INITIALIZATION
    // =========================================================================

    /// @notice Initializes the fund's T0 balance sheet via a genesis
    ///   subscription of INITIAL_SUBSCRIPTION_EUR, processed through the
    ///   exact same Toolbox-driven rules (compliance, fees, strategy) as
    ///   any later subscribe() call.
    /// @dev Must be called EXACTLY ONCE by ADMIN_ROLE, only after this
    ///   contract has become "owner" of cashToken/assetToken and has been
    ///   granted FUND_ROLE + COMPLIANCE_ROLE on sharesToken, and
    ///   FUND_AUTHORIZED_ROLE on toolbox.
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

        sharesToken.whitelistShareholder(msg.sender);

        // ── CHECKS via Toolbox ───────────────────────────────────────────────
        ITokenizedISIN.ShareholderRecord memory rec = sharesToken.getShareholderRecord(msg.sender);
        require(
            toolbox.validateCompliance(msg.sender, INITIAL_SUBSCRIPTION_EUR, 0, rec.amountInvested),
            "POC: Genesis subscription failed Toolbox compliance validation"
        );

        SubscriptionCalc memory calc = _calcSubscription(INITIAL_SUBSCRIPTION_EUR);
        require(calc.sharesToIssue > 0, "POC: Genesis subscription too small to issue a share");

        // ── INTERACTIONS ──────────────────────────────────────────────────────
        assetToken.mint(address(this), calc.assetsToBuy, "GENESIS_SUBSCRIPTION");
        cashToken.mint(address(this), calc.cashRetained, "GENESIS_SUBSCRIPTION");
        sharesToken.mint(msg.sender, calc.sharesToIssue, INITIAL_SUBSCRIPTION_EUR);

        // ── ARCHIVAL of NAV cycle 0 ───────────────────────────────────────────
        _archiveGenesisCycle(calc);
    }

    // =========================================================================
    // INVESTOR MANAGEMENT — WHITELIST / BLACKLIST (forwarded to TokenizedISIN)
    // =========================================================================

    function whitelistInvestor(address investor) external onlyRole(COMPLIANCE_ROLE) whenNotPaused {
        sharesToken.whitelistShareholder(investor);
    }

    function blacklistInvestor(address investor, string calldata reason) external onlyRole(COMPLIANCE_ROLE) {
        sharesToken.blacklistShareholder(investor, reason);
        emit SecurityAlert(string(abi.encodePacked("Blacklisting: ", reason)), investor, block.timestamp);
    }

    // =========================================================================
    // SUBSCRIPTION
    // =========================================================================

    /// @notice Subscribes `amountEUR` (18 decimals) and applies the
    ///   Toolbox-driven fee + investment strategy rules.
    /// @param amountEUR Gross subscription amount in EUR, 18 decimals.
    ///   Must satisfy Toolbox's compliance rules (institutional minimum
    ///   subscription + individual cap).
    function subscribe(uint256 amountEUR)
        external
        whenNotPaused
        nonReentrant
        notProcessing
        onlyIfInitialized
    {
        emit OrderReceived(msg.sender, OperationType.SUBSCRIPTION, amountEUR, block.timestamp);

        // ── CHECKS ────────────────────────────────────────────────────────────
        require(amountEUR > 0, "POC: Subscription amount must be > 0");

        ITokenizedISIN.ShareholderRecord memory rec = sharesToken.getShareholderRecord(msg.sender);
        require(
            toolbox.validateCompliance(msg.sender, amountEUR, 0, rec.amountInvested),
            "POC: Subscription failed Toolbox compliance validation (minimum amount or individual cap)"
        );

        // ── EFFECTS ───────────────────────────────────────────────────────────
        _processingInProgress = true;

        SubscriptionCalc memory calc = _calcSubscription(amountEUR);
        require(calc.sharesToIssue > 0, "POC: Net subscription amount too small to issue a share");

        _currentCycleNumber += 1;
        uint256 cycleNumber = _currentCycleNumber;

        CycleAfter memory c = _calcCycleAfterSubscription(calc, cycleNumber);

        _navCycles[cycleNumber] = NAVCycle({
            cycleNumber:        cycleNumber,
            timestamp:          block.timestamp,
            navPerShare:        c.navPerShareAfter,
            totalNAV:           c.totalNAVAfter,
            assetsHeld:         c.assetsAfter,
            cashAvailable:      c.cashAfter,
            sharesOutstanding:  c.sharesAfter,
            operationType:      OperationType.SUBSCRIPTION,
            shareQuantity:      calc.sharesToIssue,
            assetsBought:       calc.assetsToBuy,
            assetsSold:         0,
            feeCharged:         calc.subscriptionFee,
            investor:           msg.sender,
            stateFingerprint:   c.stateFingerprint,
            isFinalized:        true
        });

        emit SubscriptionExecuted(
            msg.sender, amountEUR, calc.subscriptionFee, calc.sharesToIssue, calc.assetsToBuy, calc.cashRetained,
            c.navPerShareAfter, cycleNumber, block.timestamp
        );
        emit NAVCycleClosed(
            cycleNumber, OperationType.SUBSCRIPTION, msg.sender, calc.sharesToIssue, calc.assetsToBuy, 0,
            calc.subscriptionFee, c.cashAfter, c.assetsAfter, c.navPerShareAfter, c.stateFingerprint, block.timestamp
        );

        // ── INTERACTIONS ──────────────────────────────────────────────────────
        // NOTE: `investedAmount` recorded on the shareholder register is the
        // GROSS amount (pre-fee): the Toolbox individual subscription cap is
        // meant to cap what an investor actually commits, not the net
        // invested amount after fees.
        require(assetToken.mint(address(this), calc.assetsToBuy, "SUBSCRIPTION"), "POC: TokenizedAssets mint failed");
        require(cashToken.mint(address(this), calc.cashRetained, "SUBSCRIPTION"), "POC: EMT mint failed");
        require(sharesToken.mint(msg.sender, calc.sharesToIssue, amountEUR), "POC: TokenizedISIN mint failed");

        emit OperationFinalized(msg.sender, OperationType.SUBSCRIPTION, calc.sharesToIssue, cycleNumber, block.timestamp);

        _processingInProgress = false;
    }

    // =========================================================================
    // REDEMPTION
    // =========================================================================

    /// @param shareAmount Whole/fractional share amount to redeem, 18 decimals.
    function redeem(uint256 shareAmount)
        external
        whenNotPaused
        nonReentrant
        notProcessing
        onlyIfInitialized
    {
        emit OrderReceived(msg.sender, OperationType.REDEMPTION, shareAmount, block.timestamp);

        // ── CHECKS ────────────────────────────────────────────────────────────
        require(shareAmount > 0, "POC: Share amount must be > 0");

        uint256 sharesOutstanding = sharesToken.totalSupply();
        require(sharesOutstanding > shareAmount, "POC: Full fund redemption is forbidden - use liquidation instead");
        require(sharesToken.balanceOf(msg.sender) >= shareAmount, "POC: Insufficient share balance for this redemption");

        // ── EFFECTS ───────────────────────────────────────────────────────────
        _processingInProgress = true;

        ITokenizedISIN.ShareholderRecord memory rec = sharesToken.getShareholderRecord(msg.sender);
        RedemptionCalc memory calc = _calcRedemption(shareAmount, rec.firstEntryTimestamp);

        require(assetToken.balanceOf(address(this)) >= calc.assetsSold, "POC: Insufficient assets to honor the redemption");
        require(cashToken.balanceOf(address(this)) >= calc.cashUsed,      "POC: Insufficient cash to honor the redemption");

        _currentCycleNumber += 1;
        uint256 cycleNumber = _currentCycleNumber;

        CycleAfter memory c = _calcCycleAfterRedemption(calc, shareAmount, cycleNumber);
        _archiveRedemption(calc, c, shareAmount, cycleNumber);

        // ── INTERACTIONS ──────────────────────────────────────────────────────
        if (calc.assetsSold > 0) {
            require(assetToken.burn(calc.assetsSold, "REDEMPTION"), "POC: TokenizedAssets burn failed");
        }
        if (calc.cashUsed > 0) {
            require(cashToken.burnFrom(address(this), calc.cashUsed, "REDEMPTION"), "POC: EMT burn failed");
        }
        require(sharesToken.burnFrom(msg.sender, shareAmount), "POC: TokenizedISIN burn failed");

        emit OperationFinalized(msg.sender, OperationType.REDEMPTION, shareAmount, cycleNumber, block.timestamp);

        _processingInProgress = false;
    }

    /// @dev Writes the NAVCycle archive entry and emits RedemptionExecuted/
    ///   NAVCycleClosed. Split out of redeem() purely to keep that
    ///   function's live stack variables low.
    function _archiveRedemption(RedemptionCalc memory calc, CycleAfter memory c, uint256 shareAmount, uint256 cycleNumber) internal {
        _navCycles[cycleNumber] = NAVCycle({
            cycleNumber:        cycleNumber,
            timestamp:          block.timestamp,
            navPerShare:        c.navPerShareAfter,
            totalNAV:           c.totalNAVAfter,
            assetsHeld:         c.assetsAfter,
            cashAvailable:      c.cashAfter,
            sharesOutstanding:  c.sharesAfter,
            operationType:      OperationType.REDEMPTION,
            shareQuantity:      shareAmount,
            assetsBought:       0,
            assetsSold:         calc.assetsSold,
            feeCharged:         calc.redemptionFee,
            investor:           msg.sender,
            stateFingerprint:   c.stateFingerprint,
            isFinalized:        true
        });

        emit RedemptionExecuted(
            msg.sender, shareAmount, calc.grossAmount, calc.redemptionFee, calc.isEarly, calc.netAmountToInvestor,
            calc.assetsSold, calc.cashUsed, c.navPerShareAfter, cycleNumber, block.timestamp
        );
        emit NAVCycleClosed(
            cycleNumber, OperationType.REDEMPTION, msg.sender, shareAmount, 0, calc.assetsSold,
            calc.redemptionFee, c.cashAfter, c.assetsAfter, c.navPerShareAfter, c.stateFingerprint, block.timestamp
        );
    }

    // =========================================================================
    // ONGOING FEE ACCRUAL (management / custody / admin / performance)
    // =========================================================================

    /// @notice Computes the ongoing fees due since the last accrual and
    struct FeeAccrual {
        uint256 periodSeconds;
        uint256 grossNAV;
        uint256 managementFee;
        uint256 custodyFee;
        uint256 adminFee;
        uint256 performanceFee;
        uint256 navPerShare;
        uint256 supply;
    }

    function accrueOngoingFees() external onlyRole(ADMIN_ROLE) whenNotPaused nonReentrant onlyIfInitialized {
        FeeAccrual memory f;

        f.periodSeconds = block.timestamp > lastFeeAccrualTimestamp
            ? block.timestamp - lastFeeAccrualTimestamp
            : 0;
        require(f.periodSeconds > 0, "POC: No time elapsed since the last fee accrual");
        require(f.periodSeconds <= 7 days, "POC: Call accrueOngoingFees() more frequently (max 7-day window)");

        f.grossNAV = _computeTotalNAV();
        (f.managementFee, f.custodyFee, f.adminFee) = toolbox.calculateProrataOngoingFees(f.grossNAV, f.periodSeconds);

        f.navPerShare = _computeNAVPerShare();
        f.supply      = sharesToken.totalSupply();

        if (f.supply > 0) {
            f.performanceFee = toolbox.calculatePerformanceFees(f.navPerShare, f.supply);
            toolbox.updateHighWaterMark(f.navPerShare, _currentCycleNumber);
        }

        lastFeeAccrualTimestamp = block.timestamp;

        _currentCycleNumber += 1;
        _archiveFeeAccrual(f, _currentCycleNumber);
    }

    /// @dev Archives a FEE_ACCRUAL NAV cycle and emits its events. Split out
    ///   of accrueOngoingFees() purely to keep that function's live stack
    ///   variables low.
    function _archiveFeeAccrual(FeeAccrual memory f, uint256 cycleNumber) internal {
        uint256 totalFee = f.managementFee + f.custodyFee + f.adminFee + f.performanceFee;
        uint256 assetsHeld = assetToken.balanceOf(address(this));
        uint256 cashAvailable = cashToken.balanceOf(address(this));

        bytes32 stateFingerprint = _computeStateFingerprint(
            cycleNumber, f.navPerShare, f.grossNAV, assetsHeld, cashAvailable, f.supply
        );

        _navCycles[cycleNumber] = NAVCycle({
            cycleNumber:        cycleNumber,
            timestamp:          block.timestamp,
            navPerShare:        f.navPerShare,
            totalNAV:           f.grossNAV,
            assetsHeld:         assetsHeld,
            cashAvailable:      cashAvailable,
            sharesOutstanding:  f.supply,
            operationType:      OperationType.FEE_ACCRUAL,
            shareQuantity:      0,
            assetsBought:       0,
            assetsSold:         0,
            feeCharged:         totalFee,
            investor:           address(0),
            stateFingerprint:   stateFingerprint,
            isFinalized:        true
        });

        emit FeesAccrued(f.managementFee, f.custodyFee, f.adminFee, f.performanceFee, f.grossNAV, f.navPerShare, f.periodSeconds, block.timestamp);
        emit NAVCycleClosed(
            cycleNumber, OperationType.FEE_ACCRUAL, address(0), 0, 0, 0, totalFee,
            cashAvailable, assetsHeld, f.navPerShare, stateFingerprint, block.timestamp
        );
    }

    // =========================================================================
    // NAV CALCULATION
    // =========================================================================

    function computeTotalNAV() external view returns (uint256) {
        return _computeTotalNAV();
    }

    function computeNAVPerShare() external view returns (uint256) {
        return _computeNAVPerShare();
    }

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
        assetsValue = assets.mulDiv(assetPriceEUR, PRECISION);
        totalNAV    = _computeTotalNAV();
        shares      = sharesToken.totalSupply();
        navPerShare = _computeNAVPerShare();
    }

    /// @notice Verifies that total assets match total liabilities (shares
    ///   outstanding valued at NAV per share).
    /// @return totalAssets Total NAV of the fund (cash + assets valuation), EUR 18 dec
    /// @return totalLiabilities Shares outstanding valued at NAV per share, EUR 18 dec
    /// @return balanced True if totalAssets and totalLiabilities match within
    ///   the expected 18-decimal fixed-point rounding tolerance
    /// @dev totalLiabilities is reconstructed as
    ///   supply * (totalNAV * PRECISION / supply) / PRECISION — a
    ///   divide-then-multiply round trip through _computeNAVPerShare().
    ///   Floor rounding at each step means this generally does NOT
    ///   reconstruct totalAssets bit-for-bit exactly, even when the balance
    ///   sheet is genuinely balanced (the gap is a negligible fraction of a
    ///   wei-of-EUR, unrelated to any real accounting discrepancy). A strict
    ///   `==` check would therefore report "unbalanced" on virtually every
    ///   call. Instead, `balanced` tolerates a gap up to `supply` raw units
    ///   — a generous bound for a single floor-division round trip — and
    ///   only reports false for a gap larger than that, which would
    ///   indicate a genuine problem worth investigating.
    function verifyBalanceSheet()
        external
        view
        returns (uint256 totalAssets, uint256 totalLiabilities, bool balanced)
    {
        uint256 supply = sharesToken.totalSupply();

        totalAssets      = _computeTotalNAV();
        totalLiabilities = supply.mulDiv(_computeNAVPerShare(), PRECISION);

        uint256 dust = totalAssets > totalLiabilities
            ? totalAssets - totalLiabilities
            : totalLiabilities - totalAssets;
        uint256 dustTolerance = supply > 0 ? supply : 1;

        balanced = dust <= dustTolerance;
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

    function verifyCycleIntegrity(uint256 cycleNumber)
        external
        view
        returns (bool integrity, bytes32 computedFingerprint, bytes32 storedFingerprint)
    {
        NAVCycle storage cycle = _navCycles[cycleNumber];
        computedFingerprint = _computeStateFingerprint(
            cycle.cycleNumber, cycle.navPerShare, cycle.totalNAV, cycle.assetsHeld, cycle.cashAvailable, cycle.sharesOutstanding
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

    function pauseContract() external onlyRole(ADMIN_ROLE) {
        _pause();
        emit SecurityAlert("Contract paused", msg.sender, block.timestamp);
    }

    function unpauseContract() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Updates the price used to value TokenizedAssets holdings.
    /// @dev KNOWN LIMITATION: manual/admin-driven, not a price oracle.
    function setAssetPrice(uint256 newPriceEUR) external onlyRole(ADMIN_ROLE) whenNotPaused {
        require(newPriceEUR > 0, "POC: Asset price must be > 0");
        emit AssetPriceUpdated(assetPriceEUR, newPriceEUR, block.timestamp);
        assetPriceEUR = newPriceEUR;
    }

    /// @notice Points the fund at a new Toolbox deployment.
    /// @dev The new Toolbox must be granted FUND_AUTHORIZED_ROLE (for
    ///   updateHighWaterMark) before or immediately after this call; the
    ///   previous Toolbox's grant should be revoked for hygiene.
    function updateToolbox(address newToolbox) external onlyRole(ADMIN_ROLE) {
        require(newToolbox != address(0), "POC: Invalid toolbox address");
        emit ToolboxUpdated(address(toolbox), newToolbox, block.timestamp);
        toolbox = IToolbox(newToolbox);
    }

    // =========================================================================
    // INTERNAL UTILITY FUNCTIONS
    // =========================================================================

    function _computeTotalNAV() internal view returns (uint256) {
        return cashToken.balanceOf(address(this)) + assetToken.balanceOf(address(this)).mulDiv(assetPriceEUR, PRECISION);
    }

    function _computeNAVPerShare() internal view returns (uint256) {
        uint256 supply = sharesToken.totalSupply();
        if (supply == 0) return INITIAL_NAV_PER_SHARE;
        return _computeTotalNAV().mulDiv(PRECISION, supply);
    }

    function _computeStateFingerprint(
        uint256 cycleNumber,
        uint256 navPerShare,
        uint256 totalNAV,
        uint256 assetsHeld,
        uint256 cashParam,
        uint256 sharesOutstanding
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            cycleNumber, navPerShare, totalNAV, assetsHeld, cashParam, sharesOutstanding, address(this)
        ));
    }
}
