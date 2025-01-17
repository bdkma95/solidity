// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract ChainRegistry is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Stores authorized addresses
    EnumerableSet.AddressSet private authorized;

    // Stores chains
    mapping(uint => string) public chains;
    uint public chainCount;

    // Emit events for chain additions and removals
    event ChainAdded(uint indexed chainIndex, string chainName);
    event ChainRemoved(uint indexed chainIndex, string chainName);
    event AddressAuthorized(address indexed addr);
    event AddressDeauthorized(address indexed addr);

    modifier onlyAuthorized() {
        require(authorized.contains(msg.sender), "Only authorized addresses can call this function");
        _;
    }

    constructor() {
        authorized.add(msg.sender); // Add the contract owner as the first authorized address
    }

    // Add a new chain
    function addChain(string memory _chainName) public onlyAuthorized {
        chains[chainCount] = _chainName;
        emit ChainAdded(chainCount, _chainName);
        chainCount++;
    }

    // Remove a chain by index
    function removeChain(uint _index) public onlyAuthorized {
        require(_index < chainCount, "Invalid index");

        string memory removedChain = chains[_index];
        delete chains[_index];

        // Shift remaining elements
        if (_index < chainCount - 1) {
            chains[_index] = chains[chainCount - 1];
        }
        delete chains[chainCount - 1];
        chainCount--;

        emit ChainRemoved(_index, removedChain);
    }

    // Authorize an address
    function authorizeAddress(address _addr) public onlyOwner {
        require(!authorized.contains(_addr), "Address is already authorized");
        authorized.add(_addr);
        emit AddressAuthorized(_addr);
    }

    // Deauthorize an address
    function deauthorizeAddress(address _addr) public onlyOwner {
        require(authorized.contains(_addr), "Address is not authorized");
        authorized.remove(_addr);
        emit AddressDeauthorized(_addr);
    }

    // Check if an address is authorized
    function isAuthorized(address _addr) public view returns (bool) {
        return authorized.contains(_addr);
    }
}

