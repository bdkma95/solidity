// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol"; // AccessControl via Ownable contract
import "@openzeppelin/contracts/token/ERC20/IERC20.sol"; // ERC20 Token interface

contract SupplyChainTracking is Ownable {

    /* Track most recent sku */
    uint public skuCount;

    /* Mapping for items */
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
        address paymentToken; // Address of ERC20 token used for payment
        uint paymentAmount; // Amount of tokens paid by the buyer
    }

    /* Events for each state change */
    event ItemForSale(uint indexed sku);
    event ItemSold(uint indexed sku);
    event ItemShipped(uint indexed sku);
    event ItemReceived(uint indexed sku);

    /* Modifiers */
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

    constructor() {
        skuCount = 0;
    }

    // Function to add item to the supply chain
    function addItem(string calldata _name, uint _price, address _paymentToken) external returns (bool) {
        emit ItemForSale(skuCount);
        items[skuCount] = Item({
            name: _name,
            sku: skuCount,
            price: _price,
            state: State.ForSale,
            seller: msg.sender,
            buyer: address(0),
            paymentToken: _paymentToken,
            paymentAmount: 0
        });
        skuCount++;
        return true;
    }

    // Function for a buyer to purchase an item (paying in Ether or ERC20 tokens)
    function buyItem(uint sku)
        external
        payable
        forSale(sku)
        paidEnough(items[sku].price)
        checkValue(sku)
    {
        Item storage item = items[sku];
        uint paymentAmount = item.price;

        // Handling payment via Ether
        if (item.paymentToken == address(0)) {
            payable(item.seller).transfer(paymentAmount);
        } else {
            // Handling payment via ERC20 token
            IERC20 token = IERC20(item.paymentToken);
            require(token.transferFrom(msg.sender, address(this), paymentAmount), "Token transfer failed");
            item.paymentAmount = paymentAmount;
        }

        item.buyer = msg.sender;
        item.state = State.Sold;
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
        Item storage item = items[sku];

        // Release payment to seller only if item is received
        if (item.paymentToken == address(0)) {
            payable(item.seller).transfer(item.price);
        } else {
            IERC20 token = IERC20(item.paymentToken);
            require(token.transfer(item.seller, item.paymentAmount), "Token transfer failed");
        }

        items[sku].state = State.Received;
        emit ItemReceived(sku);
    }

    // Withdraw contract's balance (for Ether)
    function withdrawEther(uint amount) external onl
