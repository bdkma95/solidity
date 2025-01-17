// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
        uint royaltyPercentage; // Seller's royalty percentage
        address creator; // Address of the item's creator (for royalties)
    }

    /* Events for each state change */
    event ItemForSale(uint indexed sku);
    event ItemSold(uint indexed sku);
    event ItemShipped(uint indexed sku);
    event ItemReceived(uint indexed sku);

    /* Events for reputation system */
    event ReputationUpdated(address indexed user, uint newRating);

    /* Multi-sig withdraw system */
    address[] public admins;
    mapping(address => bool) public isAdmin;
    uint public approvalThreshold = 2; // Number of admin approvals required

    /* Reputation system */
    mapping(address => uint) public reputation;

    /* Dispute system */
    mapping(uint => bool) public disputes;
    address public mediator;

    /* Modifiers */
    modifier onlyAdmin() {
        require(isAdmin[msg.sender], "Not an admin");
        _;
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

    modifier verifyCaller(address _address) {
        require(msg.sender == _address, "Caller is not authorized");
        _;
    }

    constructor(address[] memory _admins) {
        skuCount = 0;
        for (uint i = 0; i < _admins.length; i++) {
            isAdmin[_admins[i]] = true;
            admins.push(_admins[i]);
        }
    }

    // Function to add item to the supply chain
    function addItem(string calldata _name, uint _price, address _paymentToken, uint _royaltyPercentage, address _creator) external returns (bool) {
        require(_royaltyPercentage <= 100, "Invalid royalty percentage");
        emit ItemForSale(skuCount);
        items[skuCount] = Item({
            name: _name,
            sku: skuCount,
            price: _price,
            state: State.ForSale,
            seller: msg.sender,
            buyer: address(0),
            paymentToken: _paymentToken,
            paymentAmount: 0,
            royaltyPercentage: _royaltyPercentage,
            creator: _creator
        });
        skuCount++;
        return true;
    }

    // Function for a buyer to purchase an item (paying in Ether or ERC20 tokens)
    function buyItem(uint sku)
        external
        payable
        forSale(sku)
    {
        Item storage item = items[sku];
        uint paymentAmount = item.price;

        // Handling payment via Ether
        if (item.paymentToken == address(0)) {
            require(msg.value >= paymentAmount, "Not enough Ether sent");
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

    // Function to mark an item as received by the buyer and release funds
    function receiveItem(uint sku)
        external
        shipped(sku)
        verifyCaller(items[sku].buyer)
    {
        Item storage item = items[sku];

        // Royalty payment to the creator
        uint royaltyAmount = (item.price * item.royaltyPercentage) / 100;
        if (item.paymentToken == address(0)) {
            payable(item.creator).transfer(royaltyAmount);
            payable(item.seller).transfer(item.price - royaltyAmount);
        } else {
            IERC20 token = IERC20(item.paymentToken);
            require(token.transfer(item.creator, royaltyAmount), "Token transfer failed");
            require(token.transfer(item.seller, item.paymentAmount - royaltyAmount), "Token transfer failed");
        }

        items[sku].state = State.Received;
        emit ItemReceived(sku);
    }

    // Function to resolve disputes, allowing the mediator to release funds
    function resolveDispute(uint sku, bool releaseFunds)
        external
    {
        require(msg.sender == mediator, "Not the mediator");
        require(disputes[sku], "No dispute for this item");

        Item storage item = items[sku];
        if (releaseFunds) {
            uint paymentAmount = item.price;
            if (item.paymentToken == address(0)) {
                payable(item.seller).transfer(paymentAmount);
            } else {
                IERC20 token = IERC20(item.paymentToken);
                require(token.transfer(item.seller, paymentAmount), "Token transfer failed");
            }
        }
        disputes[sku] = false;
    }

    // Function to initiate a dispute
    function initiateDispute(uint sku) external {
        require(msg.sender == items[sku].buyer, "Only the buyer can initiate a dispute");
        require(items[sku].state == State.Shipped, "Item must be shipped first");
        disputes[sku] = true;
    }

    // Function to update the buyer/seller reputation
    function updateReputation(address user, uint rating) external onlyAdmin {
        require(rating <= 5 && rating >= 1, "Invalid rating");
        reputation[user] = rating;
        emit ReputationUpdated(user, rating);
    }

    // Multi-sig withdrawal approval function
    function approveWithdrawal(address to, uint amount) external onlyAdmin {
        // Simple multi-signature mechanism
        uint approvalCount;
        for (uint i = 0; i < admins.length; i++) {
            if (isAdmin[admins[i]]) {
                approvalCount++;
            }
        }
        require(approvalCount >= approvalThreshold, "Not enough approvals");

        // Withdraw Ether or tokens to the 'to' address
        payable(to).transfer(amount);
    }

    // Withdraw any ERC20 token balance (for ERC20 tokens)
    function withdrawTokens(address _token, uint amount) external onlyAdmin {
        IERC20 token = IERC20(_token);
        require(token.balanceOf(address(this)) >= amount, "Insufficient token balance");
        token.transfer(owner(), amount);
    }
}
