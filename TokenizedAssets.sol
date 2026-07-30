// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title TokenizedAssets - ERC20 token (Tokenized Assets) v2.0
/// @notice This contract implements a standard ERC20 token representing the
///   tokenized securities ("titres") held in the fund's portfolio.
/// @dev TokenizedAssets sits on the ASSET side of the fund's balance sheet.
///   The fund contract is expected to become the "owner" of this contract so
///   it can mint one token when it buys a security and burn one token when
///   it sells it, with the fund itself holding the balance (address(this)).
///
///  PHASE 2 UPDATES:
///  - Added PRECISION constant (1e18) for consistency with Toolbox
///  - Added price tracking for multi-asset portfolio support
///  - Added asset metadata (ISIN, name, asset class) for each token type
///  - Added fundContract reference for enhanced integration
///  - Added enhanced events with reason codes
///  - Added asset valuation helper for NAV calculations
contract TokenizedAssets {
    // ----------- Token metadata -----------
    string public name = "Tokenized Assets";
    string public symbol = "TKA";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    /// @notice Fixed-point precision: 18 decimals (1 unit = 1e18)
    /// Aligned with Toolbox.PRECISION and EMT.PRECISION.
    uint256 public constant PRECISION = 1e18;

    // ----------- Owner (for mint/burn) -----------
    address public owner;

    /// @notice Reference to the fund contract for enhanced integration
    address public fundContract;

    // ----------- Asset Metadata (Phase 2 - Multi-Asset Support) -----------

    /// @notice Metadata for each asset type tracked by this contract
    /// @dev In Phase 2, the fund can hold multiple security types.
    ///   Each asset type has a unique identifier and pricing information.
    ///   Fields below quantity/tradeDate/maturityDate/purchasePriceRatio/
    ///   netAmountPaid are populated for commercial-paper-style discount
    ///   instruments (registered via registerCommercialPaperAsset()); they
    ///   remain at their zero value for simple assets registered via the
    ///   original registerAsset().
    struct AssetMetadata {
        bytes32 assetId;           // Unique identifier (e.g., keccak256(ISIN))
        string assetName;          // Human-readable name
        string assetClass;         // "NEU_CP", "BOND", "EQUITY", etc.
        uint256 unitPrice;         // Current price per unit in EUR (PRECISION)
        uint256 lastPriceUpdate;   // Timestamp of last price update
        bool isActive;             // Whether this asset type is currently held
        uint256 quantity;          // Face value / nominal quantity, EUR (PRECISION) — "Qté"
        uint256 tradeDate;         // Unix timestamp of purchase — "Trade date"
        uint256 maturityDate;      // Unix timestamp of maturity — "Maturité"
        uint256 purchasePriceRatio;// Price paid, as a fraction of par (PRECISION = 100%) — "Prix d'achat"
        uint256 netAmountPaid;     // Total amount actually paid, EUR (PRECISION) — "Montant net"
    }

    /// @notice Mapping from asset ID to its metadata
    mapping(bytes32 => AssetMetadata) public assetMetadata;

    /// @notice List of all registered asset IDs (for iteration)
    bytes32[] public assetList;

    /// @notice True once initializePOCCommercialPapers() has run. Guards
    ///   against seeding the three demo commercial papers more than once.
    bool public pocCommercialPapersInitialized;

    /// @notice Identifiers for the three demo commercial papers from the
    ///   fund's origination worksheet (trade date 24/07/2026, maturity
    ///   31/12/2026). Mirrored on the Toolbox side by the identically-named
    ///   constants in Toolbox.sol, so both contracts reference the same
    ///   instruments under the same identifiers.
    bytes32 public constant POC_CP_2PCT_ID   = keccak256("POC CP 2%");
    bytes32 public constant POC_CP_2_5PCT_ID = keccak256("POC CP 2.5%");
    bytes32 public constant POC_CP_3PCT_ID   = keccak256("POC CP 3%");

    /// @notice Mapping from holder address to their asset balances by asset ID
    /// @dev For the fund contract, this tracks which assets are held.
    mapping(address => mapping(bytes32 => uint256)) public assetBalances;

    // ----------- Balances and allowances -----------
    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;

    // ----------- Events -----------
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed tokenOwner, address indexed spender, uint256 value);
    event Mint(address indexed to, uint256 value, string reason, uint256 timestamp);
    event Burn(address indexed from, uint256 value, string reason, uint256 timestamp);
    event FundContractSet(address indexed previousFund, address indexed newFund, uint256 timestamp);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner, uint256 timestamp);

    /// @notice Emitted when an asset type is registered
    event AssetRegistered(
        bytes32 indexed assetId,
        string assetName,
        string assetClass,
        uint256 initialPrice,
        uint256 timestamp
    );

    /// @notice Emitted when a commercial-paper-style asset is registered
    ///   with full origination details.
    event CommercialPaperAssetRegistered(
        bytes32 indexed assetId,
        string assetName,
        uint256 quantity,
        uint256 tradeDate,
        uint256 maturityDate,
        uint256 purchasePriceRatio,
        uint256 netAmountPaid,
        uint256 timestamp
    );

    /// @notice Emitted when an asset price is updated
    event AssetPriceUpdated(
        bytes32 indexed assetId,
        uint256 previousPrice,
        uint256 newPrice,
        uint256 timestamp
    );

    // ----------- Modifiers -----------
    modifier onlyOwner() {
        require(msg.sender == owner, "TokenizedAssets: caller is not authorized");
        _;
    }

    constructor(uint256 initialSupply) {
        owner = msg.sender;
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply, "INITIAL_SUPPLY", bytes32(0));
        }
    }

    // ----------- Fund Integration -----------

    /// @notice Sets the fund contract reference
    function setFundContract(address fundAddress) external onlyOwner {
        require(fundAddress != address(0), "TokenizedAssets: invalid fund address");
        address previousFund = fundContract;
        fundContract = fundAddress;
        emit FundContractSet(previousFund, fundAddress, block.timestamp);
    }

    // ----------- Asset Management (Phase 2) -----------

    /// @notice Registers a new asset type in the portfolio
    /// @param assetId Unique identifier for the asset (e.g., keccak256(ISIN))
    /// @param assetName Human-readable name of the asset
    /// @param assetClass Asset class category ("NEU_CP", "BOND", "EQUITY", "CASH")
    /// @param initialPrice Initial price per unit in EUR (PRECISION)
    /// @dev Called by the fund when purchasing a new security type for the first time.
    ///   For commercial-paper-style discount instruments with full
    ///   origination details (quantity, trade date, maturity, purchase
    ///   price, net amount), use registerCommercialPaperAsset() instead.
    function registerAsset(
        bytes32 assetId,
        string calldata assetName,
        string calldata assetClass,
        uint256 initialPrice
    ) external onlyOwner {
        require(assetId != bytes32(0), "TokenizedAssets: invalid asset ID");
        require(initialPrice > 0, "TokenizedAssets: invalid initial price");
        require(!assetMetadata[assetId].isActive, "TokenizedAssets: asset already registered");

        assetMetadata[assetId] = AssetMetadata({
            assetId: assetId,
            assetName: assetName,
            assetClass: assetClass,
            unitPrice: initialPrice,
            lastPriceUpdate: block.timestamp,
            isActive: true,
            quantity: 0,
            tradeDate: 0,
            maturityDate: 0,
            purchasePriceRatio: 0,
            netAmountPaid: 0
        });

        assetList.push(assetId);
        emit AssetRegistered(assetId, assetName, assetClass, initialPrice, block.timestamp);
    }

    /// @notice Registers a commercial-paper-style discount instrument with
    ///   full origination details, mirroring the fund's origination
    ///   worksheet's left-hand table (Qté, Nom, Maturité, Trade date, Prix
    ///   d'achat, Montant net).
    /// @param assetId Unique identifier for the asset (e.g., keccak256(name) or keccak256(ISIN))
    /// @param assetName Human-readable name (e.g. "POC CP 2%") — "Nom"
    /// @param quantity Face value / nominal quantity, EUR (PRECISION) — "Qté"
    /// @param tradeDate Unix timestamp of purchase — "Trade date"
    /// @param maturityDate Unix timestamp of maturity — "Maturité"
    /// @param purchasePriceRatio Price paid, as a fraction of par
    ///   (PRECISION = 100%, e.g. 0.99e18 for 99.000%) — "Prix d'achat"
    /// @param netAmountPaid Total amount actually paid, EUR (PRECISION) — "Montant net"
    /// @dev The starting mark-to-market unitPrice is set to
    ///   purchasePriceRatio (the instrument is worth what was paid for it
    ///   at trade date); it is expected to rise toward PRECISION (par) as
    ///   maturity approaches, via updateAssetPrice() driven by
    ///   Toolbox.calculateYieldToolbox()'s straight-line amortization.
    function registerCommercialPaperAsset(
        bytes32 assetId,
        string calldata assetName,
        uint256 quantity,
        uint256 tradeDate,
        uint256 maturityDate,
        uint256 purchasePriceRatio,
        uint256 netAmountPaid
    ) external onlyOwner {
        _registerCommercialPaperAsset(assetId, assetName, quantity, tradeDate, maturityDate, purchasePriceRatio, netAmountPaid);
    }

    /// @dev Shared implementation for registerCommercialPaperAsset() and
    ///   initializePOCCommercialPapers(). See registerCommercialPaperAsset()
    ///   for parameter documentation.
    function _registerCommercialPaperAsset(
        bytes32 assetId,
        string memory assetName,
        uint256 quantity,
        uint256 tradeDate,
        uint256 maturityDate,
        uint256 purchasePriceRatio,
        uint256 netAmountPaid
    ) internal {
        require(assetId != bytes32(0), "TokenizedAssets: invalid asset ID");
        require(quantity > 0, "TokenizedAssets: invalid quantity");
        require(tradeDate < maturityDate, "TokenizedAssets: trade date must precede maturity");
        require(purchasePriceRatio > 0 && purchasePriceRatio <= PRECISION, "TokenizedAssets: invalid purchase price ratio");
        require(!assetMetadata[assetId].isActive, "TokenizedAssets: asset already registered");

        // Sanity cross-check, mirrors the worksheet's "Montant net" column
        // being exactly Qté x Prix d'achat.
        uint256 expectedNet = (quantity * purchasePriceRatio) / PRECISION;
        require(netAmountPaid == expectedNet, "TokenizedAssets: netAmountPaid inconsistent with quantity and price");

        assetMetadata[assetId] = AssetMetadata({
            assetId: assetId,
            assetName: assetName,
            assetClass: "NEU_CP",
            unitPrice: purchasePriceRatio,
            lastPriceUpdate: block.timestamp,
            isActive: true,
            quantity: quantity,
            tradeDate: tradeDate,
            maturityDate: maturityDate,
            purchasePriceRatio: purchasePriceRatio,
            netAmountPaid: netAmountPaid
        });

        assetList.push(assetId);
        emit AssetRegistered(assetId, assetName, "NEU_CP", purchasePriceRatio, block.timestamp);
        emit CommercialPaperAssetRegistered(
            assetId, assetName, quantity, tradeDate, maturityDate, purchasePriceRatio, netAmountPaid, block.timestamp
        );
    }

    /// @notice One-time POC seeding: registers the three demo commercial
    ///   papers from the fund's origination worksheet — POC CP 2%, POC CP
    ///   2.5%, and POC CP 3% — using the exact figures from that worksheet.
    ///   Safe to call once; reverts on any subsequent call.
    /// @dev Trade date 24/07/2026 00:00:00 UTC (1784851200), maturity
    ///   31/12/2026 00:00:00 UTC (1798675200) for all three instruments,
    ///   matching Toolbox.sol's initializePOCCommercialPapers(), which
    ///   registers the same three instruments (under the same identifiers)
    ///   for yield/amortization calculations.
    ///
    ///   Worksheet cross-check:
    ///     POC CP 2%   : Qté 500,000   x 99.000%  = Montant net 495,000
    ///     POC CP 2.5% : Qté 500,000   x 98.500%  = Montant net 492,500
    ///     POC CP 3%   : Qté 2,000,000 x 98.125%  = Montant net 1,962,500
    ///     Total Montant net = 2,950,000 EUR (matches the fund's genesis
    ///     purchase amount: 3,100,000 EURC in, 2,950,000 EUR spent on CP,
    ///     150,000 EUR retained as cash — see the worksheet's "Prérequis").
    function initializePOCCommercialPapers() external onlyOwner {
        require(!pocCommercialPapersInitialized, "TokenizedAssets: POC commercial papers already initialized");
        pocCommercialPapersInitialized = true;

        uint256 tradeDate    = 1784851200; // 24/07/2026 00:00:00 UTC
        uint256 maturityDate = 1798675200; // 31/12/2026 00:00:00 UTC

        _registerCommercialPaperAsset(
            POC_CP_2PCT_ID,
            "POC CP 2%",
            500_000 * PRECISION,       // quantity (face value)
            tradeDate,
            maturityDate,
            99 * PRECISION / 100,      // purchasePriceRatio = 99.000% of par
            495_000 * PRECISION        // netAmountPaid
        );

        _registerCommercialPaperAsset(
            POC_CP_2_5PCT_ID,
            "POC CP 2.5%",
            500_000 * PRECISION,
            tradeDate,
            maturityDate,
            985 * PRECISION / 1000,    // purchasePriceRatio = 98.500% of par
            492_500 * PRECISION
        );

        _registerCommercialPaperAsset(
            POC_CP_3PCT_ID,
            "POC CP 3%",
            2_000_000 * PRECISION,
            tradeDate,
            maturityDate,
            98125 * PRECISION / 100000, // purchasePriceRatio = 98.125% of par
            1_962_500 * PRECISION
        );
    }

    /// @notice Updates the price of an existing asset
    /// @param assetId Identifier of the asset to update
    /// @param newPrice New price per unit in EUR (PRECISION)
    /// @dev In production, this would be called by an oracle or valuation agent.
    ///   For the POC, the fund/owner can update prices directly.
    function updateAssetPrice(bytes32 assetId, uint256 newPrice) external onlyOwner {
        require(assetMetadata[assetId].isActive, "TokenizedAssets: asset not registered");
        require(newPrice > 0, "TokenizedAssets: invalid price");

        uint256 previousPrice = assetMetadata[assetId].unitPrice;
        assetMetadata[assetId].unitPrice = newPrice;
        assetMetadata[assetId].lastPriceUpdate = block.timestamp;

        emit AssetPriceUpdated(assetId, previousPrice, newPrice, block.timestamp);
    }

    /// @notice Returns the total value of a specific asset held by an address
    /// @param holder Address holding the assets
    /// @param assetId Identifier of the asset
    /// @return totalValue Total value in EUR (PRECISION) = balance * unitPrice
    function getAssetValue(address holder, bytes32 assetId) external view returns (uint256 totalValue) {
        uint256 balance = assetBalances[holder][assetId];
        uint256 price = assetMetadata[assetId].unitPrice;
        return (balance * price) / PRECISION;
    }

    /// @notice Returns the total portfolio value for a holder across all assets
    /// @param holder Address to evaluate
    /// @return portfolioValue Total value in EUR (PRECISION)
    function getPortfolioValue(address holder) external view returns (uint256 portfolioValue) {
        uint256 total = 0;
        for (uint256 i = 0; i < assetList.length; i++) {
            bytes32 assetId = assetList[i];
            if (assetMetadata[assetId].isActive) {
                uint256 balance = assetBalances[holder][assetId];
                uint256 price = assetMetadata[assetId].unitPrice;
                total += (balance * price) / PRECISION;
            }
        }
        return total;
    }

    // ----------- Standard ERC20 Functions -----------

    function balanceOf(address account) public view returns (uint256) {
        return balances[account];
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount, bytes32(0));
        return true;
    }

    /// @notice Transfer with asset tracking for specific asset types
    function transferAsset(address to, uint256 amount, bytes32 assetId) public returns (bool) {
        require(assetMetadata[assetId].isActive, "TokenizedAssets: asset not registered");
        _transfer(msg.sender, to, amount, assetId);
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        require(spender != address(0), "TokenizedAssets: invalid spender");
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function allowance(address tokenOwner, address spender) public view returns (uint256) {
        return allowances[tokenOwner][spender];
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 currentAllowance = allowances[from][msg.sender];
        require(currentAllowance >= amount, "TokenizedAssets: insufficient allowance");

        _transfer(from, to, amount, bytes32(0));

        unchecked {
            allowances[from][msg.sender] = currentAllowance - amount;
        }
        emit Approval(from, msg.sender, allowances[from][msg.sender]);
        return true;
    }

    // ----------- Mint / Burn (Owner Only) -----------

    function mint(address to, uint256 amount, string calldata reason) external onlyOwner returns (bool) {
        _mint(to, amount, reason, bytes32(0));
        return true;
    }

    /// @notice Mint specific asset type with tracking
    function mintAsset(
        address to,
        uint256 amount,
        bytes32 assetId,
        string calldata reason
    ) external onlyOwner returns (bool) {
        require(assetMetadata[assetId].isActive, "TokenizedAssets: asset not registered");
        _mint(to, amount, reason, assetId);
        return true;
    }

    function burn(uint256 amount, string calldata reason) public returns (bool) {
        _burn(msg.sender, amount, reason, bytes32(0));
        return true;
    }

    function burnFrom(address from, uint256 amount, string calldata reason) external onlyOwner returns (bool) {
        _burn(from, amount, reason, bytes32(0));
        return true;
    }

    /// @notice Burn specific asset type
    function burnAssetFrom(
        address from,
        uint256 amount,
        bytes32 assetId,
        string calldata reason
    ) external onlyOwner returns (bool) {
        require(assetMetadata[assetId].isActive, "TokenizedAssets: asset not registered");
        _burn(from, amount, reason, assetId);
        return true;
    }

    // ----------- Ownership Transfer -----------

    function transferOwnership(address newOwner) public onlyOwner returns (bool) {
        require(newOwner != address(0), "TokenizedAssets: invalid new owner");
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner, block.timestamp);
        return true;
    }

    // ----------- Internal Functions -----------

    function _transfer(address from, address to, uint256 amount, bytes32 assetId) internal {
        require(from != address(0), "TokenizedAssets: invalid sender");
        require(to != address(0), "TokenizedAssets: invalid recipient");

        uint256 senderBalance = balances[from];
        require(senderBalance >= amount, "TokenizedAssets: insufficient balance");

        unchecked {
            balances[from] = senderBalance - amount;
            balances[to] += amount;
        }

        // Track asset-specific balances if assetId is specified
        if (assetId != bytes32(0)) {
            assetBalances[from][assetId] -= amount;
            assetBalances[to][assetId] += amount;
        }

        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount, string memory reason, bytes32 assetId) internal {
        require(to != address(0), "TokenizedAssets: invalid recipient");

        totalSupply += amount;
        balances[to] += amount;

        if (assetId != bytes32(0)) {
            assetBalances[to][assetId] += amount;
        }

        emit Mint(to, amount, reason, block.timestamp);
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount, string memory reason, bytes32 assetId) internal {
        require(from != address(0), "TokenizedAssets: invalid sender");

        uint256 accountBalance = balances[from];
        require(accountBalance >= amount, "TokenizedAssets: insufficient balance");

        unchecked {
            balances[from] = accountBalance - amount;
            totalSupply -= amount;
        }

        if (assetId != bytes32(0)) {
            assetBalances[from][assetId] -= amount;
        }

        emit Burn(from, amount, reason, block.timestamp);
        emit Transfer(from, address(0), amount);
    }
}
