// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
//
//  Smart Contract TOOLBOX — v2.0.0 (Phase 2)
//  Institutional financial calculation library
//  Auxiliary contract of the tokenized fund architecture
//
//  Compliance : AMF / CSSF / AIFMD / MiFID II / EMIR / MMF Regulation EU 2017/1131
//  Convention : ACT/365 (Euro Money Market)
//  Precision  : 18 decimals (wei-compatible, standard ERC20)
// =============================================================================
//
//  WHAT CHANGED IN v2.0.0 (Phase 2 architecture)
//  -----------------------------------------------------------------------
//  The fund is no longer a single monolithic contract. It is now split into
//  four contracts:
//
//    EMT.sol            - plain ERC20, represents the fund's CASH (EUR),
//                          minted/burned by the fund on subscription/redemption.
//    TokenizedAssets.sol - plain ERC20, represents the tokenized SECURITIES
//                          held in the fund's portfolio.
//    TokenizedISIN.sol  - OpenZeppelin ERC20 + AccessControl + Pausable.
//                          Represents the fund SHARES (liability side) AND
//                          maintains the on-chain shareholder register
//                          (whitelist / blacklist, amount invested, first
//                          entry timestamp, last operation timestamp).
//    Toolbox.sol (this) - stateless financial calculation engine.
//
//  The current fund contract in the repository, TokenizedFundPOC.sol, is a
//  Phase 1 proof of concept that intentionally does NOT call a Toolbox
//  ([POC-1] "NO TOOLBOX", [POC-2] "NO FEES") and reasons about a single
//  security priced flat at 1 EUR. This Toolbox targets the richer Phase 2
//  fund contract that will eventually replace/extend TokenizedFundPOC with
//  fees, a multi-asset portfolio, and regulatory limits — it is the
//  Toolbox that the "NO TOOLBOX" POC rule will be lifted for.
//
//  KEY DESIGN CHANGE — NO MORE SHADOW SHAREHOLDER REGISTER
//  -----------------------------------------------------------------------
//  The previous Toolbox kept its own investor bookkeeping (qualified
//  investor flag, cumulative amount invested, first subscription date).
//  That data now already lives in TokenizedISIN.ShareholderRecord and is
//  updated atomically on every mint/burn/transfer. Keeping a second copy
//  here would create two sources of truth that can silently drift apart
//  (e.g. if the Fund forgets to call both contracts, or a call reverts on
//  one side only). Instead, this Toolbox is a STATELESS rules engine for
//  anything investor-specific: the Fund contract reads the relevant fields
//  from TokenizedISIN.getShareholderRecord(investor) and passes them in as
//  plain parameters (amountAlreadyInvested, firstEntryTimestamp). The
//  Toolbox still owns and administers the parameters that are genuinely
//  its own responsibility (fee grid, investment strategy, individual
//  subscription cap, High Water Mark, commercial paper register).
//
// =============================================================================

// =============================================================================
// OPENZEPPELIN LIBRARY IMPORTS
// =============================================================================
// Rationale for each library used by the Toolbox:
//
// AccessControl : The Toolbox holds critical financial parameters (fee grid,
//   allocation strategy). Changing them must be restricted to authorized
//   roles only. An unchecked fee parameter change could amount to fraudulent
//   manipulation of the fund.
//
// Pausable : Circuit breaker in case a calculation bug is detected or a
//   regulatory instruction requires it. Lets the Toolbox freeze parameter
//   updates without impacting the Fund contract (which can keep operating
//   in read-only mode).
//
// ReentrancyGuard : Even though the Toolbox never holds funds directly, its
//   administration functions (fee updates, strategy updates) must be
//   protected against malicious recursive calls that could corrupt internal
//   state between two transactions in the same block.
//
// Math (mulDiv) : Key primitive for on-chain finance. mulDiv(a, b, c)
//   computes a*b/c with maximum precision and no intermediate overflow.
//   INDISPENSABLE because at 18-decimal fixed point, intermediate products
//   a*b easily exceed uint256 before the final division.
//
// SafeCast : Converts uint256 <-> int256 without silent truncation. Critical
//   for signed portfolio-adjustment calculations.

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

// =============================================================================
// ITOOLBOX INTERFACE
// =============================================================================
// This interface is the formal contract between the (future) Phase 2 fund
// contract and the Toolbox. It MUST stay in sync with whatever the fund
// contract declares. Any change must be versioned, documented, and audited
// before deployment.
//
// Why declare the interface in the same file?
//   - Lets the compiler verify the Toolbox actually honors its contract
//   - Makes ABI generation easier for off-chain integrators
//   - Reduces the risk of drift between the two contracts

interface IToolbox {
    // NOTE: FeeStructure/InvestmentStrategy are intentionally NOT redeclared
    // here. A struct declared inside an interface is a distinct type from
    // the identically-shaped struct declared inside Toolbox itself, which
    // would break `override` on any function returning them. Callers that
    // need individual fields (e.g. the fund's cash/invested split) use the
    // dedicated scalar getters below instead of reading the whole struct.

    function calculateLinearDepreciation(
        uint256 faceValue,
        uint256 annualRateBp,
        uint256 durationDays,
        uint256 daysElapsed
    ) external pure returns (uint256 currentValue);

    function calculateFees(
        uint256 amount,
        uint8 operationType
    ) external view returns (uint256 fee);

    /// @param firstEntryTimestamp Investor's first-entry timestamp, as read
    ///   by the caller from
    ///   TokenizedISIN.getShareholderRecord(investor).firstEntryTimestamp.
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

    /// @dev Restricted on the implementation side to FUND_AUTHORIZED_ROLE.
    function updateHighWaterMark(uint256 currentNAVPerShare, uint256 navCycle) external;

    function calculatePortfolioAdjustments(
        uint256 totalPortfolioValue,
        uint256[] calldata currentAllocations,
        uint256[] calldata targetAllocations
    ) external pure returns (int256[] memory adjustments);

    function checkLockup(
        uint256 firstEntryTimestamp
    ) external view returns (bool isLockupElapsed, uint256 secondsRemaining);

    function calculateSharesToIssue(
        uint256 subscriptionAmountEUR,
        uint256 navPerShare
    ) external pure returns (uint256 numberOfShares);

    function calculateRedemptionAmount(
        uint256 numberOfShares,
        uint256 navPerShare
    ) external pure returns (uint256 grossAmountEUR);

    /// @param amountAlreadyInvested Cumulative amount already invested by
    ///   `investor`, as read by the caller from
    ///   TokenizedISIN.getShareholderRecord(investor).amountInvested.
    ///   Ignored for redemptions.
    function validateCompliance(
        address investor,
        uint256 amount,
        uint8 operationType,
        uint256 amountAlreadyInvested
    ) external view returns (bool isValid);

    /// @notice Cash allocation of the current investment strategy, in bp.
    /// @dev Used by the fund to derive the invest-vs-retain-cash split: this
    ///   architecture has a single non-cash asset bucket (TokenizedAssets),
    ///   so `BASE_POINTS - cashAllocationBp` is the fraction routed there.
    function readCashAllocationBp() external view returns (uint256);

    function readIndividualSubscriptionCap() external view returns (uint256);
}

// =============================================================================
// SMART CONTRACT TOOLBOX
// =============================================================================
// Role in the Phase 2 architecture:
//
//   TokenizedFundPhase2 (future orchestrator contract)
//       |
//       |-- calls -----> Toolbox (this contract, stateless calculations)
//       |-- mints/burns -> EMT (cash)
//       |-- mints/burns -> TokenizedAssets (securities)
//       |-- mints/burns -> TokenizedISIN (shares + shareholder register)
//
// This contract centralizes:
//   MODULE 1 : Linear depreciation of fixed-income instruments (NEU CP)
//   MODULE 2 : Fee structure and calculation (entry, exit, management, performance)
//   MODULE 3 : Investment strategy and portfolio rebalancing
//   MODULE 4 : Regulatory compliance validation (limits, concentration, lock-up)
//   MODULE 5 : Advanced actuarial calculations (compound interest, yield, duration)
//   MODULE 6 : Advanced NAV valuation calculations (net NAV, shares to issue/redeem)
//   MODULE 7 : Toolbox administration and parameterization
//
// Benefits of externalizing this logic into a separate Toolbox:
//   SEPARATION OF CONCERNS : Fund = order lifecycle; Toolbox = financial and
//     regulatory logic. Independent auditability.
//   CONTROLLED UPGRADABILITY : a new fee grid = a new Toolbox deployed +
//     a call to Fund.updateToolbox(). Funds never move.
//   REUSABILITY : any future satellite contract can reuse the same
//     calculation functions (depreciation, rates, duration) without
//     duplicating code.
//   GAS EFFICIENCY : pure/view functions cost no gas outside of the
//     calling transaction.

