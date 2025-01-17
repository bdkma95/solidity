// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

contract RecoveryWallet {
    address public owner;
    address public recoveryAddress;

    uint256 public recoveryAddressChangeTime;  // Timestamp when recovery address can change
    uint256 public ownershipTransferTime;     // Timestamp when owner can transfer ownership

    uint256 public constant CHANGE_DELAY = 1 weeks; // Delay for recovery address changes (e.g., 1 week)
    uint256 public constant OWNERSHIP_DELAY = 1 weeks; // Delay for ownership transfers (e.g., 1 week)

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event RecoveryAddressChanged(address indexed oldRecovery, address indexed newRecovery);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    modifier onlyRecovery() {
        require(msg.sender == recoveryAddress, "Not the recovery address");
        _;
    }

    modifier onlyAfterOwnershipDelay() {
        require(block.timestamp >= ownershipTransferTime, "Ownership transfer delay has not passed");
        _;
    }

    modifier onlyAfterRecoveryAddressDelay() {
        require(block.timestamp >= recoveryAddressChangeTime, "Recovery address change delay has not passed");
        _;
    }

    constructor(address _recoveryAddress) {
        require(_recoveryAddress != address(0), "Invalid recovery address");
        owner = msg.sender;
        recoveryAddress = _recoveryAddress;
        recoveryAddressChangeTime = block.timestamp + CHANGE_DELAY; // Set recovery change delay
        ownershipTransferTime = block.timestamp + OWNERSHIP_DELAY; // Set ownership transfer delay
    }

    // Transfer ownership to a new address after the delay period
    function transferOwnership(address newOwner) public onlyRecovery onlyAfterOwnershipDelay {
        require(newOwner != address(0), "Invalid new owner address");
        address oldOwner = owner;
        owner = newOwner;
        ownershipTransferTime = block.timestamp + OWNERSHIP_DELAY; // Reset the delay after transfer
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // Set a new recovery address with a delay
    function setRecoveryAddress(address newRecoveryAddress) public onlyOwner onlyAfterRecoveryAddressDelay {
        require(newRecoveryAddress != address(0), "Invalid recovery address");
        require(newRecoveryAddress != owner, "Recovery address cannot be the owner");
        address oldRecovery = recoveryAddress;
        recoveryAddress = newRecoveryAddress;
        recoveryAddressChangeTime = block.timestamp + CHANGE_DELAY; // Reset delay
        emit RecoveryAddressChanged(oldRecovery, newRecoveryAddress);
    }

    // Function to allow the contract to be self-destructed once it is no longer needed
    function selfDestruct() public onlyOwner {
        selfdestruct(payable(owner)); // Destroys the contract and sends remaining ether to the owner
    }
}
