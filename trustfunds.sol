pragma solidity ^0.8.3;

contract Trustfunds {
    struct Child {
        uint amount;
        uint majority;
        bool paid;
    }
    mapping(address => Child) public children;
    address public admin;
    
    constructor() {
       admin = msg.sender; 
    }
    
    function addChild(address child, uint timetomajority) external payable {
        require(msg.sender == admin, 'Only admin');
        require(children[msg.sender].amount == 0, 'child already exist');
        children[child] = Child(msg.value, block.timestamp + timetomajority, false);
    }
    
    function withdraw() external {
        Child storage child = children[msg.sender];
        require(child.majority <= block.timestamp, 'too early');
        require(child.amount > 0, 'Only child can withdraw');
        require(child.paid == false, 'Paid already');
        child.paid = true;
        payable(msg.sender).transfer(child.amount);
    }
}
