// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract ChainRegistry is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Stores authorized addresses
    EnumerableSet.AddressSet private authorized;

    // Structure for chain metadata
    struct Chain {
        string name;
        string description;
        string url;
    }

    // Stores chains
    mapping(uint => Chain) public chains;
    uint public chainCount;

    // Contract paused state
    bool public paused;

    // Emit events for chain actions and pause toggles
    event ChainAdded(uint indexed chainIndex, string chainName);
    event ChainRemoved(uint indexed chainIndex, string chainName);
    event AddressAuthorized(address indexed addr);
    event AddressDeauthorized(address indexed addr);
    event Paused(bool state);

    modifier onlyAuthorized() {
        require(authorized.contains(msg.sender), "Only authorized addresses can call this function");
        _;
    }

    modifier notPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    constructor() {
        authorized.add(msg.sender); // Add the contract owner as the first authorized address
    }

    // Add a new chain with metadata
    function addChain(string memory _chainName, string memory _description, string memory _url) public onlyAuthorized notPaused {
        chains[chainCount] = Chain({
            name: _chainName,
            description: _description,
            url: _url
        });
        emit ChainAdded(chainCount, _chainName);
        chainCount++;
    }

    // Remove a chain by index
    function removeChain(uint _index) public onlyAuthorized notPaused {
        require(_index < chainCount, "Invalid index");

        string memory removedChainName = chains[_index].name;
        delete chains[_index];

        // Shift remaining elements if necessary
        if (_index < chainCount - 1) {
            chains[_index] = chains[chainCount - 1];
        }
        delete chains[chainCount - 1];
        chainCount--;

        emit ChainRemoved(_index, removedChainName);
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

    // Toggle pause state
    function togglePause() public onlyOwner {
        paused = !paused;
        emit Paused(paused);
    }

    // Get chain metadata by index
    function getChainMetadata(uint _index) public view returns (string memory name, string memory description, string memory url) {
        require(_index < chainCount, "Invalid index");
        Chain storage chain = chains[_index];
        return (chain.name, chain.description, chain.url);
    }
}
