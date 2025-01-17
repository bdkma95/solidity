// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

contract Escrow {
    enum State { AWAITING_PAYMENT, AWAITING_DELIVERY, COMPLETE }

    State public currState;
    address public buyer;
    address payable public seller;
    uint256 public paymentAmount;
    uint256 public escrowFeePercentage = 1; // Fee percentage (1%)
    mapping(address => uint256) public deposits;

    // Declare events for better transparency
    event Deposited(address indexed buyer, uint256 amount);
    event Withdrawn(address indexed seller, uint256 amount);
    event DeliveryConfirmed(address indexed buyer);
    event FeeDeducted(address indexed payer, uint256 feeAmount);

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

    // Function for the buyer to deposit funds to escrow
    function deposit() external onlyBuyer payable inState(State.AWAITING_PAYMENT) {
        uint256 amount = msg.value;
        require(amount > 0, "Deposit amount must be greater than 0");

        // Deduct fee
        uint256 fee = (amount * escrowFeePercentage) / 100;
        uint256 amountAfterFee = amount - fee;

        deposits[seller] += amountAfterFee;
        paymentAmount += amountAfterFee;

        // Send the fee to the contract owner (assuming contract deployer is the fee recipient)
        address payable owner = address(uint160(msg.sender)); // Could be a dedicated fee recipient address
        owner.transfer(fee);

        emit FeeDeducted(msg.sender, fee);
        emit Deposited(buyer, amountAfterFee);
    }

    // Function to allow the seller to withdraw the funds after confirmation
    function withdraw() external onlySeller inState(State.AWAITING_DELIVERY) {
        uint256 payment = deposits[seller];
        require(payment > 0, "No funds to withdraw");

        deposits[seller] = 0;  // Reset the deposit to prevent re-entrancy
        seller.transfer(payment);

        currState = State.AWAITING_DELIVERY;

        emit Withdrawn(seller, payment);
    }

    // Function for the buyer to confirm the delivery of the goods or service
    function confirmDelivery() external onlyBuyer inState(State.AWAITING_DELIVERY) {
        require(paymentAmount > 0, "No payment has been made");

        seller.transfer(address(this).balance); // Transfer remaining balance to seller
        currState = State.COMPLETE;

        emit DeliveryConfirmed(buyer);
    }

    // Function to check if the contract is in a specific state
    function getState() external view returns (State) {
        return currState;
    }

    // Function to update the fee percentage (only the contract deployer can change it)
    function setFeePercentage(uint256 newFee) external {
        // Ensure the new fee is within an acceptable range (e.g., 0 to 5%)
        require(newFee <= 5, "Fee cannot exceed 5%");
        escrowFeePercentage = newFee;
    }
}
