// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

contract MultiSigWallet {
    address[] public owners;
    uint256 public requiredSignatures;
    mapping(address => bool) public isOwner;

    struct Transaction {
        address to;
        uint256 value;
        bool executed;
        uint256 numConfirmations;
    }

    Transaction[] public transactions;
    mapping(uint256 => mapping(address => bool)) public isConfirmed;

    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not an owner");
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

    function submitTransaction(address to, uint256 value) public onlyOwner {
        transactions.push(Transaction({
            to: to,
            value: value,
            executed: false,
            numConfirmations: 0
        }));
    }

    function confirmTransaction(uint256 txIndex) public onlyOwner {
        require(transactions[txIndex].to != address(0), "Transaction does not exist");
        require(!isConfirmed[txIndex][msg.sender], "Transaction already confirmed");

        transactions[txIndex].numConfirmations += 1;
        isConfirmed[txIndex][msg.sender] = true;

        if (transactions[txIndex].numConfirmations >= requiredSignatures) {
            executeTransaction(txIndex);
        }
    }

    function executeTransaction(uint256 txIndex) internal {
        Transaction storage transaction = transactions[txIndex];

        require(transaction.numConfirmations >= requiredSignatures, "Cannot execute transaction");
        require(!transaction.executed, "Transaction already executed");

        (bool success, ) = transaction.to.call{value: transaction.value}("");
        require(success, "Transaction failed");

        transaction.executed = true;
    }

    function balanceOf(address account) public view returns (uint256) {
    return account.balance;
    }
}
