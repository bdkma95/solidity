// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

contract MultiSigWallet {
    address[] public owners;
    uint256 public requiredSignatures;
    mapping(address => bool) public isOwner;

    struct Transaction {
        address to;
        uint256 value;
        address token;  // ERC20 token address (optional)
        bool executed;
        uint256 numConfirmations;
    }

    Transaction[] public transactions;
    mapping(uint256 => mapping(address => bool)) public isConfirmed;

    event TransactionSubmitted(uint256 indexed txIndex, address indexed to, uint256 value, address token);
    event TransactionConfirmed(uint256 indexed txIndex, address indexed owner);
    event TransactionExecuted(uint256 indexed txIndex, bool success);
    event TransactionCancelled(uint256 indexed txIndex);
    event OwnerAdded(address indexed newOwner);
    event OwnerRemoved(address indexed oldOwner);
    event SignaturesUpdated(uint256 requiredSignatures);

    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not an owner");
        _;
    }

    modifier txExists(uint256 txIndex) {
        require(txIndex < transactions.length, "Transaction does not exist");
        _;
    }

    modifier notExecuted(uint256 txIndex) {
        require(!transactions[txIndex].executed, "Transaction already executed");
        _;
    }

    modifier notConfirmed(uint256 txIndex) {
        require(!isConfirmed[txIndex][msg.sender], "Transaction already confirmed by this owner");
        _;
    }

    modifier isValidOwner(address owner) {
        require(owner != address(0), "Invalid owner address");
        require(!isOwner[owner], "Owner already exists");
        _;
    }

    constructor(address[] memory _owners, uint256 _requiredSignatures) {
        require(_owners.length > 0, "Owners required");
        require(_requiredSignatures > 0 && _requiredSignatures <= _owners.length, "Invalid number of required signatures");

        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(owner != address(0), "Invalid owner");
            require(!isOwner[owner], "Owner not unique");

            isOwner[owner] = true;
            owners.push(owner);
        }
        requiredSignatures = _requiredSignatures;
    }

    function submitTransaction(address to, uint256 value, address token) public onlyOwner {
        transactions.push(Transaction({
            to: to,
            value: value,
            token: token,
            executed: false,
            numConfirmations: 0
        }));
        uint256 txIndex = transactions.length - 1;

        emit TransactionSubmitted(txIndex, to, value, token);
    }

    function confirmTransaction(uint256 txIndex) public onlyOwner txExists(txIndex) notConfirmed(txIndex) notExecuted(txIndex) {
        transactions[txIndex].numConfirmations += 1;
        isConfirmed[txIndex][msg.sender] = true;

        emit TransactionConfirmed(txIndex, msg.sender);

        if (transactions[txIndex].numConfirmations >= requiredSignatures) {
            executeTransaction(txIndex);
        }
    }

    function executeTransaction(uint256 txIndex) internal txExists(txIndex) notExecuted(txIndex) {
        Transaction storage transaction = transactions[txIndex];
        require(transaction.numConfirmations >= requiredSignatures, "Cannot execute transaction");

        bool success;
        if (transaction.token == address(0)) {
            // Ether transfer
            (success, ) = transaction.to.call{value: transaction.value}("");
        } else {
            // ERC20 token transfer
            success = IERC20(transaction.token).transfer(transaction.to, transaction.value);
        }

        if (success) {
            transaction.executed = true;
            emit TransactionExecuted(txIndex, true);
        } else {
            emit TransactionExecuted(txIndex, false);
        }
    }

    function cancelTransaction(uint256 txIndex) public onlyOwner txExists(txIndex) notExecuted(txIndex) {
        // Cancel transaction and reset confirmations
        for (uint256 i = 0; i < owners.length; i++) {
            isConfirmed[txIndex][owners[i]] = false;
        }

        emit TransactionCancelled(txIndex);
    }

    function addOwner(address newOwner) public onlyOwner isValidOwner(newOwner) {
        isOwner[newOwner] = true;
        owners.push(newOwner);
        emit OwnerAdded(newOwner);
    }

    function removeOwner(address ownerToRemove) public onlyOwner {
        require(isOwner[ownerToRemove], "Not an owner");
        isOwner[ownerToRemove] = false;

        uint256 index = getOwnerIndex(ownerToRemove);
        owners[index] = owners[owners.length - 1];
        owners.pop();
        emit OwnerRemoved(ownerToRemove);
    }

    function updateRequiredSignatures(uint256 newRequiredSignatures) public onlyOwner {
        require(newRequiredSignatures > 0 && newRequiredSignatures <= owners.length, "Invalid number of required signatures");
        requiredSignatures = newRequiredSignatures;
        emit SignaturesUpdated(newRequiredSignatures);
    }

    function getOwnerIndex(address owner) internal view returns (uint256) {
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                return i;
            }
        }
        revert("Owner not found");
    }

    // To receive ether
    receive() external payable {}

    // Function to get wallet balance
    function walletBalance() public view returns (uint256) {
        return address(this).balance;
    }

    // Function to check balance of an ERC20 token in the wallet
    function tokenBalance(address token) public view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