contract Toolbox is IToolbox, AccessControl, Pausable, ReentrancyGuard {

    // =========================================================================
    // LIBRARY USAGE
    // =========================================================================
    // Declares usage of Math and SafeCast for all uint256/int256 variables.
    // Allows calling a.mulDiv(b, c) or a.toInt256() directly.
    using Math for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;

    // =========================================================================
    // ROLE DEFINITIONS (RBAC)
    // =========================================================================
    // Four-eyes principle (two-man rule) applied throughout:
    // Changing a critical financial parameter must be authorized by a role
    // distinct from the role that executes orders.

    /// @dev Portfolio manager: changes the allocation strategy
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @dev Fee administrator: changes the fee grid.
    /// Separate from MANAGER_ROLE: a manager must not be able to set their
    /// own fees.
    bytes32 public constant FEE_ADMIN_ROLE = keccak256("FEE_ADMIN_ROLE");

    /// @dev Compliance officer: manages regulatory thresholds
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    /// @dev Principal Toolbox administrator
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @dev Authorized Fund contract: only the Phase 2 fund contract may
    ///   call the stateful functions. Protects against unauthorized use of
    ///   the Toolbox by third-party contracts.
    bytes32 public constant FUND_AUTHORIZED_ROLE = keccak256("FUND_AUTHORIZED_ROLE");

    // =========================================================================
    // FUNDAMENTAL FINANCIAL CONSTANTS
    // =========================================================================
    // Constants (burned into bytecode) rather than variables, for parameters
    // that must NEVER change after deployment. Gas advantage: constants do
    // not consume an SLOAD (no storage read).

    /// @notice Fixed-point precision: 18 decimals (1 EUR = 1e18 units)
    /// ERC20 standard, compatible with wei-denominated price calculations.
    uint256 public constant PRECISION = 1e18;

    /// @notice Basis points base (1 bp = 0.01%, 10,000 bp = 100%)
    /// Avoids using decimal numbers (not natively supported in Solidity).
    /// Every rate is expressed in bp: 350 bp = 3.50%.
    uint256 public constant BASE_POINTS = 10_000;

    /// @notice Days per year — ACT/365 convention (Euro Money Market)
    /// ACT/365 is the standard convention for EUR-denominated rate
    /// instruments: NEU CP (formerly "billets de tresorerie"), OAT, BTF,
    /// and other French instruments.
    /// Alternative: ACT/360 for certain bank deposits. We choose ACT/365.
    uint256 public constant DAYS_PER_YEAR = 365;

    /// @notice Seconds per year (ACT/365, no leap year)
    /// Used for prorata temporis calculations of management fees.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Absolute minimum institutional subscription amount
    /// 100,000 EUR: regulatory threshold for qualified investors
    /// (Art. 423-27 AMF) and informed investors (Art. L533-16 CMF).
    /// Standard ASPIM market practice.
    uint256 public constant MINIMUM_SUBSCRIPTION = 100_000 * PRECISION;

    /// @notice Maximum concentration per issuer, in bp
    /// 20% max: diversification rule inspired by UCITS Article 22, adapted
    /// for alternative funds. Limits counterparty risk.
    uint256 public constant MAX_ISSUER_CONCENTRATION_BP = 2_000;

    /// @notice Minimum portfolio liquidity ratio, in bp
    /// 10% minimum: prudential requirement to honor daily redemptions.
    /// Compliant with MMF Regulation EU 2017/1131 (variable NAV money
    /// market funds).
    uint256 public constant MIN_LIQUIDITY_RATIO_BP = 1_000;

    /// @notice Minimum lock-up period: 90 days (AIFMD Art. 23 standard)
    uint256 public constant LOCK_UP_PERIOD = 90 days;

    /// @notice Maximum number of assets in the portfolio
    /// Capped at 50: avoids loops long enough to exceed the gas limit.
    /// An institutional MMF portfolio generally does not exceed 30 lines.
    uint256 public constant MAX_PORTFOLIO_ASSETS = 50;

    // -------------------------------------------------------------------------
    // POC COMMERCIAL PAPER IDENTIFIERS
    // -------------------------------------------------------------------------
    // Identifiers for the three demo commercial papers from the fund's
    // origination worksheet (trade date 24/07/2026, maturity 31/12/2026,
    // 160-day tenor for all three). Registered in bulk by
    // initializePOCCommercialPapers() below. Mirrored on the TokenizedAssets
    // side by the identically-named constants in TokenizedAssets.sol.

    bytes32 public constant POC_CP_2PCT_ID   = keccak256("POC CP 2%");
    bytes32 public constant POC_CP_2_5PCT_ID = keccak256("POC CP 2.5%");
    bytes32 public constant POC_CP_3PCT_ID   = keccak256("POC CP 3%");

    // =========================================================================
    // DATA STRUCTURES
    // =========================================================================

    // -------------------------------------------------------------------------
    // FEE STRUCTURE
    // -------------------------------------------------------------------------
    // Three-layer fee architecture, standard hedge fund / reserved fund
    // practice:
    //
    //   LAYER 1 - Transaction fees (charged on each order)
    //     Entry fee (subscription) and exit fee (redemption).
    //     Expressed in bp of the gross amount.
    //
    //   LAYER 2 - Ongoing annual fees (accrued prorata at every NAV cycle)
    //     Management fee + custody fee + admin fee.
    //     Reduce net assets at every cycle, hence NAV per share.
    //
    //   LAYER 3 - Performance fees (High Water Mark)
    //     Charged only if NAV > HWM + hurdle rate.
    //     Avoids double-charging the same gains.
    //     Crystallized annually or on each redemption.

    /// @notice Complete fee structure of the fund
    /// All rates are expressed in basis points (bp).
    struct FeeStructure {
        uint256 subscriptionFeeBp;       // Entry fee (e.g. 50 bp = 0.50%)
        uint256 redemptionFeeBp;         // Exit fee (e.g. 25 bp = 0.25%)
        uint256 annualManagementFeeBp;   // Annual management fee (e.g. 100 bp = 1.00%/yr)
        uint256 performanceFeeBp;        // Share of outperformance (e.g. 2000 bp = 20%)
        uint256 hurdleRateBp;            // Minimum return before perf fees (e.g. 300 bp = 3%/yr)
        uint256 annualCustodyFeeBp;      // Annual custody fee (e.g. 5 bp = 0.05%/yr)
        uint256 annualAdminFeeBp;        // Annual admin fee (e.g. 10 bp = 0.10%/yr)
        uint256 earlyRedemptionPenaltyBp;// Penalty for redemption before lock-up (e.g. 200 bp = 2%)
        uint256 lastUpdateTimestamp;     // Timestamp of the last update
    }

    // -------------------------------------------------------------------------
    // INVESTMENT STRATEGY
    // -------------------------------------------------------------------------
    // The strategy defines target allocations per asset class and portfolio
    // risk parameters. It is set by the manager and validated by the
    // investment committee.

    /// @notice Investment strategy parameters
    struct InvestmentStrategy {
        uint256 commercialPaperAllocationBp; // NEU CP / Commercial Paper (< 1 year)
        uint256 bondAllocationBp;            // Sovereign bonds / IG corporate bonds
        uint256 equityAllocationBp;          // Equities (0 for a pure MMF)
        uint256 cashAllocationBp;            // Cash (safety floor)

        // Deviation tolerance before rebalancing:
        // If an asset's actual allocation deviates from its target by more
        // than deviationToleranceBp, rebalancing is triggered.
        // E.g. 100 bp = rebalance if deviation > 1%
        uint256 deviationToleranceBp;

        // Maximum portfolio duration in days.
        // Limits interest rate risk exposure.
        // Short-term MMF ESMA standard: 60d (WAM) / 120d (WAL).
        // We use 90d as a conservative value.
        uint256 maxDurationDays;

        // Minimum counterparty rating (encoded: 1=AAA, 2=AA+, 3=AA, 4=AA-,
        // 5=A+, 6=A, 7=A-). Compliant with ESMA MMF requirements
        // (Regulation 2017/1131 Art. 19).
        uint8 minCounterpartyRating;

        uint256 lastUpdateTimestamp;
    }

    // -------------------------------------------------------------------------
    // HIGH WATER MARK
    // -------------------------------------------------------------------------
    // Standard investor-protection mechanism: performance fees are only due
    // if NAV per share exceeds its historical high. Avoids charging the
    // same gains twice.
    // Example: NAV rises to 1050, falls back to 980, then rises to 1030.
    // Performance fees are only charged on the rise from 980 to 1050 (the
    // first time), NOT on the rise from 980 to 1030 (HWM is still 1050).

    /// @notice High Water Mark register for performance fees
    struct HighWaterMark {
        uint256 highValue;   // Historical high of NAV per share (EUR, 18 dec)
        uint256 timestamp;   // Timestamp the high was reached
        uint256 navCycle;    // NAV cycle number that established the high
    }

    // -------------------------------------------------------------------------
    // COMMERCIAL PAPER (NEU CP)
    // -------------------------------------------------------------------------
    // Complete parameters of a commercial paper instrument, for valuation
    // tracking. NEU CP (Negotiable European Commercial Paper) are short-term
    // rate instruments issued by corporates or credit institutions,
    // generally at a discount (below par).

    /// @notice Parameters of a commercial paper instrument for depreciation calculation
    struct CommercialPaperParameters {
        bytes32 identifier;       // ISIN (e.g. keccak256("FR0000000000"))
        uint256 faceValue;        // Value at maturity in EUR (18 dec)
        uint256 acquisitionPrice; // Purchase price in EUR (18 dec, <= face value for a discount)
        uint256 yieldRateBp;      // Annualized actuarial yield rate (bp)
        uint256 issuanceDate;     // Unix timestamp of issuance
        uint256 maturityDate;     // Unix timestamp of maturity
        uint256 durationDays;     // Total duration in days (computed at registration)
        bool    isActive;         // True if the instrument is still in the portfolio
    }

    /// @notice Detailed valuation result of a commercial paper instrument
    struct ValuationResult {
        uint256 currentValue;     // Current value of the instrument (EUR, 18 dec)
        uint256 accruedInterest;  // Interest accrued since issuance (EUR, 18 dec)
        uint256 daysElapsed;      // Days elapsed since issuance
        uint256 daysRemaining;    // Days remaining until maturity
        uint256 dailyYield;       // Daily yield, in PRECISION units
        bool    isMatured;        // True if maturity has passed
    }

    // =========================================================================
    // STATE VARIABLES
    // =========================================================================
    // All state variables are private with dedicated public getters.
    // Least-privilege principle for internal data exposure.
    //
    // NOTE: there is deliberately no investor-level bookkeeping here
    // (whitelist flag, cumulative amount invested, first-entry date). That
    // data is owned by TokenizedISIN.ShareholderRecord — see the
    // "KEY DESIGN CHANGE" note at the top of this file.

    /// @notice Fee structure currently in effect
    FeeStructure private _fees;

    /// @notice Investment strategy currently in effect
    InvestmentStrategy private _strategy;

    /// @notice High Water Mark register
    HighWaterMark private _highWaterMark;

    /// @notice Registry of tracked commercial paper instruments: ISIN => parameters
    mapping(bytes32 => CommercialPaperParameters) private _commercialPapers;

    /// @notice List of paper identifiers (for iteration and audit)
    bytes32[] private _paperIdentifierList;

    /// @notice True once initializePOCCommercialPapers() has run. Guards
    ///   against seeding the three demo commercial papers more than once.
    bool public pocCommercialPapersInitialized;

    /// @notice Default individual subscription cap (EUR, 18 dec)
    /// Protects against excessive concentration in a single investor.
    uint256 private _individualSubscriptionCapEUR;

    /// @notice Toolbox version (for update traceability)
    string public version;

    // =========================================================================
    // EVENTS
    // =========================================================================
    // All events are indexed to allow efficient querying. They form the
    // immutable trail of every parameter change.

    /// @notice Emitted when the fee structure is updated
    event FeesUpdated(
        uint256 subscriptionFeeBp,
        uint256 redemptionFeeBp,
        uint256 annualManagementFeeBp,
        uint256 performanceFeeBp,
        uint256 timestamp,
        address indexed updatedBy
    );

    /// @notice Emitted when the investment strategy is updated
    event StrategyUpdated(
        uint256 commercialPaperAllocationBp,
        uint256 bondAllocationBp,
        uint256 deviationToleranceBp,
        uint256 maxDurationDays,
        uint256 timestamp,
        address indexed manager
    );

    /// @notice Emitted when a new commercial paper instrument is registered
    event CommercialPaperRegistered(
        bytes32 indexed identifier,
        uint256 faceValue,
        uint256 yieldRateBp,
        uint256 durationDays,
        uint256 timestamp
    );

    /// @notice Emitted when the High Water Mark is updated
    event HighWaterMarkUpdated(
        uint256 previousValue,
        uint256 newValue,
        uint256 navCycle,
        uint256 timestamp
    );

    /// @notice Emitted on a compliance alert (non-blocking, for monitoring)
    /// @dev Reserved for future use by stateful functions; validateCompliance()
    ///   itself is a view function and cannot emit events, so off-chain
    ///   monitoring must watch its return value directly.
    event ComplianceAlert(
        address indexed investor,
        string reason,
        uint256 amount,
        uint256 timestamp
    );

    /// @notice Emitted when the individual subscription cap is updated
    event SubscriptionCapUpdated(
        uint256 previousCap,
        uint256 newCap,
        uint256 timestamp
    );

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    /// @dev Restricts stateful calls to the single authorized Fund contract.
    /// Prevents a third-party contract from manipulating HWM parameters or
    /// invested amounts through unauthorized direct calls to the Toolbox.
    modifier onlyAuthorizedFund() {
        require(
            hasRole(FUND_AUTHORIZED_ROLE, msg.sender),
            "TOOLBOX: Unauthorized caller - Only the Fund contract may call this"
        );
        _;
    }

    /// @dev Verifies that target allocations sum to exactly 100%.
    /// A +/-1 bp tolerance is allowed to absorb rounding.
    modifier targetAllocationsSum100Percent(
        uint256 commercialPaper,
        uint256 bonds,
        uint256 equities,
        uint256 cash
    ) {
        uint256 total = commercialPaper + bonds + equities + cash;
        require(
            total >= BASE_POINTS - 1 && total <= BASE_POINTS + 1,
            "TOOLBOX: Target allocations do not sum to 100% (+/- 1bp tolerance)"
        );
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /// @notice Deploys the Toolbox and initializes default financial parameters
    /// @param adminAddress Address receiving all roles initially
    /// @param contractVersion Contract version (e.g. "2.0.0")
    ///
    /// @dev Default values correspond to a standard institutional money
    /// market fund, compliant with MMF Regulation EU 2017/1131 and
    /// AFG/ASPIM market practice.
    constructor(
        address adminAddress,
        string memory contractVersion
    ) {
        require(adminAddress != address(0), "TOOLBOX: Invalid admin address");
        require(bytes(contractVersion).length > 0, "TOOLBOX: Empty version");

        version = contractVersion;

        // Founding role assignment to the deployment administrator.
        // In production: these roles will be distributed to distinct
        // addresses (principle of least privilege) after initial deployment.
        _grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        _grantRole(ADMIN_ROLE,         adminAddress);
        _grantRole(MANAGER_ROLE,       adminAddress);
        _grantRole(FEE_ADMIN_ROLE,     adminAddress);
        _grantRole(COMPLIANCE_ROLE,    adminAddress);

        // -----------------------------------------------------------------------
        // Default fee parameters — institutional money market fund
        // Source: AFG (Association Francaise de la Gestion financiere) 2024
        // -----------------------------------------------------------------------
        _fees = FeeStructure({
            subscriptionFeeBp:        0,     // 0 bp: no entry fee (standard practice
                                              // for institutional reserved funds)
            redemptionFeeBp:          0,     // 0 bp: no standard exit fee
            annualManagementFeeBp:    50,    // 0.50%/yr: low end of institutional range
                                              // (0.10-0.50% for an MMF, 1-2% for an AIF)
            performanceFeeBp:         2_000, // 20% of outperformance: classic hedge
                                              // fund "2/20" standard (2% mgmt + 20% perf)
            hurdleRateBp:             300,   // 3%/yr: hurdle rate based on average 3M
                                              // Euribor. Adjustable with market conditions
            annualCustodyFeeBp:       5,     // 0.05%/yr: standard for large funds (> 500M EUR)
                                              // BNP Securities Services, Caceis, SGSS
            annualAdminFeeBp:         10,    // 0.10%/yr: fund administrator fee
                                              // (valuation agent, transfer agent, auditor)
            earlyRedemptionPenaltyBp: 200,   // 2%: penalty for redemption before lock-up ends
                                              // Protects remaining holders against dilution
            lastUpdateTimestamp:      block.timestamp
        });

        // -----------------------------------------------------------------------
        // Default investment strategy — short-term MMF
        // Compliant with EU Regulation 2017/1131 on money market funds
        // -----------------------------------------------------------------------
        _strategy = InvestmentStrategy({
            commercialPaperAllocationBp: 6_000, // 60% NEU CP: main French MMF instrument
                                                 // Issued by corporates and local authorities
            bondAllocationBp:            2_000, // 20% OAT/BTAN/short-duration IG bonds
                                                 // Residual maturity < 2 years (limited rate risk)
            equityAllocationBp:          0,     // 0% equities: incompatible with a pure MMF
                                                 // (Art. 9 MMF Regulation: eligible assets only)
            cashAllocationBp:            2_000, // 20% cash: above the regulatory minimum
                                                 // (10%) to handle redemptions
            deviationToleranceBp:        100,   // 1%: rebalancing trigger threshold
                                                 // Trade-off between stability and precision
            maxDurationDays:             90,    // 90 days WAM (Weighted Average Maturity)
                                                 // Compliant with MMF Regulation Art. 24
                                                 // (WAM <= 60d; we are conservative at 90d
                                                 // for a similar AIF profile)
            minCounterpartyRating:       3,     // AA minimum (code 3 in our nomenclature)
                                                 // Compliant with ESMA MMF: no sub-investment
                                                 // grade exposure
            lastUpdateTimestamp:         block.timestamp
        });

        // HWM initialized to zero: the first NAV cycle establishes the initial HWM
        _highWaterMark = HighWaterMark({
            highValue: 0,
            timestamp: block.timestamp,
            navCycle:  0
        });

        // Default individual subscription cap: 10 million EUR
        // Prevents a single investor from representing more than X% of the
        // fund (to be adjusted based on the fund's target size).
        _individualSubscriptionCapEUR = 10_000_000 * PRECISION;
    }

    // =========================================================================
    // MODULE 1 : LINEAR DEPRECIATION CALCULATION — COMMERCIAL PAPER
    // =========================================================================
    // NEU CP are issued "below par" (at a discount).
    // Example: an instrument with face value 1,000,000 EUR, rate 3.50%/yr, 90 days
    //   -> Issuance price = 1,000,000 / (1 + 3.50% x 90/365) = 991,400 EUR (approx.)
    //   -> The instrument's value rises linearly from 991,400 EUR to
    //      1,000,000 EUR over 90 days.
    //
    // Method chosen: STRAIGHT-LINE AMORTIZATION
    //   Formula: V(t) = IssuancePrice + (FV - IssuancePrice) x (t / T)
    //   Where: t = days elapsed, T = total duration, FV = face value
    //
    // Why straight-line rather than actuarial (compound rate)?
    //   1. The actuarial method requires exp()/pow(), not available in
    //      Solidity without external libraries (additional security risk).
    //   2. For short maturities (< 1 year, typical of NEU CP), the gap
    //      between the two methods is under 0.01 bp (negligible).
    //   3. The straight-line method is accepted by regulators for MMFs with
    //      a stable or quasi-stable NAV (CNAV/LVNAV).
    //   4. IFRS 9 compliance: held-to-maturity instruments can be valued at
    //      straight-line amortized cost if the gap with the actuarial value
    //      is immaterial.

    /// @notice Computes the current value of a commercial paper (NEU CP) instrument by straight-line amortization
    /// @param faceValue Face value (repayment at maturity) in EUR — 18 decimals
    /// @param annualRateBp Annual yield rate in basis points (e.g. 350 = 3.50%/yr)
    /// @param durationDays Total duration of the instrument in calendar days
    /// @param daysElapsed Number of days elapsed since the issuance date
    /// @return currentValue Current value of the instrument in EUR — 18 decimals
    ///
    /// @dev Guaranteed invariant: currentValue >= issuancePrice AND <= faceValue
    ///      If daysElapsed >= durationDays: returns faceValue (maturity reached)
    function calculateLinearDepreciation(
        uint256 faceValue,
        uint256 annualRateBp,
        uint256 durationDays,
        uint256 daysElapsed
    ) external pure override returns (uint256 currentValue) {
        // --- CHECKS ---
        require(faceValue > 0,                 "TOOLBOX: Face value is zero");
        require(durationDays > 0,               "TOOLBOX: Duration is zero");
        require(annualRateBp > 0,               "TOOLBOX: Annual rate is zero");
        require(annualRateBp <= BASE_POINTS * 10, "TOOLBOX: Annual rate implausible (> 100%)");
        // daysElapsed may be 0 (first day) or > durationDays (matured)

        // --- CASE: instrument has reached or passed maturity ---
        // Returns the face value: the amount repaid at maturity.
        if (daysElapsed >= durationDays) {
            return faceValue;
        }

        // --- STEP 1: Compute the issuance (discount) price ---
        // Simple formula (European straight-line ACT/365 method):
        //   IssuancePrice = FV / (1 + rate_decimal x duration/365)
        //   IssuancePrice = FV x 365 x BASE_POINTS / (365 x BASE_POINTS + rate x duration)
        //
        // Uses Math.mulDiv(a, b, c) = a*b/c without intermediate overflow.
        // numerator   = FV x (365 x 10000)
        // denominator = (365 x 10000) + (rate_bp x duration_days)
        //
        // Example: FV=1e24 (1M EUR x 1e18), rate=350bp, duration=90d
        //   num = 1e24 x 3650000 = 3.65e30 < 2^256 ? YES (2^256 ~ 1.15e77) -> OK
        //   den = 3650000 + (350 x 90) = 3650000 + 31500 = 3681500
        //   issuancePrice = 3.65e30 / 3681500 ~= 9.914e23 (991,400 EUR x 1e18)
        uint256 priceNumerator = DAYS_PER_YEAR * BASE_POINTS;
        uint256 priceDenominator = (DAYS_PER_YEAR * BASE_POINTS) + (annualRateBp * durationDays);

        uint256 issuancePrice = Math.mulDiv(faceValue, priceNumerator, priceDenominator);

        // --- STEP 2: Compute the discount ---
        // The discount is the total gain over the instrument's lifetime.
        // It will be amortized linearly over time.
        uint256 discount = faceValue - issuancePrice;
        // issuancePrice <= faceValue always holds (rate >= 0), so no underflow

        // --- STEP 3: Straight-line amortization of the discount ---
        // Amortized portion(t) = discount x (daysElapsed / durationDays)
        // In fixed point with Math.mulDiv to avoid overflow:
        // mulDiv(discount, daysElapsed, durationDays) = discount x daysElapsed / durationDays
        uint256 amortizedPortion = Math.mulDiv(discount, daysElapsed, durationDays);

        // --- STEP 4: Current value ---
        currentValue = issuancePrice + amortizedPortion;

        // Safety invariant (should never fail mathematically, but is
        // asserted to catch any calculation bug)
        assert(currentValue <= faceValue);
        assert(currentValue >= issuancePrice);

        return currentValue;
    }

    /// @notice Computes a detailed valuation result for a registered commercial paper instrument
    /// @param identifier ISIN of the commercial paper instrument
    /// @return result Complete structure with current value, accrued interest, etc.
    ///
    /// @dev View function: can be called for free, read-only.
    /// Used by the valuation agent to submit prices to the Fund.
    function calculateCommercialPaperValuation(bytes32 identifier)
        external
        view
        returns (ValuationResult memory result)
    {
        CommercialPaperParameters storage paper = _commercialPapers[identifier];
        require(paper.isActive, "TOOLBOX: Unknown or inactive commercial paper");

        uint256 nowTimestamp = block.timestamp;

        // Number of days elapsed since issuance.
        // Uses integer division (1 day = 86400 seconds)
        uint256 secondsElapsed = nowTimestamp > paper.issuanceDate
            ? nowTimestamp - paper.issuanceDate
            : 0;
        uint256 daysElapsed = secondsElapsed / 1 days;

        bool isMatured = nowTimestamp >= paper.maturityDate;

        // Current value calculation
        uint256 currentVal;
        if (isMatured) {
            // At maturity: value = face value (issuer repayment)
            currentVal = paper.faceValue;
        } else {
            // Recursive call to our own depreciation function
            currentVal = this.calculateLinearDepreciation(
                paper.faceValue,
                paper.yieldRateBp,
                paper.durationDays,
                daysElapsed
            );
        }

        // Accrued interest = current value - acquisition price
        // Measures the unrealized gain on the position
        uint256 accruedInterest = currentVal > paper.acquisitionPrice
            ? currentVal - paper.acquisitionPrice
            : 0;

        // Daily yield, in PRECISION units
        // = (annual rate bp / BASE_POINTS) / DAYS_PER_YEAR
        // = rate x PRECISION / (BASE_POINTS x DAYS_PER_YEAR)
        uint256 dailyYield = Math.mulDiv(
            paper.yieldRateBp * PRECISION,
            1,
            BASE_POINTS * DAYS_PER_YEAR
        );

        uint256 daysRemaining = isMatured
            ? 0
            : (paper.maturityDate - nowTimestamp) / 1 days;

        result = ValuationResult({
            currentValue:    currentVal,
            accruedInterest: accruedInterest,
            daysElapsed:     daysElapsed,
            daysRemaining:   daysRemaining,
            dailyYield:      dailyYield,
            isMatured:       isMatured
        });
    }

    // =========================================================================
    // MODULE 2 : FEE CALCULATION
    // =========================================================================

    /// @notice Computes transaction fees for a subscription or redemption
    /// @param amount Gross amount of the operation in EUR (18 decimals)
    /// @param operationType 0 = subscription, 1 = redemption
    /// @return fee Total fee to charge, in EUR (18 decimals)
    ///
    /// @dev View function: read-only access to the fee structure.
    /// Uses Math.mulDiv for precision on large amounts:
    ///   fee = amount x rateBp / BASE_POINTS
    ///   mulDiv prevents (amount x rateBp) from exceeding uint256 before division.
    function calculateFees(
        uint256 amount,
        uint8 operationType
    ) external view override returns (uint256 fee) {
        require(amount > 0,          "TOOLBOX: Zero amount for fee calculation");
        require(operationType <= 1,  "TOOLBOX: Invalid operation type (0=subscription, 1=redemption)");

        if (operationType == 0) {
            // --- SUBSCRIPTION: entry fee ---
            // Fee = amount x subscriptionFeeBp / 10,000
            fee = Math.mulDiv(amount, _fees.subscriptionFeeBp, BASE_POINTS);
        } else {
            // --- STANDARD REDEMPTION: exit fee ---
            fee = Math.mulDiv(amount, _fees.redemptionFeeBp, BASE_POINTS);
        }

        return fee;
    }

    /// @notice Computes redemption fees, distinguishing standard vs early redemption
    /// @param amount Redemption amount in EUR
    /// @param firstEntryTimestamp Investor's first-entry timestamp, as read by
    ///   the caller from TokenizedISIN.getShareholderRecord(investor).firstEntryTimestamp
    ///   (0 if the investor has never subscribed, i.e. lock-up not applicable).
    /// @return fee Total fee (standard or increased for an early redemption)
    /// @return isEarly True if the redemption occurs before the end of the lock-up
    function calculateFullRedemptionFees(
        uint256 amount,
        uint256 firstEntryTimestamp
    ) external view override returns (uint256 fee, bool isEarly) {
        require(amount > 0, "TOOLBOX: Zero amount");

        isEarly = (firstEntryTimestamp > 0 && block.timestamp < firstEntryTimestamp + LOCK_UP_PERIOD);

        if (isEarly) {
            // Early redemption: additional penalty on the full amount
            fee = Math.mulDiv(amount, _fees.earlyRedemptionPenaltyBp, BASE_POINTS);
        } else {
            // Standard redemption: normal exit fee
            fee = Math.mulDiv(amount, _fees.redemptionFeeBp, BASE_POINTS);
        }
    }

    /// @notice Computes prorata temporis ongoing management fees for a NAV cycle
    /// @param totalNetAssets Total net assets of the fund in EUR (18 decimals)
    /// @param cycleDurationSeconds Duration of the NAV cycle in seconds
    /// @return managementFee Prorata management fee in EUR
    /// @return custodyFee Prorata custody fee in EUR
    /// @return adminFee Prorata admin fee in EUR
    ///
    /// @dev Prorata formula: fee = NetAssets x (annualRate / 10000) x (duration / secondsPerYear)
    ///   Decomposed into two nested mulDiv calls to avoid overflow:
    ///   Step 1: annualFee = mulDiv(NetAssets, rateBp, BASE_POINTS)
    ///   Step 2: prorataFee = mulDiv(annualFee, durationSeconds, SECONDS_PER_YEAR)
    function calculateProrataOngoingFees(
        uint256 totalNetAssets,
        uint256 cycleDurationSeconds
    )
        external
        view
        override
        returns (
            uint256 managementFee,
            uint256 custodyFee,
            uint256 adminFee
        )
    {
        require(totalNetAssets > 0,             "TOOLBOX: Zero net assets");
        require(cycleDurationSeconds > 0,        "TOOLBOX: Zero cycle duration");
        require(cycleDurationSeconds <= 7 days,  "TOOLBOX: Excessive cycle duration (> 7 days)");

        // Management fee = NetAssets x managementRate/10000 x duration/365d
        managementFee = Math.mulDiv(
            Math.mulDiv(totalNetAssets, _fees.annualManagementFeeBp, BASE_POINTS),
            cycleDurationSeconds,
            SECONDS_PER_YEAR
        );

        // Custody fee = NetAssets x custodyRate/10000 x duration/365d
        custodyFee = Math.mulDiv(
            Math.mulDiv(totalNetAssets, _fees.annualCustodyFeeBp, BASE_POINTS),
            cycleDurationSeconds,
            SECONDS_PER_YEAR
        );

        // Admin fee = NetAssets x adminRate/10000 x duration/365d
        adminFee = Math.mulDiv(
            Math.mulDiv(totalNetAssets, _fees.annualAdminFeeBp, BASE_POINTS),
            cycleDurationSeconds,
            SECONDS_PER_YEAR
        );
    }

    /// @notice Computes performance fees under the High Water Mark mechanism
    /// @param currentNAVPerShare Current NAV per share in EUR (18 decimals)
    /// @param totalSharesOutstanding Total shares outstanding
    /// @return performanceFee Performance fee in EUR (0 if below HWM or hurdle)
    ///
    /// @dev HWM + hurdle rate algorithm:
    ///   1. If NAV <= HWM: no performance fee (not above the historical high)
    ///   2. Compute the hurdle accrued since the last HWM: hurdlePerShare = HWM x rate x time
    ///   3. If NAV <= HWM + hurdle: no fee (the rise is insufficient)
    ///   4. Otherwise: performanceFee = (NAV - HWM - hurdle) x shares x perfRate / BASE_POINTS
    function calculatePerformanceFees(
        uint256 currentNAVPerShare,
        uint256 totalSharesOutstanding
    ) external view override returns (uint256 performanceFee) {
        // No calculation if no shares are outstanding
        if (totalSharesOutstanding == 0) return 0;

        // If current NAV <= HWM: no performance fee
        if (currentNAVPerShare <= _highWaterMark.highValue) return 0;

        // Compute the hurdle rate accrued since the last HWM was established
        // hurdlePerShare = HWM x (hurdleRateBp/10000) x (timeElapsed / secondsPerYear)
        uint256 timeSinceHWM = block.timestamp > _highWaterMark.timestamp
            ? block.timestamp - _highWaterMark.timestamp
            : 0;

        uint256 hurdlePerShare = Math.mulDiv(
            Math.mulDiv(_highWaterMark.highValue, _fees.hurdleRateBp, BASE_POINTS),
            timeSinceHWM,
            SECONDS_PER_YEAR
        );

        // Minimum required NAV threshold: HWM + accrued hurdle
        uint256 minimumRequiredNAV = _highWaterMark.highValue + hurdlePerShare;

        // If NAV does not reach the required minimum: no fee
        if (currentNAVPerShare <= minimumRequiredNAV) return 0;

        // Outperformance per share = current NAV - (HWM + hurdle)
        uint256 outperformancePerShare = currentNAVPerShare - minimumRequiredNAV;

        // Performance fee = outperformance x shares x perfRate / BASE_POINTS
        // Decomposed into two mulDiv calls to avoid overflow:
        // Step 1: totalOutperformanceValue = (outperformance x shares) / PRECISION
        //   (divided by PRECISION because outperformance and shares are 18 dec)
        // Step 2: performanceFee = totalOutperformanceValue x rateBp / BASE_POINTS
        uint256 totalOutperformanceValue = Math.mulDiv(
            outperformancePerShare,
            totalSharesOutstanding,
            PRECISION
        );

        performanceFee = Math.mulDiv(totalOutperformanceValue, _fees.performanceFeeBp, BASE_POINTS);

        return performanceFee;
    }

    /// @notice Updates the High Water Mark if the current NAV establishes a new historical high
    /// @param currentNAVPerShare Current NAV per share
    /// @param navCycle Current NAV cycle number
    /// @dev Only the authorized Fund contract may call this function (onlyAuthorizedFund pattern)
    function updateHighWaterMark(
        uint256 currentNAVPerShare,
        uint256 navCycle
    ) external override onlyAuthorizedFund {
        if (currentNAVPerShare > _highWaterMark.highValue) {
            uint256 previousValue = _highWaterMark.highValue;

            _highWaterMark = HighWaterMark({
                highValue: currentNAVPerShare,
                timestamp: block.timestamp,
                navCycle:  navCycle
            });

            emit HighWaterMarkUpdated(
                previousValue,
                currentNAVPerShare,
                navCycle,
                block.timestamp
            );
        }
    }

    // =========================================================================
    // MODULE 3 : INVESTMENT STRATEGY AND PORTFOLIO REBALANCING
    // =========================================================================

    /// @notice Computes the portfolio adjustments needed to reach target allocations
    /// @param totalPortfolioValue Current total portfolio value in EUR (18 decimals)
    /// @param currentAllocations Current per-asset values in EUR (array, 18 dec)
    /// @param targetAllocations Target per-asset allocations in bp (array)
    /// @return adjustments Adjustments to make in EUR (signed: + = buy, - = sell)
    ///
    /// @dev Proportional rebalancing algorithm:
    ///   For each asset i:
    ///     targetValue(i) = totalValue x targetAllocation(i) / BASE_POINTS
    ///     adjustment(i) = targetValue(i) - currentValue(i)
    ///   Property: sum(adjustments) ~= 0 (balanced budget, max gap = rounding)
    ///   Positive adjustments = buy orders to route to the custodian
    ///   Negative adjustments = sell orders to route to the custodian
    ///
    /// @dev The function is pure (no storage access): it can be called from
    ///   any context, including by satellite contracts.
    function calculatePortfolioAdjustments(
        uint256 totalPortfolioValue,
        uint256[] calldata currentAllocations,
        uint256[] calldata targetAllocations
    ) external pure override returns (int256[] memory adjustments) {
        // --- CHECKS ---
        require(totalPortfolioValue > 0, "TOOLBOX: Zero total portfolio value");
        require(
            currentAllocations.length == targetAllocations.length,
            "TOOLBOX: Allocation arrays have different lengths"
        );
        require(
            currentAllocations.length > 0,
            "TOOLBOX: Empty portfolio"
        );
        require(
            currentAllocations.length <= MAX_PORTFOLIO_ASSETS,
            "TOOLBOX: Number of assets exceeds the allowed maximum (50)"
        );

        uint256 assetCount = currentAllocations.length;
        adjustments = new int256[](assetCount);

        // Verify that target allocations sum to 100% (+/- 1 bp)
        uint256 totalTargets = 0;
        for (uint256 i = 0; i < assetCount; i++) {
            totalTargets += targetAllocations[i];
        }
        require(
            totalTargets >= BASE_POINTS - 1 && totalTargets <= BASE_POINTS + 1,
            "TOOLBOX: Target allocations do not sum to 100% (+/- 1bp tolerance)"
        );

        // --- ADJUSTMENT CALCULATION ---
        for (uint256 i = 0; i < assetCount; i++) {
            // Target value = total portfolio value x target allocation (bp) / 10,000
            // Uses mulDiv to avoid overflow on large portfolios
            uint256 targetValue = Math.mulDiv(
                totalPortfolioValue,
                targetAllocations[i],
                BASE_POINTS
            );

            // Adjustment = target - current (sign: positive = buy, negative = sell)
            // SafeCast.toInt256() reverts if the value exceeds type(int256).max
            // Protection against implausibly large portfolios
            int256 signedTarget  = targetValue.toInt256();
            int256 signedCurrent = currentAllocations[i].toInt256();
            adjustments[i] = signedTarget - signedCurrent;
        }

        return adjustments;
    }

    /// @notice Checks whether rebalancing is needed given the configured tolerance
    /// @param currentAllocations Current per-asset values in EUR
    /// @param targetAllocations Target allocations in bp
    /// @param totalValue Total portfolio value in EUR
    /// @return needed True if at least one asset exceeds the tolerance threshold
    /// @return outOfToleranceIndex Index of the first out-of-tolerance asset (-1 if none)
    function checkRebalancingNeeded(
        uint256[] calldata currentAllocations,
        uint256[] calldata targetAllocations,
        uint256 totalValue
    ) external view returns (bool needed, int256 outOfToleranceIndex) {
        require(currentAllocations.length == targetAllocations.length, "TOOLBOX: Arrays have different lengths");
        require(totalValue > 0, "TOOLBOX: Zero total value");

        outOfToleranceIndex = -1; // -1 = no out-of-tolerance asset

        for (uint256 i = 0; i < currentAllocations.length; i++) {
            // Current allocation in bp = (currentValue / totalValue) x 10,000
            uint256 currentAllocationBp = Math.mulDiv(
                currentAllocations[i],
                BASE_POINTS,
                totalValue
            );

            // Absolute deviation in bp between current and target allocation
            uint256 deviation;
            if (currentAllocationBp > targetAllocations[i]) {
                deviation = currentAllocationBp - targetAllocations[i];
            } else {
                deviation = targetAllocations[i] - currentAllocationBp;
            }

            // If the deviation exceeds the tolerance: rebalancing is needed
            if (deviation > _strategy.deviationToleranceBp) {
                return (true, i.toInt256());
            }
        }

        return (false, -1);
    }

    // =========================================================================
    // MODULE 4 : REGULATORY COMPLIANCE VALIDATION
    // =========================================================================

    /// @notice Validates the compliance of an operation against fund rules
    /// @param investor Investor address
    /// @param amount Amount in EUR (subscription) or number of shares (redemption)
    /// @param operationType 0 = subscription, 1 = redemption
    /// @param amountAlreadyInvested Cumulative amount already invested by
    ///   `investor`, as read by the caller from
    ///   TokenizedISIN.getShareholderRecord(investor).amountInvested.
    ///   Ignored for redemptions.
    /// @return isValid True if all rules are respected
    ///
    /// @dev Rules checked:
    ///   SUBSCRIPTION:
    ///     [1] Amount >= MINIMUM_SUBSCRIPTION (100,000 EUR)
    ///     [2] amountAlreadyInvested + amount <= individual cap (10M EUR by default)
    ///   REDEMPTION:
    ///     [1] Amount > 0
    ///     [2] If before lock-up: non-blocking, a penalty will be applied
    ///
    ///   Note: KYC/AML whitelisting is handled by TokenizedISIN
    ///   (COMPLIANCE_ROLE / FUND_ROLE). The Toolbox validates the
    ///   complementary financial and regulatory criteria.
    function validateCompliance(
        address investor,
        uint256 amount,
        uint8 operationType,
        uint256 amountAlreadyInvested
    ) external view override returns (bool isValid) {
        // Common baseline validations
        if (investor == address(0)) return false;
        if (amount == 0) return false;
        if (operationType > 1) return false;

        if (operationType == 0) {
            // --- SUBSCRIPTION ---

            // Rule [1]: Institutional minimum amount
            if (amount < MINIMUM_SUBSCRIPTION) {
                // Note: a view function cannot emit an event.
                // Off-chain monitoring detects the rejection via the false return.
                return false;
            }

            // Rule [2]: Individual concentration cap
            // Checks that the cumulative amount does not exceed the configured cap
            uint256 cumulativeAmount = amountAlreadyInvested + amount;
            if (cumulativeAmount > _individualSubscriptionCapEUR) {
                return false;
            }

        } else {
            // --- REDEMPTION ---

            // Rule [1]: Redemption before lock-up is allowed but penalized
            // (non-blocking). The increased fee is computed by
            // calculateFullRedemptionFees(). We do not block early
            // redemption: the investor has the right to exit, but pays a
            // penalty to protect the remaining holders.

            // Rule [2]: Basic amount check
            if (amount == 0) return false;
        }

        return true;
    }

    /// @notice Computes whether the lock-up period has elapsed for an investor
    /// @param firstEntryTimestamp Investor's first-entry timestamp, as read by
    ///   the caller from TokenizedISIN.getShareholderRecord(investor).firstEntryTimestamp
    ///   (0 if the investor has never subscribed).
    /// @return isLockupElapsed True if the investor can redeem without penalty
    /// @return secondsRemaining Seconds remaining before the lock-up ends (0 if elapsed)
    function checkLockup(uint256 firstEntryTimestamp)
        external
        view
        override
        returns (bool isLockupElapsed, uint256 secondsRemaining)
    {
        if (firstEntryTimestamp == 0) {
            // Never subscribed: lock-up not applicable
            return (true, 0);
        }

        uint256 lockupEnd = firstEntryTimestamp + LOCK_UP_PERIOD;
        if (block.timestamp >= lockupEnd) {
            return (true, 0);
        } else {
            return (false, lockupEnd - block.timestamp);
        }
    }

    // =========================================================================
    // MODULE 5 : ADVANCED ACTUARIAL CALCULATIONS
    // =========================================================================
    // These functions are pure or view and can be called by any contract
    // (Fund, EMT, TokenizedAssets, TokenizedISIN) without restriction.

    /// @notice Computes simple interest (ACT/365, European convention)
    /// @param principal Initial amount in EUR (18 decimals)
    /// @param annualRateBp Annual interest rate in bp (e.g. 350 = 3.50%)
    /// @param numberOfDays Investment duration in calendar days
    /// @return finalAmount Amount after interest (18 decimals)
    /// @return interest Interest generated (18 decimals)
    ///
    /// @dev ACT/365 convention: interest = principal x rate x days / 365
    ///   Simple method (no compounding): appropriate for short-term
    ///   instruments (< 1 year). See calculateCompoundInterest for
    ///   compound interest. The simple-vs-compound gap for 1 year at 3.5%
    ///   is ~0.06% (negligible for an MMF).
    function calculateSimpleInterest(
        uint256 principal,
        uint256 annualRateBp,
        uint256 numberOfDays
    ) external pure returns (uint256 finalAmount, uint256 interest) {
        require(principal > 0,           "TOOLBOX: Zero principal");
        require(annualRateBp > 0,        "TOOLBOX: Zero rate");
        require(numberOfDays > 0,        "TOOLBOX: Zero duration");
        require(annualRateBp <= BASE_POINTS, "TOOLBOX: Rate above 100%");

        // Interest = Principal x (rateBp / BASE_POINTS) x (days / DAYS_PER_YEAR)
        // = mulDiv(principal x rateBp, days, BASE_POINTS x DAYS_PER_YEAR)
        // Decomposed into two mulDiv calls for readability:
        interest = Math.mulDiv(
            Math.mulDiv(principal, annualRateBp, BASE_POINTS),
            numberOfDays,
            DAYS_PER_YEAR
        );

        finalAmount = principal + interest;
    }

    /// @notice Computes interest with annual compounding (ICMA method)
    /// @param principal Initial amount in EUR (18 decimals)
    /// @param annualRateBp Annual interest rate in bp
    /// @param numberOfDays Investment duration in days
    /// @return finalAmount Amount after compounding (18 decimals)
    /// @return interest Cumulative interest generated (18 decimals)
    ///
    /// @dev Second-order Taylor approximation of (1+r)^(t/365):
    ///   (1+r)^t ~= 1 + r*t + r^2*t*(t-1)/2
    ///   For r < 10% and t < 2 years, the error is under 0.01%.
    ///   Method recommended by ICMA (International Capital Market Association).
    function calculateCompoundInterest(
        uint256 principal,
        uint256 annualRateBp,
        uint256 numberOfDays
    ) external pure returns (uint256 finalAmount, uint256 interest) {
        require(principal > 0, "TOOLBOX: Zero principal");
        require(annualRateBp > 0, "TOOLBOX: Zero rate");
        require(numberOfDays > 0, "TOOLBOX: Zero duration");
        require(annualRateBp <= BASE_POINTS, "TOOLBOX: Rate above 100%");

        // Term 1 (linear): r x t / 365 (equivalent to simple interest)
        uint256 term1 = Math.mulDiv(
            Math.mulDiv(principal, annualRateBp, BASE_POINTS),
            numberOfDays,
            DAYS_PER_YEAR
        );

        // Term 2 (quadratic): r^2 x t x (t-1) / (2 x 365^2)
        // Compounding correction: represents the "gain on the gain"
        // Significant for t > 180d or r > 5%
        //
        // BUGFIX: r2 must be computed at PRECISION (1e18) fixed-point scale.
        // annualRateBp/BASE_POINTS is a fraction (e.g. 500/10000 = 0.05); its
        // square (0.0025) cannot be represented as a raw, unscaled integer —
        // mulDiv(rateBp, rateBp, BASE_POINTS*BASE_POINTS) previously computed
        // exactly that, which truncates to 0 for every annualRateBp below
        // 10,000 (i.e. below 100%/yr), silently disabling this term for any
        // realistic rate and making calculateCompoundInterest() return
        // identical results to calculateSimpleInterest(). Fixed by scaling
        // the rate to PRECISION before squaring, matching the fixed-point
        // convention used everywhere else in this contract.
        uint256 term2 = 0;
        if (numberOfDays > 1) {
            // r, scaled to PRECISION: rScaled = rateBp x PRECISION / BASE_POINTS
            uint256 rScaled = Math.mulDiv(annualRateBp, PRECISION, BASE_POINTS);
            // r^2, still PRECISION-scaled: r2Scaled = rScaled^2 / PRECISION
            uint256 r2Scaled = Math.mulDiv(rScaled, rScaled, PRECISION);
            // term2 = principal x r2Scaled x t(t-1) / (2 x 365^2 x PRECISION)
            term2 = Math.mulDiv(
                Math.mulDiv(principal, r2Scaled, PRECISION),
                numberOfDays * (numberOfDays - 1),
                2 * DAYS_PER_YEAR * DAYS_PER_YEAR
            );
        }

        interest    = term1 + term2;
        finalAmount = principal + interest;
    }

    /// @notice Computes the annualized actuarial yield rate of an instrument
    /// @param purchasePrice Purchase price in EUR (18 decimals)
    /// @param redemptionValue Redemption (face) value in EUR (18 decimals)
    /// @param durationDays Holding duration in days
    /// @return yieldRateBp Annualized yield rate in basis points
    ///
    /// @dev Simple annualized yield formula (ACT/365):
    ///   rate (bp) = (RV - PP) / PP x 365 / duration x 10,000
    ///   Returns 0 if RV <= PP (zero or negative yield — negative market
    ///   rate scenario)
    function calculateYieldRate(
        uint256 purchasePrice,
        uint256 redemptionValue,
        uint256 durationDays
    ) external pure returns (uint256 yieldRateBp) {
        require(purchasePrice > 0, "TOOLBOX: Zero purchase price");
        require(durationDays > 0, "TOOLBOX: Zero duration");

        // Negative or zero yield: return 0
        // (incompatible with uint, should be flagged to the manager)
        if (redemptionValue <= purchasePrice) return 0;

        uint256 gain = redemptionValue - purchasePrice;

        // rate (bp) = gain/purchasePrice x (365/duration) x 10000
        // = mulDiv(gain x 365 x 10000, 1, purchasePrice x duration)
        // Robust formulation with mulDiv to avoid overflow:
        yieldRateBp = Math.mulDiv(
            gain * DAYS_PER_YEAR * BASE_POINTS,
            PRECISION,
            purchasePrice * durationDays
        ) / PRECISION;
        // Final division by PRECISION to cancel the amplification factor.
        // Cannot simplify PRECISION away because gain*365*10000 could overflow.
    }

    /// @notice Computes the value-weighted Macaulay duration of a portfolio of bullet instruments
    /// @param values Current value of each instrument (EUR, 18 dec)
    /// @param maturitiesDays Remaining maturity of each instrument in days
    /// @return weightedDurationDays Value-weighted portfolio duration in days
    ///
    /// @dev Macaulay duration for zero-coupon (bullet) instruments:
    ///   duration(i) = maturity(i) (all cash flow occurs at maturity)
    ///   Weighted duration = sum(value(i) x maturity(i)) / sum(value(i))
    ///
    ///   Relevance: duration measures the sensitivity of the portfolio's
    ///   value to a change in interest rates (+1% rate = -duration% value).
    ///   An MMF portfolio with a 90-day duration has a sensitivity of
    ///   0.25%/1%rate.
    function calculatePortfolioDuration(
        uint256[] calldata values,
        uint256[] calldata maturitiesDays
    ) external pure returns (uint256 weightedDurationDays) {
        require(values.length == maturitiesDays.length, "TOOLBOX: Arrays have different lengths");
        require(values.length > 0, "TOOLBOX: Empty portfolio");
        require(values.length <= MAX_PORTFOLIO_ASSETS, "TOOLBOX: Too many assets");

        uint256 sumValues = 0;
        uint256 sumValuesTimesMaturities = 0;

        for (uint256 i = 0; i < values.length; i++) {
            sumValues += values[i];
            // mulDiv(value, maturity, 1) = value x maturity (no division)
            // Uses mulDiv for consistency and overflow protection
            sumValuesTimesMaturities += Math.mulDiv(values[i], maturitiesDays[i], 1);
        }

        if (sumValues == 0) return 0;

        // Duration = sum(value x maturity) / sum(value)
        weightedDurationDays = sumValuesTimesMaturities / sumValues;
    }

    /// @notice Checks that portfolio duration respects the strategy's limit
    /// @param values Current values of the instruments
    /// @param maturitiesDays Remaining maturities
    /// @return withinLimit True if duration <= the strategy's limit
    /// @return currentDuration Computed duration in days
    function checkPortfolioDuration(
        uint256[] calldata values,
        uint256[] calldata maturitiesDays
    ) external view returns (bool withinLimit, uint256 currentDuration) {
        currentDuration = this.calculatePortfolioDuration(values, maturitiesDays);
        withinLimit = currentDuration <= _strategy.maxDurationDays;
    }

    // =========================================================================
    // MODULE 6 : ADVANCED NAV VALUATION CALCULATIONS
    // =========================================================================

    /// @notice Computes net NAV per share after deducting prorata ongoing fees
    /// @param grossNetAssets Gross net assets before fees (EUR, 18 dec)
    /// @param numberOfShares Number of shares outstanding
    /// @param cycleDurationSeconds Duration of the NAV cycle (seconds)
    /// @return netNAV Net NAV per share in EUR (18 decimals)
    /// @return totalFeesChargedThisCycle Total fees deducted for this cycle, in EUR
    function calculateNetNAV(
        uint256 grossNetAssets,
        uint256 numberOfShares,
        uint256 cycleDurationSeconds
    ) external view returns (uint256 netNAV, uint256 totalFeesChargedThisCycle) {
        require(grossNetAssets > 0, "TOOLBOX: Zero gross net assets");
        require(numberOfShares > 0, "TOOLBOX: Zero number of shares");
        require(cycleDurationSeconds > 0, "TOOLBOX: Zero cycle duration");

        // Compute the cycle's prorata ongoing fees
        (
            uint256 managementFee,
            uint256 custodyFee,
            uint256 adminFee
        ) = this.calculateProrataOngoingFees(grossNetAssets, cycleDurationSeconds);

        totalFeesChargedThisCycle = managementFee + custodyFee + adminFee;

        // Net assets after deducting ongoing fees
        uint256 netAssetsAfter = grossNetAssets > totalFeesChargedThisCycle
            ? grossNetAssets - totalFeesChargedThisCycle
            : 0;

        // NAV per share = net assets / number of shares (18 dec precision)
        netNAV = Math.mulDiv(netAssetsAfter, PRECISION, numberOfShares);
    }

    /// @notice Computes the number of shares to issue for a subscription amount
    /// @param subscriptionAmountEUR Net amount after fees, in EUR (18 dec)
    /// @param navPerShare NAV per share for the current cycle, in EUR (18 dec)
    /// @return numberOfShares Number of shares to issue (18 dec, rounded down)
    ///
    /// @dev Rounded down (floor): protects the fund.
    ///   The residual (the amount not covered by the last share) remains
    ///   in cash.
    ///   Example: 150,001 EUR subscription, NAV = 1,000 EUR
    ///     -> shares = 150,001 / 1,000 = 150.001 -> 150 shares issued
    ///     -> residual = 1 EUR remains in the fund's cash
    function calculateSharesToIssue(
        uint256 subscriptionAmountEUR,
        uint256 navPerShare
    ) external pure override returns (uint256 numberOfShares) {
        require(subscriptionAmountEUR > 0, "TOOLBOX: Zero subscription amount");
        require(navPerShare > 0,           "TOOLBOX: Zero NAV per share");

        // shares = (amount x PRECISION) / navPerShare
        // Multiplying by PRECISION compensates the division to preserve 18 dec
        numberOfShares = Math.mulDiv(subscriptionAmountEUR, PRECISION, navPerShare);
    }

    /// @notice Computes the gross EUR amount to pay out for a share redemption
    /// @param numberOfShares Number of shares to redeem (18 dec)
    /// @param navPerShare NAV per share for the current cycle (18 dec)
    /// @return grossAmountEUR Gross amount before deducting redemption fees (18 dec)
    function calculateRedemptionAmount(
        uint256 numberOfShares,
        uint256 navPerShare
    ) external pure override returns (uint256 grossAmountEUR) {
        require(numberOfShares > 0, "TOOLBOX: Zero number of shares");
        require(navPerShare > 0,    "TOOLBOX: Zero NAV per share");

        // amount = (numberOfShares x navPerShare) / PRECISION
        // Divided by PRECISION because both operands are 18 dec
        grossAmountEUR = Math.mulDiv(numberOfShares, navPerShare, PRECISION);
    }

    // =========================================================================
    // MODULE 7 : TOOLBOX ADMINISTRATION
    // =========================================================================

    /// @notice Registers a commercial paper instrument for amortized valuation tracking
    /// @param identifier ISIN or internal identifier (bytes32)
    /// @param faceValue Face value (repayment at maturity), in EUR
    /// @param acquisitionPrice Acquisition price, in EUR
    /// @param yieldRateBp Annualized actuarial yield rate, in bp
    /// @param issuanceDate Unix timestamp of the issuance date
    /// @param maturityDate Unix timestamp of the maturity date
    ///
    /// @dev CEI pattern applied: all checks before state changes. Thin
    ///   wrapper around _registerCommercialPaper() so that
    ///   initializePOCCommercialPapers() below can reuse the exact same
    ///   checks/effects/event without re-entering this nonReentrant
    ///   external function via a self-call (which would revert).
    function registerCommercialPaper(
        bytes32 identifier,
        uint256 faceValue,
        uint256 acquisitionPrice,
        uint256 yieldRateBp,
        uint256 issuanceDate,
        uint256 maturityDate
    )
        external
        onlyRole(MANAGER_ROLE)
        whenNotPaused
        nonReentrant
    {
        _registerCommercialPaper(identifier, faceValue, acquisitionPrice, yieldRateBp, issuanceDate, maturityDate);
    }

    /// @dev Shared implementation for registerCommercialPaper() and
    ///   initializePOCCommercialPapers(). See registerCommercialPaper() for
    ///   parameter documentation.
    function _registerCommercialPaper(
        bytes32 identifier,
        uint256 faceValue,
        uint256 acquisitionPrice,
        uint256 yieldRateBp,
        uint256 issuanceDate,
        uint256 maturityDate
    ) internal {
        // --- CHECKS ---
        require(identifier != bytes32(0),                    "TOOLBOX: Zero identifier");
        require(faceValue > 0,                                "TOOLBOX: Zero face value");
        require(acquisitionPrice > 0,                         "TOOLBOX: Zero acquisition price");
        require(acquisitionPrice <= faceValue,                "TOOLBOX: Price > face value (impossible for a discount instrument)");
        require(yieldRateBp > 0,                              "TOOLBOX: Zero yield rate");
        require(yieldRateBp < BASE_POINTS,                    "TOOLBOX: Implausible yield rate (>= 100%)");
        require(issuanceDate < maturityDate,                  "TOOLBOX: Issuance date is after maturity date");
        require(maturityDate > block.timestamp,               "TOOLBOX: Instrument already matured at registration time");
        require(!_commercialPapers[identifier].isActive,      "TOOLBOX: Instrument already registered - use an update instead");

        uint256 durationDays = (maturityDate - issuanceDate) / 1 days;
        require(durationDays > 0,   "TOOLBOX: Duration under 1 day");
        require(durationDays <= 365, "TOOLBOX: Duration > 365 days - outside NEU CP scope (max 1-year maturity)");

        // --- EFFECTS ---
        _commercialPapers[identifier] = CommercialPaperParameters({
            identifier:       identifier,
            faceValue:        faceValue,
            acquisitionPrice: acquisitionPrice,
            yieldRateBp:      yieldRateBp,
            issuanceDate:     issuanceDate,
            maturityDate:     maturityDate,
            durationDays:     durationDays,
            isActive:         true
        });

        _paperIdentifierList.push(identifier);

        emit CommercialPaperRegistered(
            identifier,
            faceValue,
            yieldRateBp,
            durationDays,
            block.timestamp
        );
        // No INTERACTIONS: no external call in this function
    }

    /// @notice Computes the discount-to-maturity for a discount instrument
    ///   directly from its face value/quantity and purchase price — no
    ///   separately-supplied acquisition price needed.
    /// @param quantity Face value / nominal quantity, EUR (18 dec) — "Qté"
    /// @param purchasePriceRatio Price paid, as a fraction of par
    ///   (PRECISION = 100%, e.g. 0.98125e18 for 98.125%) — "Prix d'achat"
    /// @return discount quantity - (quantity x purchasePriceRatio / PRECISION)
    ///   — the worksheet's "Rendement à maturité" column. Literally "the
    ///   difference between 100% and the purchase price, times the
    ///   quantity."
    /// @dev Uses a PRECISION-scaled ratio (not basis points): a price like
    ///   98.125% is 9,812.5 bp — not representable at whole-bp granularity
    ///   — but is exact at 18-decimal PRECISION (0.98125e18).
    function calculateDiscountFromPrice(uint256 quantity, uint256 purchasePriceRatio)
        public
        pure
        returns (uint256 discount)
    {
        require(quantity > 0, "TOOLBOX: Zero quantity");
        require(purchasePriceRatio > 0 && purchasePriceRatio <= PRECISION, "TOOLBOX: Invalid purchase price ratio");

        uint256 netAmountPaid = Math.mulDiv(quantity, purchasePriceRatio, PRECISION);
        discount = quantity - netAmountPaid;
    }

    /// @notice Computes the constant per-second straight-line yield rate for
    ///   a discount instrument directly from its quantity, purchase price,
    ///   and tenor — no on-chain registration required. Same "boite a
    ///   outils" math as calculateYieldToolbox() below, but callable for
    ///   any hypothetical instrument, not just an already-registered one.
    /// @param quantity Face value, EUR (18 dec)
    /// @param purchasePriceRatio Price paid, as a fraction of par (PRECISION = 100%)
    /// @param durationDays Full tenor in days (issuance -> maturity)
    /// @return yieldPerSecond discount / (durationDays x 1 days), EUR/sec (18 dec)
    ///   — the worksheet's "rendement à la seconde" column.
    function calculateYieldPerSecondFromPrice(
        uint256 quantity,
        uint256 purchasePriceRatio,
        uint256 durationDays
    ) external pure returns (uint256 yieldPerSecond) {
        require(durationDays > 0, "TOOLBOX: Zero duration");
        uint256 discount = calculateDiscountFromPrice(quantity, purchasePriceRatio);
        yieldPerSecond = discount / (durationDays * 1 days);
    }

    /// @dev Shared implementation for initializePOCCommercialPapers():
    ///   derives acquisitionPrice from quantity + purchasePriceRatio via
    ///   calculateDiscountFromPrice() instead of taking it as a separately
    ///   hardcoded literal — the 5,000 / 7,500 / 37,500 EUR discounts (and
    ///   the 495,000 / 492,500 / 1,962,500 EUR acquisition prices behind
    ///   them) are now computed ON-CHAIN, not pre-computed off-chain and
    ///   hardcoded as magic numbers.
    function _registerPOCPaperFromPrice(
        bytes32 identifier,
        uint256 quantity,
        uint256 purchasePriceRatio,
        uint256 yieldRateBp,
        uint256 issuanceDate,
        uint256 maturityDate
    ) internal {
        uint256 discount = calculateDiscountFromPrice(quantity, purchasePriceRatio);
        uint256 acquisitionPrice = quantity - discount;
        _registerCommercialPaper(identifier, quantity, acquisitionPrice, yieldRateBp, issuanceDate, maturityDate);
    }

    /// @notice One-time POC seeding: registers the three demo commercial
    ///   papers from the fund's origination worksheet — POC CP 2%, POC CP
    ///   2.5%, and POC CP 3%. Safe to call once; reverts on any subsequent
    ///   call.
    /// @dev Trade date 24/07/2026 00:00:00 UTC (1784851200), maturity
    ///   31/12/2026 00:00:00 UTC (1798675200) — a 160-day tenor for all
    ///   three instruments, matching the worksheet's "nbre de jours avt
    ///   maturité" column exactly. Each paper's acquisition price (and
    ///   therefore its discount — the worksheet's "Rendement à maturité"
    ///   column: 5,000 / 7,500 / 37,500 EUR, 50,000 EUR total /
    ///   "Montant à linéariser") is derived on-chain by
    ///   _registerPOCPaperFromPrice() from just the quantity and purchase
    ///   price below — only the worksheet's "Qté" and "Prix d'achat"
    ///   columns are hardcoded here; "Montant net" is not.
    function initializePOCCommercialPapers() external onlyRole(MANAGER_ROLE) whenNotPaused nonReentrant {
        require(!pocCommercialPapersInitialized, "TOOLBOX: POC commercial papers already initialized");
        pocCommercialPapersInitialized = true;

        uint256 tradeDate    = 1784851200; // 24/07/2026 00:00:00 UTC
        uint256 maturityDate = 1798675200; // 31/12/2026 00:00:00 UTC

        // POC CP 2%   — 500,000 EUR face value, bought at 99.000% of par
        _registerPOCPaperFromPrice(
            POC_CP_2PCT_ID,
            500_000 * PRECISION,       // quantity ("Qté")
            99 * PRECISION / 100,      // purchasePriceRatio = 99.000% of par
            200,                        // yieldRateBp = 2.00%
            tradeDate,
            maturityDate
        );

        // POC CP 2.5% — 500,000 EUR face value, bought at 98.500% of par
        _registerPOCPaperFromPrice(
            POC_CP_2_5PCT_ID,
            500_000 * PRECISION,
            985 * PRECISION / 1000,    // purchasePriceRatio = 98.500% of par
            250,                        // yieldRateBp = 2.50%
            tradeDate,
            maturityDate
        );

        // POC CP 3%   — 2,000,000 EUR face value, bought at 98.125% of par
        _registerPOCPaperFromPrice(
            POC_CP_3PCT_ID,
            2_000_000 * PRECISION,
            98125 * PRECISION / 100000, // purchasePriceRatio = 98.125% of par
            300,                          // yieldRateBp = 3.00%
            tradeDate,
            maturityDate
        );
    }

    // =========================================================================
    // MODULE 7B : "BOITE A OUTILS" — REAL-TIME LINEAR YIELD BREAKDOWN
    // =========================================================================
    // Reproduces the fund's origination worksheet's right-hand "boite à
    // outils" table: for a straight-line-amortized discount instrument, the
    // total discount to be earned by maturity is spread evenly over its
    // ENTIRE original tenor (from issuance to maturity), expressed as a
    // constant EUR-per-second rate. This is a fixed rate derived once from
    // the paper's registered parameters — not a live countdown recomputed
    // against block.timestamp — exactly mirroring how the worksheet's
    // "nbre de secondes avant maturité" / "rendement à la seconde" columns
    // are computed once from the trade date, not re-derived every time the
    // sheet is opened.

    /// @notice Real-time "boite a outils" yield breakdown for a single
    ///   registered commercial paper.
    /// @param identifier ISIN / internal identifier of the registered paper
    /// @return discountAtMaturity Face value minus acquisition price (EUR, 18 dec)
    ///   — the worksheet's "Rendement à maturité" column.
    /// @return daysToMaturity Full original tenor in days (issuance -> maturity)
    ///   — the worksheet's "nbre de jours avt maturité" column.
    /// @return minutesToMaturity Full original tenor in minutes
    ///   — the worksheet's "nombre de minutes avt maturité" column.
    /// @return secondsToMaturity Full original tenor in seconds
    ///   — the worksheet's "nombre de seconde avant maturité" column.
    /// @return yieldPerSecond discountAtMaturity / secondsToMaturity (EUR/sec, 18 dec)
    ///   — the worksheet's "rendement à la seconde" column.
    function calculateYieldToolbox(bytes32 identifier)
        external
        view
        returns (
            uint256 discountAtMaturity,
            uint256 daysToMaturity,
            uint256 minutesToMaturity,
            uint256 secondsToMaturity,
            uint256 yieldPerSecond
        )
    {
        CommercialPaperParameters storage paper = _commercialPapers[identifier];
        require(paper.isActive, "TOOLBOX: Unknown or inactive commercial paper");

        discountAtMaturity = paper.faceValue - paper.acquisitionPrice;
        daysToMaturity      = paper.durationDays;
        minutesToMaturity    = paper.durationDays * 1440;
        secondsToMaturity    = paper.durationDays * 1 days;
        yieldPerSecond       = discountAtMaturity / secondsToMaturity;
    }

    /// @notice Portfolio-level aggregation of calculateYieldToolbox() across
    ///   every ACTIVE registered commercial paper.
    /// @return totalDiscountToLinearize Sum of (faceValue - acquisitionPrice)
    ///   across all active papers — the worksheet's "Montant à linéariser"
    ///   total row (50,000 EUR for the three POC papers).
    /// @return totalYieldPerSecond Sum of each paper's per-second
    ///   straight-line yield — the worksheet's bottom-right total
    ///   (≈0.003616898 EUR/sec for the three POC papers).
    /// @dev Gas-bounded by MAX_PORTFOLIO_ASSETS, same iteration pattern as
    ///   the existing readPaperList().
    function calculatePortfolioYieldToolbox()
        external
        view
        returns (uint256 totalDiscountToLinearize, uint256 totalYieldPerSecond)
    {
        for (uint256 i = 0; i < _paperIdentifierList.length; i++) {
            CommercialPaperParameters storage paper = _commercialPapers[_paperIdentifierList[i]];
            if (!paper.isActive) continue;

            uint256 discount = paper.faceValue - paper.acquisitionPrice;
            totalDiscountToLinearize += discount;
            totalYieldPerSecond      += discount / (paper.durationDays * 1 days);
        }
    }

    /// @notice Updates the fee structure in effect
    /// @dev Hard-coded safety caps prevent fraudulent configurations.
    ///   These caps are inspired by AMF limits for French-law funds.
    function updateFees(
        uint256 subscriptionFeeBp,
        uint256 redemptionFeeBp,
        uint256 annualManagementFeeBp,
        uint256 performanceFeeBp,
        uint256 hurdleRateBp,
        uint256 annualCustodyFeeBp,
        uint256 annualAdminFeeBp,
        uint256 earlyRedemptionPenaltyBp
    )
        external
        onlyRole(FEE_ADMIN_ROLE)
        whenNotPaused
        nonReentrant
    {
        // --- CHECKS: hard-coded anti-fraud safety caps ---
        // These caps are hard-coded guardrails that cannot be modified
        // after deployment (they live in bytecode, not storage).
        require(subscriptionFeeBp        <= 500,   "TOOLBOX: Entry fee > 5% - Rejected for safety");
        require(redemptionFeeBp          <= 500,   "TOOLBOX: Exit fee > 5% - Rejected");
        require(annualManagementFeeBp    <= 500,   "TOOLBOX: Management fee > 5%/yr - Rejected");
        require(performanceFeeBp         <= 3_000, "TOOLBOX: Performance fee > 30% - Rejected");
        require(hurdleRateBp             <= 2_000, "TOOLBOX: Hurdle rate > 20%/yr - Rejected");
        require(annualCustodyFeeBp       <= 100,   "TOOLBOX: Custody fee > 1%/yr - Rejected");
        require(annualAdminFeeBp         <= 200,   "TOOLBOX: Admin fee > 2%/yr - Rejected");
        require(earlyRedemptionPenaltyBp <= 500,   "TOOLBOX: Early redemption penalty > 5% - Rejected");

        // --- EFFECTS ---
        _fees = FeeStructure({
            subscriptionFeeBp:        subscriptionFeeBp,
            redemptionFeeBp:          redemptionFeeBp,
            annualManagementFeeBp:    annualManagementFeeBp,
            performanceFeeBp:         performanceFeeBp,
            hurdleRateBp:             hurdleRateBp,
            annualCustodyFeeBp:       annualCustodyFeeBp,
            annualAdminFeeBp:         annualAdminFeeBp,
            earlyRedemptionPenaltyBp: earlyRedemptionPenaltyBp,
            lastUpdateTimestamp:      block.timestamp
        });

        emit FeesUpdated(
            subscriptionFeeBp,
            redemptionFeeBp,
            annualManagementFeeBp,
            performanceFeeBp,
            block.timestamp,
            msg.sender
        );
        // No INTERACTIONS: no external call
    }

    /// @notice Updates the investment strategy
    /// @dev Allocations must sum to exactly 10,000 bp (enforced by the modifier).
    ///   A minimum 10% cash allocation is enforced to protect the fund's liquidity.
    function updateStrategy(
        uint256 commercialPaperAllocationBp,
        uint256 bondAllocationBp,
        uint256 equityAllocationBp,
        uint256 cashAllocationBp,
        uint256 deviationToleranceBp,
        uint256 maxDurationDays,
        uint8   minRating
    )
        external
        onlyRole(MANAGER_ROLE)
        whenNotPaused
        nonReentrant
        targetAllocationsSum100Percent(
            commercialPaperAllocationBp,
            bondAllocationBp,
            equityAllocationBp,
            cashAllocationBp
        )
    {
        // --- CHECKS ---
        require(deviationToleranceBp >= 10,
            "TOOLBOX: Deviation tolerance < 0.1bp - Too restrictive (excessive gas)");
        require(deviationToleranceBp <= 1_000,
            "TOOLBOX: Deviation tolerance > 10% - Too permissive (drift risk)");
        require(maxDurationDays >= 1,
            "TOOLBOX: Max duration < 1 day - Impossible");
        require(maxDurationDays <= 730,
            "TOOLBOX: Max duration > 2 years - Incompatible with a short-term MMF/AIF profile");
        require(minRating >= 1 && minRating <= 7,
            "TOOLBOX: Invalid rating code (1=AAA ... 7=BBB-)");
        require(cashAllocationBp >= MIN_LIQUIDITY_RATIO_BP,
            "TOOLBOX: Cash allocation < 10% - Unacceptable liquidity risk (AMF)");

        // --- EFFECTS ---
        _strategy = InvestmentStrategy({
            commercialPaperAllocationBp: commercialPaperAllocationBp,
            bondAllocationBp:            bondAllocationBp,
            equityAllocationBp:          equityAllocationBp,
            cashAllocationBp:            cashAllocationBp,
            deviationToleranceBp:        deviationToleranceBp,
            maxDurationDays:             maxDurationDays,
            minCounterpartyRating:       minRating,
            lastUpdateTimestamp:         block.timestamp
        });

        emit StrategyUpdated(
            commercialPaperAllocationBp,
            bondAllocationBp,
            deviationToleranceBp,
            maxDurationDays,
            block.timestamp,
            msg.sender
        );
        // No INTERACTIONS
    }

    /// @notice Updates the individual subscription cap
    /// @param newCapEUR New cap in EUR (18 dec)
    function updateSubscriptionCap(
        uint256 newCapEUR
    ) external onlyRole(COMPLIANCE_ROLE) {
        require(newCapEUR >= MINIMUM_SUBSCRIPTION,
            "TOOLBOX: Cap below the institutional minimum subscription amount");

        uint256 previousCap = _individualSubscriptionCapEUR;
        _individualSubscriptionCapEUR = newCapEUR;

        emit SubscriptionCapUpdated(previousCap, newCapEUR, block.timestamp);
    }

    /// @notice Emergency pause of the Toolbox (regulatory circuit breaker)
    function pauseToolbox() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Resumes operation after a pause (requires ADMIN_ROLE)
    function unpauseToolbox() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // =========================================================================
    // READ (VIEW) FUNCTIONS — TRANSPARENCY AND AUDITABILITY
    // =========================================================================
    // All these functions are view (free, read-only). They let auditors,
    // valuation agents, and off-chain systems access the parameters in
    // effect without gas cost.

    /// @notice Returns the fee structure in effect
    function readFeeStructure() external view returns (FeeStructure memory) {
        return _fees;
    }

    /// @notice Returns the investment strategy in effect
    function readStrategy() external view returns (InvestmentStrategy memory) {
        return _strategy;
    }

    /// @notice Cash allocation of the current investment strategy, in bp.
    /// @dev Scalar counterpart of readStrategy().cashAllocationBp, exposed
    ///   directly through IToolbox so external callers (e.g. the fund
    ///   contract) don't need to know Toolbox's internal struct layout.
    function readCashAllocationBp() external view override returns (uint256) {
        return _strategy.cashAllocationBp;
    }

    /// @notice Returns the current High Water Mark
    function readHighWaterMark() external view returns (HighWaterMark memory) {
        return _highWaterMark;
    }

    /// @notice Returns the parameters of a commercial paper instrument
    function readCommercialPaper(bytes32 identifier)
        external
        view
        returns (CommercialPaperParameters memory)
    {
        return _commercialPapers[identifier];
    }

    /// @notice Returns the list of all registered paper identifiers
    function readPaperList() external view returns (bytes32[] memory) {
        return _paperIdentifierList;
    }

    /// @notice Returns the portfolio deviation tolerance (bp)
    function readDeviationTolerance() external view returns (uint256) {
        return _strategy.deviationToleranceBp;
    }

    /// @notice Returns the maximum duration allowed by the strategy (days)
    function readMaxAllowedDuration() external view returns (uint256) {
        return _strategy.maxDurationDays;
    }

    /// @notice Returns the total annual ongoing fees, in bp (excluding performance fee)
    /// @dev Useful for computing the fund's TER (Total Expense Ratio)
    function readTotalAnnualOngoingFeesBp() external view returns (uint256) {
        return _fees.annualManagementFeeBp
             + _fees.annualCustodyFeeBp
             + _fees.annualAdminFeeBp;
    }

    /// @notice Returns the individual subscription cap (EUR, 18 dec)
    function readIndividualSubscriptionCap() external view override returns (uint256) {
        return _individualSubscriptionCapEUR;
    }
}
