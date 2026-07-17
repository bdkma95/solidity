// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title EMT - Cash Token (ERC20)
/// @notice This contract implements a standard ERC20 token named EMT, used to
///   represent CASH (EUR) on-chain within the tokenized fund architecture.
/// @dev EMT sits on the ASSET side of the fund's balance sheet ("Gestion de
///   l'actif" in the architecture diagram). The fund contract is expected to
///   become the "owner" of this contract so that it can mint EMT whenever
///   cash enters the fund (subscription) and burn EMT whenever cash leaves
///   the fund (redemption), keeping the ERC20 total supply in line with the
///   real cash position of the fund at all times.
contract EMT {
    // ----------- Token metadata -----------
    string public name = "EMT";
    string public symbol = "EMT";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    // ----------- Owner (for mint/burn) -----------
    address public owner;

    // ----------- Balances and allowances -----------
    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;

    // ----------- Events -----------
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed tokenOwner, address indexed spender, uint256 value);
    event Mint(address indexed to, uint256 value);
    event Burn(address indexed from, uint256 value);

    // ----------- Modifier -----------
    modifier onlyOwner() {
        require(msg.sender == owner, "EMT: caller is not authorized");
        _;
    }

    constructor(uint256 initialSupply) {
        owner = msg.sender;
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
    }

    // ----------- Function: Retrieve balance (balanceOf) -----------
    /// @notice Returns the balance of a given account
    function balanceOf(address account) public view returns (uint256) {
        return balances[account];
    }

    // ----------- Function: Transfer -----------
    /// @notice Transfers tokens from the caller to another address
    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    // ----------- Function: Approve -----------
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

    // ----------- Function: TransferFrom -----------
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

    // ----------- Function: Mint -----------
    /// @notice Creates new tokens and assigns them to an address (owner only)
    /// @dev Called by the fund contract whenever new cash enters the fund
    ///   (e.g. on subscription), to keep the EMT supply equal to the fund's
    ///   real cash position.
    function mint(address to, uint256 amount) public onlyOwner returns (bool) {
        _mint(to, amount);
        return true;
    }

    // ----------- Function: Burn -----------
    /// @notice Destroys tokens belonging to the caller
    function burn(uint256 amount) public returns (bool) {
        _burn(msg.sender, amount);
        return true;
    }

    /// @notice Destroys tokens belonging to another address (owner only)
    /// @dev Called by the fund contract whenever cash leaves the fund
    ///   (e.g. on redemption), to keep the EMT supply equal to the fund's
    ///   real cash position.
    function burnFrom(address from, uint256 amount) public onlyOwner returns (bool) {
        _burn(from, amount);
        return true;
    }

    // ----------- Function: Ownership transfer -----------
    /// @notice Transfers owner rights (mint/burn) to another address.
    /// @dev Useful to delegate the management of this token to a third-party
    ///   contract, e.g. a tokenized fund contract that needs to mint/burn EMT
    ///   to represent the fund's cash position.
    function transferOwnership(address newOwner) public onlyOwner returns (bool) {
        require(newOwner != address(0), "EMT: invalid new owner (zero address)");
        owner = newOwner;
        return true;
    }

    // ----------- Internal functions -----------
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

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "EMT: invalid recipient (zero address)");

        totalSupply += amount;
        balances[to] += amount;

        emit Mint(to, amount);
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        require(from != address(0), "EMT: invalid sender (zero address)");

        uint256 accountBalance = balances[from];
        require(accountBalance >= amount, "EMT: insufficient balance to burn");

        unchecked {
            balances[from] = accountBalance - amount;
            totalSupply -= amount;
        }

        emit Burn(from, amount);
        emit Transfer(from, address(0), amount);
    }
}