// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SupplyChainTracking is Ownable {
    uint public skuCount; // track most recent SKU

    mapping(uint => Item) public items; // SKU -> Item mapping

    // Item state enum
    enum State { ForSale, Sold, Shipped, Received }

    struct Item {
        string name;
        uint sku;
        uint price;
        State state;
        address seller;
        address buyer;
        address paymentToken; // ERC20 token for payment (address(0) means Ether)
        uint royaltyPercentage; // Royalty percentage
        address creator; // Creator for royalties
        uint escrowAmount; // Amount held in escrow
    }

    // Events for state changes
    event ItemForSale(uint indexed sku);
    event ItemSold(uint indexed sku);
    event ItemShipped(uint indexed sku);
    event ItemReceived(uint indexed sku);
    event FundsReleased(uint indexed sku);
    event RoyaltyPaid(uint indexed sku, address creator, uint royaltyAmount);

    // Admins and multi-signature wallet system
    address[] public admins;
    mapping(address => bool) public isAdmin;
    uint public approvalThreshold = 2; // Minimum number of approvals required

    // Dispute system
    mapping(uint => bool) public disputes;
    address public mediator;

    // Modifiers for access control
    modifier onlyAdmin() {
        require(isAdmin[msg.sender], "Not an admin");
        _;
    }

    modifier forSale(uint _sku) {
        require(items[_sku].state == State.ForSale, "Item not for sale");
        _;
    }

    modifier sold(uint _sku) {
        require(items[_sku].state == State.Sold, "Item not sold");
        _;
    }

    modifier shipped(uint _sku) {
        require(items[_sku].state == State.Shipped, "Item not shipped");
        _;
    }

    modifier received(uint _sku) {
        require(items[_sku].state == State.Received, "Item not received");
        _;
    }

    modifier verifyCaller(address _address) {
        require(msg.sender == _address, "Caller is not authorized");
        _;
    }

    constructor(address[] memory _admins, address _mediator) {
        skuCount = 0;
        for (uint i = 0; i < _admins.length; i++) {
            isAdmin[_admins[i]] = true;
            admins.push(_admins[i]);
        }
        mediator = _mediator;
    }

    // Function to add a new item for sale
    function addItem(string calldata _name, uint _price, address _paymentToken, uint _royaltyPercentage, address _creator) external returns(bool) {
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
            royaltyPercentage: _royaltyPercentage,
            creator: _creator,
            escrowAmount: 0
        });
        skuCount++;
        return true;
    }

    // Function for a buyer to purchase an item with Ether or ERC20 token
    function buyItem(uint sku) external payable forSale(sku) {
        Item storage item = items[sku];
        uint paymentAmount = item.price;

        // Handling payment with Ether
        if (item.paymentToken == address(0)) {
            require(msg.value >= paymentAmount, "Not enough Ether sent");
            item.escrowAmount = msg.value;
        } else {
            // Handling ERC20 token payment
            IERC20 token = IERC20(item.paymentToken);
            require(token.transferFrom(msg.sender, address(this), paymentAmount), "Token transfer failed");
            item.escrowAmount = paymentAmount;
        }

        item.buyer = msg.sender;
        item.state = State.Sold;
        emit ItemSold(sku);
    }

    // Function to mark an item as shipped
    function shipItem(uint sku) external sold(sku) verifyCaller(items[sku].seller) {
        items[sku].state = State.Shipped;
        emit ItemShipped(sku);
    }

    // Function for a buyer to confirm receipt of an item and release funds
    function receiveItem(uint sku) external shipped(sku) verifyCaller(items[sku].buyer) {
        Item storage item = items[sku];

        // Calculate and send royalties
        uint royaltyAmount = (item.price * item.royaltyPercentage) / 100;
        if (item.paymentToken == address(0)) {
            payable(item.creator).transfer(royaltyAmount);
            payable(item.seller).transfer(item.escrowAmount - royaltyAmount);
        } else {
            IERC20 token = IERC20(item.paymentToken);
            require(token.transfer(item.creator, royaltyAmount), "Token transfer to creator failed");
            require(token.transfer(item.seller, item.escrowAmount - royaltyAmount), "Token transfer to seller failed");
        }

        item.state = State.Received;
        emit ItemReceived(sku);
    }

    // Function to resolve disputes
    function resolveDispute(uint sku, bool releaseFunds) external {
        require(msg.sender == mediator, "Not the mediator");
        require(disputes[sku], "No dispute for this item");

        Item storage item = items[sku];
        if (releaseFunds) {
            // Release funds from escrow to seller
            if (item.paymentToken == address(0)) {
                payable(item.seller).transfer(item.escrowAmount);
            } else {
                IERC20 token = IERC20(item.paymentToken);
                require(token.transfer(item.seller, item.escrowAmount), "Token transfer to seller failed");
            }
        }

        disputes[sku] = false;
        emit FundsReleased(sku);
    }

    // Function to initiate a dispute
    function initiateDispute(uint sku) external {
        require(msg.sender == items[sku].buyer, "Only the buyer can initiate a dispute");
        require(items[sku].state == State.Shipped, "Item must be shipped first");
        disputes[sku] = true;
    }

    // Function to update the buyer/seller reputation (admin controlled)
    function updateReputation(address user, uint rating) external onlyAdmin {
        require(rating <= 5 && rating >= 1, "Invalid rating");
        emit ReputationUpdated(user, rating);
    }

    // Multi-sig withdrawal approval function (for admin withdrawals)
    function approveWithdrawal(address to, uint amount) external onlyAdmin {
        uint approvalCount;
        for (uint i = 0; i < admins.length; i++) {
            if (isAdmin[admins[i]]) {
                approvalCount++;
            }
        }
        require(approvalCount >= approvalThreshold, "Not enough approvals");

        // Withdraw Ether or ERC20 tokens
        payable(to).transfer(amount);
    }

    // Function to withdraw ERC20 tokens (for admin withdrawals)
    function withdrawTokens(address _token, uint amount) external onlyAdmin {
        IERC20 token = IERC20(_token);
        require(token.balanceOf(address(this)) >= amount, "Insufficient token balance");
        token.transfer(owner(), amount);
    }
}
