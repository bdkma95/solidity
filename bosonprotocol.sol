pragma solidity ^0.6.0;

contract Escrow {
    enum State { AWAITING_PAYMENT, AWAITING_DELIVERY, COMPLETE }
    
    State public currState;
    
    address public buyer;
    address payable public seller;
    mapping(address => uint256) public deposits;
    
    modifier onlyBuyer () {
        require(msg.sender == buyer, "Only buyer can call this method");
        _;
    }
    
    constructor(address _buyer, address payable _seller) public {
        buyer = _buyer;
        seller = _seller;
    }
    
    function deposit(address payable _seller) public onlyBuyer payable {
        uint256 amount = msg.value;
        deposits[_seller] = deposits[_seller] + amount;
        currState = State.AWAITING_PAYMENT;
        
    }
    
    function withdraw(address payable _seller) public onlyBuyer {
        uint256 payment = deposits[_seller];
        deposits[_seller] = 0;
        _seller.transfer(payment);
        currState = State.AWAITING_DELIVERY;
    }
    
    
    function confirmDelivery() onlyBuyer external {
        require(currState == State.AWAITING_DELIVERY, "Cannot confirm delivery");
        seller.transfer(address(this).balance);
        currState = State.COMPLETE;
    }
}
