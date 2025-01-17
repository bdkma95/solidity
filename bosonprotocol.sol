// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

contract Escrow {
    enum State { AWAITING_PAYMENT, AWAITING_DELIVERY, COMPLETE }

    State public currState;
    address public buyer;
    address payable public seller;
    uint256 public paymentAmount;
    uint256 public escrowFeePercentageBuyer = 1; // Default fee for buyers (1%)
    uint256 public escrowFeePercentageSeller = 1; // Default fee for sellers (1%)
    uint256 public earlyPaymentDiscount = 10; // 10% discount for early payments
    uint256 public earlyPaymentDeadline; // Deadline timestamp for early payment discounts
    mapping(address => uint256) public deposits;

    // Define events for better transparency
    event Deposited(address indexed buyer, uint256 amount, uint256 fee);
    event Withdrawn(address indexed seller, uint256 amount, uint256 fee);
    event DeliveryConfirmed(address indexed buyer);
    event FeeDeducted(address indexed payer, uint256 feeAmount);
    event FeeUpdated(string role, uint256 newFee);
    event MultiPartyFeeDistributed(address indexed feeRecipient, uint256 amount);

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

    // Constructor to initialize the buyer, seller, and early payment discount deadline
    constructor(address _buyer, address payable _seller, uint256 _earlyPaymentDeadline) public {
        buyer = _buyer;
        seller = _seller;
        earlyPaymentDeadline = _earlyPaymentDeadline;
        currState = State.AWAITING_PAYMENT;
    }

    // Function to set fee rates for buyers and sellers
    function setFeePercentage(uint256 newFeeBuyer, uint256 newFeeSeller) external {
        require(newFeeBuyer <= 5, "Fee for buyer cannot exceed 5%");
        require(newFeeSeller <= 5, "Fee for seller cannot exceed 5%");

        escrowFeePercentageBuyer = newFeeBuyer;
        escrowFeePercentageSeller = newFeeSeller;

        emit FeeUpdated("Buyer", newFeeBuyer);
        emit FeeUpdated("Seller", newFeeSeller);
    }

    // Function to set early payment discount (percentage)
    function setEarlyPaymentDiscount(uint256 discountPercentage) external {
        require(discountPercentage <= 50, "Discount cannot exceed 50%");
        earlyPaymentDiscount = discountPercentage;
    }

    // Function to deposit funds into escrow with tiered fees and early payment discounts
    function deposit() external onlyBuyer payable inState(State.AWAITING_PAYMENT) {
        uint256 amount = msg.value;
        require(amount > 0, "Deposit amount must be greater than 0");

        // Apply tiered fees based on deposit amount
        uint256 feeBuyer = calculateTieredFee(amount, escrowFeePercentageBuyer);
        uint256 amountAfterFee = amount - feeBuyer;

        // Check if the buyer qualifies for early payment discount
        uint256 finalFeeBuyer = feeBuyer;
        if (block.timestamp <= earlyPaymentDeadline) {
            uint256 discount = (feeBuyer * earlyPaymentDiscount) / 100;
            finalFeeBuyer = feeBuyer - discount;
            amountAfterFee = amount - finalFeeBuyer;
        }

        deposits[seller] += amountAfterFee;
        paymentAmount += amountAfterFee;

        // Deduct fee and distribute it to the platform and charity (multi-party fee distribution)
        uint256 platformFee = finalFeeBuyer / 2; // 50% goes to platform
        uint256 charityFee = finalFeeBuyer / 2; // 50% goes to charity or other recipient

        address payable platform = 0x1234567890abcdef1234567890abcdef12345678; // Platform address
        address payable charity = 0xabcdefabcdefabcdefabcdefabcdefabcdefabcdef; // Charity address

        platform.transfer(platformFee);
        charity.transfer(charityFee);

        // Emit events for fee deduction and deposits
        emit FeeDeducted(msg.sender, finalFeeBuyer);
        emit Deposited(buyer, amountAfterFee, finalFeeBuyer);
        emit MultiPartyFeeDistributed(platform, platformFee);
        emit MultiPartyFeeDistributed(charity, charityFee);
    }

    // Function for the seller to withdraw funds after confirmation
    function withdraw() external onlySeller inState(State.AWAITING_DELIVERY) {
        uint256 payment = deposits[seller];
        require(payment > 0, "No funds to withdraw");

        // Apply tiered fees for the seller
        uint256 feeSeller = calculateTieredFee(payment, escrowFeePercentageSeller);
        uint256 amountAfterFee = payment - feeSeller;

        deposits[seller] = 0;  // Prevent re-entrancy
        seller.transfer(amountAfterFee);

        // Deduct fee and distribute it
        uint256 platformFee = feeSeller / 2;
        uint256 charityFee = feeSeller / 2;

        address payable platform = 0x1234567890abcdef1234567890abcdef12345678; // Platform address
        address payable charity = 0xabcdefabcdefabcdefabcdefabcdefabcdefabcdef; // Charity address

        platform.transfer(platformFee);
        charity.transfer(charityFee);

        currState = State.AWAITING_DELIVERY;

        // Emit events for fee deduction and withdrawals
        emit FeeDeducted(seller, feeSeller);
        emit Withdrawn(seller, amountAfterFee, feeSeller);
        emit MultiPartyFeeDistributed(platform, platformFee);
        emit MultiPartyFeeDistributed(charity, charityFee);
    }

    // Function for the buyer to confirm the delivery of goods or services
    function confirmDelivery() external onlyBuyer inState(State.AWAITING_DELIVERY) {
        require(paymentAmount > 0, "No payment has been made");

        seller.transfer(address(this).balance); // Transfer the remaining balance to the seller
        currState = State.COMPLETE;

        emit DeliveryConfirmed(buyer);
    }

    // Function to calculate tiered fees based on the amount
    function calculateTieredFee(uint256 amount, uint256 baseFeePercentage) private pure returns (uint256) {
        if (amount >= 10 ether) {
            return (amount * (baseFeePercentage - 1)) / 100; // 1% fee for large deposits (>= 10 ETH)
        } else if (amount >= 1 ether) {
            return (amount * (baseFeePercentage - 0.5)) / 100; // 0.5% fee for deposits >= 1 ETH
        } else {
            return (amount * baseFeePercentage) / 100; // Default fee
        }
    }

    // Function to get the current state
    function getState() external view returns (State) {
        return currState;
    }
}
