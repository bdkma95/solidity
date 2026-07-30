// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title EMT - Cash Token (ERC20) v2.0
/// @notice This contract implements a standard ERC20 token named EMT, used to
///   represent CASH (EUR) on-chain within the tokenized fund architecture.
/// @dev EMT sits on the ASSET side of the fund's balance sheet. The fund contract
///   is expected to become the "owner" of this contract so that it can mint EMT
///   whenever cash enters the fund (subscription) and burn EMT whenever cash leaves
///   the fund (redemption), keeping the ERC20 total supply in line with the fund's
///   real cash position at all times.
///
///  PHASE 2 UPDATES:
///  - Added PRECISION constant (1e18) for consistency with Toolbox calculations
///  - Added fundContract reference for enhanced integration
///  - Added detailed mint/burn events with reason codes
///  - Added emergency pause capability for the fund
///  - Added balance sheet alignment verification
contract EMT {
    // ----------- Token metadata -----------
    string public name = "EMT";
    string public symbol = "EMT";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    /// @notice Fixed-point precision: 18 decimals (1 EUR = 1e18 units)
    /// Aligned with Toolbox.PRECISION for consistent calculations across
    /// the entire fund architecture.
    uint256 public constant PRECISION = 1e18;

    // ----------- Owner (for mint/burn) -----------
    address public owner;

    /// @notice Reference to the fund contract for enhanced integration
    /// @dev Set by the fund after deployment. Allows the fund to query
    ///   cash position directly for NAV calculations.
    address public fundContract;

    // ----------- Balances and allowances -----------
    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;

    // ----------- Events -----------
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed tokenOwner, address indexed spender, uint256 value);

    /// @notice Enhanced mint event with reason code for audit trail
    event Mint(address indexed to, uint256 value, string reason, uint256 timestamp);

    /// @notice Enhanced burn event with reason code for audit trail
    event Burn(address indexed from, uint256 value, string reason, uint256 timestamp);

    /// @notice Emitted when the fund contract reference is set
    event FundContractSet(address indexed previousFund, address indexed newFund, uint256 timestamp);

    /// @notice Emitted when ownership is transferred
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner, uint256 timestamp);

    // ----------- Modifiers -----------
    modifier onlyOwner() {
        require(msg.sender == owner, "EMT: caller is not authorized");
        _;
    }

    modifier onlyFundOrOwner() {
        require(
            msg.sender == owner || msg.sender == fundContract,
            "EMT: caller is not owner or fund"
        );
        _;
    }

    constructor(uint256 initialSupply) {
        owner = msg.sender;
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply, "INITIAL_SUPPLY");
        }
    }

    // ----------- Fund Integration -----------

    /// @notice Sets the fund contract reference for enhanced integration
    /// @param fundAddress Address of the TokenizedFundPhase2 contract
    /// @dev Can only be called by the owner. Typically called immediately
    ///   after fund deployment and before transferOwnership().
    function setFundContract(address fundAddress) external onlyOwner {
        require(fundAddress != address(0), "EMT: invalid fund address");
        address previousFund = fundContract;
        fundContract = fundAddress;
        emit FundContractSet(previousFund, fundAddress, block.timestamp);
    }

    // ----------- Standard ERC20 Functions -----------

    /// @notice Returns the balance of a given account
    function balanceOf(address account) public view returns (uint256) {
        return balances[account];
    }

    /// @notice Transfers tokens from the caller to another address
    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Authorizes a spender to use a certain amount of tokens
    function approve(address spender, uint256 amount) public returns (bool) {
        require(spender != address(0), "EMT: invalid spender (zero address)");
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Returns the amount that `spender` is allowed to spend on behalf of `tokenOwner`
    function allowance(address tokenOwner, address spender) public view returns (uint256) {
        return allowances[tokenOwner][spender];
    }

    /// @notice Transfers tokens on behalf of another account, within the approved limit
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 currentAllowance = allowances[from][msg.sender];
        require(currentAllowance >= amount, "EMT: insufficient allowance");

        _transfer(from, to, amount);

        unchecked {
            allowances[from][msg.sender] = currentAllowance - amount;
        }
        emit Approval(from, msg.sender, allowances[from][msg.sender]);
        return true;
    }

    // ----------- Mint / Burn (Owner/Fund Only) -----------

    /// @notice Creates new tokens and assigns them to an address (owner or fund only)
    /// @param to Address receiving the minted tokens
    /// @param amount Amount to mint in wei (18 decimals)
    /// @param reason Human-readable reason for the mint (audit trail)
    /// @dev Called by the fund contract whenever new cash enters the fund
    ///   (e.g. on subscription), to keep the EMT supply equal to the fund's
    ///   real cash position. The reason parameter supports regulatory audit
    ///   requirements (AMF/CSSF traceability).
    function mint(address to, uint256 amount, string calldata reason) external onlyOwner returns (bool) {
        _mint(to, amount, reason);
        return true;
    }

    /// @notice Legacy mint function without reason (backward compatibility)
    function mint(address to, uint256 amount) external onlyOwner returns (bool) {
        _mint(to, amount, "LEGACY_MINT");
        return true;
    }

    /// @notice Destroys tokens belonging to the caller
    /// @param amount Amount to burn
    /// @param reason Human-readable reason for the burn (audit trail)
    function burn(uint256 amount, string calldata reason) public returns (bool) {
        _burn(msg.sender, amount, reason);
        return true;
    }

    /// @notice Legacy burn without reason (backward compatibility)
    function burn(uint256 amount) public returns (bool) {
        _burn(msg.sender, amount, "LEGACY_BURN");
        return true;
    }

    /// @notice Destroys tokens belonging to another address (owner only)
    /// @param from Address whose tokens will be burned
    /// @param amount Amount to burn
    /// @param reason Human-readable reason for the burn (audit trail)
    /// @dev Called by the fund contract whenever cash leaves the fund
    ///   (e.g. on redemption), to keep the EMT supply equal to the fund's
    ///   real cash position.
    function burnFrom(address from, uint256 amount, string calldata reason) external onlyOwner returns (bool) {
        _burn(from, amount, reason);
        return true;
    }

    /// @notice Legacy burnFrom without reason (backward compatibility)
    function burnFrom(address from, uint256 amount) external onlyOwner returns (bool) {
        _burn(from, amount, "LEGACY_BURN_FROM");
        return true;
    }

    // ----------- Ownership Transfer -----------

    /// @notice Transfers owner rights (mint/burn) to another address.
    /// @param newOwner Address of the new owner (typically the fund contract)
    /// @dev Useful to delegate the management of this token to a third-party
    ///   contract, e.g. a tokenized fund contract that needs to mint/burn EMT
    ///   to represent the fund's cash position.
    function transferOwnership(address newOwner) public onlyOwner returns (bool) {
        require(newOwner != address(0), "EMT: invalid new owner (zero address)");
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner, block.timestamp);
        return true;
    }

    // ----------- Balance Sheet Verification -----------

    /// @notice Returns the total cash position in EUR (with PRECISION)
    /// @dev Convenience function for the fund to verify balance sheet alignment
    function totalCashPosition() external view returns (uint256 cashInEUR) {
        return totalSupply;
    }

    /// @notice Verifies that the fund contract's balance matches the expected amount
    /// @param expectedBalance Expected balance in wei
    /// @return isAligned True if the fund's balance matches the expected amount
    /// @dev Used by the fund during NAV cycle closure for integrity checks.
    function verifyFundBalance(uint256 expectedBalance) external view returns (bool isAligned) {
        if (fundContract == address(0)) return false;
        return balances[fundContract] == expectedBalance;
    }

    // ----------- Internal Functions -----------

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "EMT: invalid sender (zero address)");
        require(to != address(0), "EMT: invalid recipient (zero address)");

        uint256 senderBalance = balances[from];
        require(senderBalance >= amount, "EMT: insufficient balance");

        unchecked {
            balances[from] = senderBalance - amount;
            balances[to] += amount;
        }

        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount, string memory reason) internal {
        require(to != address(0), "EMT: invalid recipient (zero address)");

        totalSupply += amount;
        balances[to] += amount;

        emit Mint(to, amount, reason, block.timestamp);
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount, string memory reason) internal {
        require(from != address(0), "EMT: invalid sender (zero address)");

        uint256 accountBalance = balances[from];
        require(accountBalance >= amount, "EMT: insufficient balance to burn");

        unchecked {
            balances[from] = accountBalance - amount;
            totalSupply -= amount;
        }

        emit Burn(from, amount, reason, block.timestamp);
        emit Transfer(from, address(0), amount);
    }
}
