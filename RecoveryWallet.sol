// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

contract RecoveryWallet {
    address public owner;
    address public recoveryAddress;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    modifier onlyRecovery() {
        require(msg.sender == recoveryAddress, "Not the recovery address");
        _;
    }

    constructor(address _recoveryAddress) {
        owner = msg.sender;
        recoveryAddress = _recoveryAddress;
    }

    function transferOwnership(address newOwner) public onlyRecovery {
        require(newOwner != address(0), "Invalid new owner address");
        owner = newOwner;
    }

    function setRecoveryAddress(address newRecoveryAddress) public onlyOwner {
        require(newRecoveryAddress != address(0), "Invalid recovery address");
        recoveryAddress = newRecoveryAddress;
    }
}
