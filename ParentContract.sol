// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;

import "./ChildContract.sol";

contract ParentContract {

    struct Ben {    
        string collectionName;
        string collectionSymbol;
        string collectionDescription;
        uint collectionPrice;
        uint collectionElements;
    }

    Ben[] public ben; 

    address[] public deployedContract;

    constructor() {
        
    }

    function deployContract(string memory _collectionName, string memory _collectionSymbol, string memory _collectionDescription, uint _collectionPrice, uint _collectionElements) public {
        ChildContract child = new ChildContract(_collectionName, _collectionDescription, _collectionSymbol, _collectionPrice, _collectionElements);
          
        Ben memory benInitial = Ben ({

           collectionName : _collectionName,
           collectionSymbol : _collectionSymbol,
           collectionDescription : _collectionDescription,
           collectionPrice : _collectionPrice,
           collectionElements : _collectionElements
        });

        ben.push(benInitial);
        deployedContract.push(address(child));
    }
}
