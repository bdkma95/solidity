// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

contract Crowdfunding {
    address public manager;
    uint256 public totalFunds; // Total funds in the contract
    uint256 public start; // Start time
    uint256 public end; // End time
    uint256 public counter; // Project ID counter

    struct Project {
        uint256 id;
        address payable owner;
        string projectName;
        string description;
        uint256 expectedCost;
        bool isVerified;
        uint256 fundedAmount;
        uint256 fundsWithdrawn;
    }

    mapping(address => uint256) public projectIdByAddress;
    mapping(uint256 => Project) public projects;

    event ProjectRegistered(uint256 indexed projectId, uint256 timestamp, string name, address indexed owner);
    event ProjectVerified(uint256 indexed projectId, uint256 timestamp);
    event FundsTransferred(uint256 indexed projectId, uint256 timestamp, address indexed from, uint256 amount);
    event FundsWithdrawn(uint256 indexed projectId, uint256 timestamp, address indexed to, uint256 amount);

    modifier onlyManager() {
        require(msg.sender == manager, "Caller is not the manager");
        _;
    }

    modifier onlyProjectOwner(uint256 projectId) {
        require(projects[projectId].owner == msg.sender, "Caller is not the project owner");
        _;
    }

    modifier onlyVerifiedProject(uint256 projectId) {
        require(projects[projectId].isVerified, "Project is not verified");
        _;
    }

    constructor(uint256 _durationInDays) {
        manager = msg.sender;
        start = block.timestamp;
        end = block.timestamp + (_durationInDays * 1 days);
    }

    function registerProject(
        string calldata projectName,
        string calldata description,
        uint256 expectedCost
    ) external {
        require(block.timestamp < end, "Registration period has ended");
        require(projectIdByAddress[msg.sender] == 0, "Address already registered a project");

        counter++;
        projects[counter] = Project({
            id: counter,
            owner: payable(msg.sender),
            projectName: projectName,
            description: description,
            expectedCost: expectedCost,
            isVerified: false,
            fundedAmount: 0,
            fundsWithdrawn: 0
        });

        projectIdByAddress[msg.sender] = counter;

        emit ProjectRegistered(counter, block.timestamp, projectName, msg.sender);
    }

    function verifyProject(uint256 projectId) external onlyManager {
        require(projects[projectId].owner != address(0), "Invalid project ID");
        projects[projectId].isVerified = true;

        emit ProjectVerified(projectId, block.timestamp);
    }

    function viewProject(uint256 projectId)
        external
        view
        onlyVerifiedProject(projectId)
        returns (
            uint256 id,
            address owner,
            string memory projectName,
            string memory description,
            uint256 expectedCost,
            uint256 fundedAmount
        )
    {
        Project storage project = projects[projectId];
        return (
            project.id,
            project.owner,
            project.projectName,
            project.description,
            project.expectedCost,
            project.fundedAmount
        );
    }

    function timeLeft() external view returns (uint256) {
        return block.timestamp < end ? end - block.timestamp : 0;
    }

    function sendFunds(uint256 projectId) external payable onlyVerifiedProject(projectId) {
        require(block.timestamp < end, "Funding period has ended");
        require(msg.sender != projects[projectId].owner, "Owner cannot fund their own project");
        require(msg.value > 0, "Funding amount must be greater than zero");

        projects[projectId].fundedAmount += msg.value;
        totalFunds += msg.value;

        emit FundsTransferred(projectId, block.timestamp, msg.sender, msg.value);
    }

    function withdrawFunds(uint256 projectId) external onlyProjectOwner(projectId) {
        require(block.timestamp > end, "Funding period is still ongoing");
        Project storage project = projects[projectId];
        uint256 amount = project.fundedAmount - project.fundsWithdrawn;

        require(amount > 0, "No funds available for withdrawal");

        project.fundsWithdrawn += amount;
        (bool success, ) = project.owner.call{value: amount}("");
        require(success, "Transfer failed");

        emit FundsWithdrawn(projectId, block.timestamp, project.owner, amount);
    }

    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
