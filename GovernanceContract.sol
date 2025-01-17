// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract Governance {
    IERC20 public governanceToken;
    address public contractOwner;

    // Proposal structure
    struct Proposal {
        uint256 id;
        address proposer;
        uint256 newRate;
        uint256 newSlippageThreshold;
        uint256 newFeePercent;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 endTime;
        bool executed;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(address => mapping(uint256 => bool)) public hasVoted;
    uint256 public proposalCount;
    uint256 public votingPeriod = 3 days;  // Voting period duration

    modifier onlyOwner() {
        require(msg.sender == contractOwner, "Not the contract owner");
        _;
    }

    modifier hasVotingRights() {
        require(governanceToken.balanceOf(msg.sender) > 0, "No governance tokens");
        _;
    }

    event ProposalCreated(uint256 proposalId, address proposer);
    event Voted(address voter, uint256 proposalId, bool support);
    event ProposalExecuted(uint256 proposalId);

    constructor(address _governanceToken) {
        governanceToken = IERC20(_governanceToken);
        contractOwner = msg.sender;
    }

    // Function to create a new proposal
    function createProposal(uint256 _newRate, uint256 _newSlippageThreshold, uint256 _newFeePercent) external hasVotingRights {
        proposalCount++;
        Proposal storage newProposal = proposals[proposalCount];
        newProposal.id = proposalCount;
        newProposal.proposer = msg.sender;
        newProposal.newRate = _newRate;
        newProposal.newSlippageThreshold = _newSlippageThreshold;
        newProposal.newFeePercent = _newFeePercent;
        newProposal.endTime = block.timestamp + votingPeriod;

        emit ProposalCreated(proposalCount, msg.sender);
    }

    // Function to vote on a proposal
    function vote(uint256 proposalId, bool support) external hasVotingRights {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp <= proposal.endTime, "Voting has ended");
        require(!hasVoted[msg.sender][proposalId], "Already voted");

        if (support) {
            proposal.votesFor += governanceToken.balanceOf(msg.sender);
        } else {
            proposal.votesAgainst += governanceToken.balanceOf(msg.sender);
        }

        hasVoted[msg.sender][proposalId] = true;
        emit Voted(msg.sender, proposalId, support);
    }

    // Function to execute a proposal after voting period ends
    function executeProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp > proposal.endTime, "Voting period is not over");
        require(!proposal.executed, "Proposal already executed");

        if (proposal.votesFor > proposal.votesAgainst) {
            // Execute the proposal (apply changes)
            // Example: update fee, slippage, and rate in the main contract
            // Note: You should integrate this with your main contract logic

            // Assuming the governance contract has the methods setRate, setSlippageThreshold, and setFeePercent
            // (You would call the corresponding functions in the SwappingContract to apply the changes)
            SwappingContract(address(this)).setRate(proposal.newRate);
            SwappingContract(address(this)).setSlippageThreshold(proposal.newSlippageThreshold);
            SwappingContract(address(this)).setFeePercent(proposal.newFeePercent);
        }

        proposal.executed = true;
        emit ProposalExecuted(proposalId);
    }
}

