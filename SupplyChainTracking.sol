// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

contract SupplyChainTracking {

    /* Set owner */
    address public owner;

    /* Track most recent sku */
    uint public skuCount;

    /* Mappings for items */
    mapping(uint => Item) public items;

    /* Enum for item state */
    enum State {ForSale, Sold, Shipped, Received}

    /* Struct for item */
    struct Item {
        string name;
        uint sku;
        uint price;
        State state;
        address seller;
        address buyer;
    }

    /* Events for each state change */
    event ItemForSale(uint indexed sku);
    event ItemSold(uint indexed sku);
    event ItemShipped(uint indexed sku);
    event ItemReceived(uint indexed sku);

    /* Modifiers */
    modifier checkOwnership() {
        require(msg.sender == owner, "Only the contract owner can perform this action");
        _;
    }

    modifier verifyCaller(address _address) {
        require(msg.sender == _address, "Caller is not authorized");
        _;
    }

    modifier paidEnough(uint _price) {
        require(msg.value >= _price, "Insufficient funds sent");
        _;
    }

    modifier checkValue(uint _sku) {
        _;
        uint _price = items[_sku].price;
        uint amountToRefund = msg.value - _price;
        if (amountToRefund > 0) {
            payable(items[_sku].buyer).transfer(amountToRefund);
        }
    }

    modifier forSale(uint _sku) {
        require(items[_sku].state == State.ForSale, "Item is not for sale");
        _;
    }

    modifier sold(uint _sku) {
        require(items[_sku].state == State.Sold, "Item has not been sold");
        _;
    }

    modifier shipped(uint _sku) {
        require(items[_sku].state == State.Shipped, "Item has not been shipped");
        _;
    }

    modifier received(uint _sku) {
        require(items[_sku].state == State.Received, "Item has not been received");
        _;
    }

    constructor() {
        owner = msg.sender;
        skuCount = 0;
    }

    // Function to add item to the supply chain
    function addItem(string calldata _name, uint _price) external returns (bool) {
        emit ItemForSale(skuCount);
        items[skuCount] = Item({
            name: _name,
            sku: skuCount,
            price: _price,
            state: State.ForSale,
            seller: msg.sender,
            buyer: address(0)
        });
        skuCount++;
        return true;
    }

    // Function for a buyer to purchase an item
    function buyItem(uint sku)
        external
        payable
        forSale(sku)
        paidEnough(items[sku].price)
        checkValue(sku)
    {
        payable(items[sku].seller).transfer(items[sku].price);
        items[sku].buyer = msg.sender;
        items[sku].state = State.Sold;
        emit ItemSold(sku);
    }

    // Function to mark an item as shipped by the seller
    function shipItem(uint sku)
        external
        sold(sku)
        verifyCaller(items[sku].seller)
    {
        items[sku].state = State.Shipped;
        emit ItemShipped(sku);
    }

    // Function to mark an item as received by the buyer
    function receiveItem(uint sku)
        external
        shipped(sku)
        verifyCaller(items[sku].buyer)
    {
        items[sku].state = State.Received;
        emit ItemReceived(sku);
    }

    // Function to withdraw Ether from the contract (only accessible to the owner)
    function withdraw() external checkOwnership {
        payable(owner).transfer(address(this).balance);
    }
}
