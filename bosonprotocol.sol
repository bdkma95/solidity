// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

contract Escrow {
    enum State { AWAITING_PAYMENT, AWAITING_DELIVERY, COMPLETE }

    State public currState;
    address public buyer;
    address payable public seller;
    uint256 public paymentAmount;
    uint256 public escrowFeePercentageBuyer = 1; // Default fee for buyers (1%)
    uint256 public escrowFeePercentageSeller = 1; // Default fee for sellers (1%)
    mapping(address => uint256) public deposits;

    // Declare events for better transparency
    event Deposited(address indexed buyer, uint256 amount, uint256 fee);
    event Withdrawn(address indexed seller, uint256 amount, uint256 fee);
    event DeliveryConfirmed(address indexed buyer);
    event FeeDeducted(address indexed payer, uint256 feeAmount);
    event FeeUpdated(string role, uint256 newFee);

    // Modifiers
    modifier onlyBuyer() {
        require(msg.sender == buyer, "Only buyer can call this method");
        _;
    }

    modifier onlySeller() {
        require(msg.sender == seller, "Only seller can call this method");
        _;
    }

    modifier inState(State _state) {
        require(currState == _state, "Invalid state for this action");
        _;
    }

    // Constructor to initialize the buyer and seller
    constructor(address _buyer, address payable _seller) public {
        buyer = _buyer;
        seller = _seller;
        currState = State.AWAITING_PAYMENT;
    }

    // Function to set fee rates for buyers and sellers
    function setFeePercentage(uint256 newFeeBuyer, uint256 newFeeSeller) external {
        // Ensure the new fee is within an acceptable range (e.g., 0 to 5%)
        require(newFeeBuyer <= 5, "Fee for buyer cannot exceed 5%");
        require(newFeeSeller <= 5, "Fee for seller cannot exceed 5%");
        
        escrowFeePercentageBuyer = newFeeBuyer;
        escrowFeePercentageSeller = newFeeSeller;

        emit FeeUpdated("Buyer", newFeeBuyer);
        emit FeeUpdated("Seller", newFeeSeller);
    }

    // Function for the buyer to deposit funds to escrow
    function deposit() external onlyBuyer payable inState(State.AWAITING_PAYMENT) {
        uint256 amount = msg.value;
        require(amount > 0, "Deposit amount must be greater than 0");

        // Deduct fee for the buyer
        uint256 feeBuyer = (amount * escrowFeePercentageBuyer) / 100;
        uint256 amountAfterFee = amount - feeBuyer;

        deposits[seller] += amountAfterFee;
        paymentAmount += amountAfterFee;

        // Send the fee to the contract owner (or fee recipient address)
        address payable owner = address(uint160(msg.sender)); // Could be a platform address
        owner.transfer(feeBuyer);

        emit FeeDeducted(msg.sender, feeBuyer);
        emit Deposited(buyer, amountAfterFee, feeBuyer);
    }

    // Function to allow the seller to withdraw the funds after confirmation
    function withdraw() external onlySeller inState(State.AWAITING_DELIVERY) {
        uint256 payment = deposits[seller];
        require(payment > 0, "No funds to withdraw");

        // Deduct fee for the seller
        uint256 feeSeller = (payment * escrowFeePercentageSeller) / 100;
        uint256 amountAfterFee = payment - feeSeller;

        deposits[seller] = 0;  // Reset the deposit to prevent re-entrancy
        seller.transfer(amountAfterFee);

        // Send the fee to the contract owner (or fee recipient address)
        address payable owner = address(uint160(msg.sender)); // Could be a platform address
        owner.transfer(feeSeller);

        currState = State.AWAITING_DELIVERY;

        emit FeeDeducted(seller, feeSeller);
        emit Withdrawn(seller, amountAfterFee, feeSeller);
    }

    // Function for the buyer to confirm the delivery of the goods or service
    function confirmDelivery() external onlyBuyer inState(State.AWAITING_DELIVERY) {
        require(paymentAmount > 0, "No payment has been made");

        seller.transfer(address(this).balance); // Transfer remaining balance to seller
        currState = State.COMPLETE;

        emit DeliveryConfirmed(buyer);
    }

    // Function to get the current state
    function getState() external view returns (State) {
        return currState;
    }
}
