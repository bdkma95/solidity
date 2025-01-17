// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;

import "./ChildContract.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ParentContract is Ownable {

    struct Collection {
        string collectionName;
        string collectionSymbol;
        string collectionDescription;
        uint collectionPrice;
        uint collectionElements;
    }

    // Mapping to store collections by contract address
    mapping(address => Collection) public collections;

    // Mapping to store deployed contracts by index (could also be an ID)
    address[] public deployedContracts;

    // Event declaration for contract deployment
    event ContractDeployed(address indexed childContract, string collectionName, uint collectionPrice);

    constructor() {
        // Constructor logic if needed
    }

    function deployContract(
        string memory _collectionName, 
        string memory _collectionSymbol, 
        string memory _collectionDescription, 
        uint _collectionPrice, 
        uint _collectionElements
    ) public onlyOwner {

        // Input validation
        require(bytes(_collectionName).length > 0, "Collection name is required");
        require(bytes(_collectionSymbol).length > 0, "Collection symbol is required");
        require(bytes(_collectionDescription).length > 0, "Collection description is required");
        require(_collectionPrice > 0, "Collection price must be greater than 0");
        require(_collectionElements > 0, "Collection elements must be greater than 0");

        // Deploy ChildContract
        ChildContract child = new ChildContract(
            _collectionName, 
            _collectionSymbol, 
            _collectionDescription, 
            _collectionPrice, 
            _collectionElements
        );

        // Store collection information in the mapping
        collections[address(child)] = Collection({
            collectionName: _collectionName,
            collectionSymbol: _collectionSymbol,
            collectionDescription: _collectionDescription,
            collectionPrice: _collectionPrice,
            collectionElements: _collectionElements
        });

        // Store the deployed contract address
        deployedContracts.push(address(child));

        // Emit an event for the contract deployment
        emit ContractDeployed(address(child), _collectionName, _collectionPrice);
    }

    // Optional function to get the details of a deployed contract by address
    function getCollectionDetails(address childContract) public view returns (Collection memory) {
        return collections[childContract];
    }

    // Optional function to get the count of deployed contracts
    function getDeployedContractsCount() public view returns (uint256) {
        return deployedContracts.length;
    }
}
