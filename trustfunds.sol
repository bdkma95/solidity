// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

contract Trustfunds {
    struct Child {
        uint amount;        // Amount the child will receive
        uint majority;      // Timestamp when the child can withdraw
        bool paid;          // Whether the child has been paid already
    }

    mapping(address => Child) public children; // Mapping of child address to their Trustfund details
    address public admin; // Address of the admin (who can add children)

    // Only admin can add a child
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can add a child");
        _;
    }

    constructor() {
        admin = msg.sender; 
    }

    // Function to add a child to the trust fund
    function addChild(address child, uint timetomajority) external payable onlyAdmin {
        require(children[child].amount == 0, "Child already exists");
        require(msg.value > 0, "Must send funds to create a trust fund");

        // Creating the trust fund for the child
        children[child] = Child({
            amount: msg.value, 
            majority: block.timestamp + timetomajority, 
            paid: false
        });
    }

    // Function to allow the child to withdraw the funds once they reach majority
    function withdraw() external {
        Child storage child = children[msg.sender];

        // Check that the child can withdraw (has reached majority)
        require(child.majority <= block.timestamp, "Too early to withdraw");
        require(child.amount > 0, "No funds available for withdrawal");
        require(!child.paid, "Already paid out");

        // Mark the child as paid to avoid double withdrawal
        child.paid = true;

        // Transfer the funds to the child
        payable(msg.sender).transfer(child.amount);
    }

    // Function to check the trust fund details of a child
    function getTrustFundDetails(address child) external view returns (uint amount, uint majority, bool paid) {
        Child storage c = children[child];
        return (c.amount, c.majority, c.paid);
    }
}
