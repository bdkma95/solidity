// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

contract Voting {
    // Mapping to store votes for each team
    mapping(string => uint256) public votes;

    // Mapping to track if a user has already voted
    mapping(address => bool) public hasVoted;

    // Event to log votes
    event Voted(address indexed voter, string team);

    // Function to vote for a team
    function vote(string memory team) public {
        require(!hasVoted[msg.sender], "You have already voted.");
        require(bytes(team).length > 0, "Team name cannot be empty.");

        // Normalize the team name to lowercase to ensure case-insensitivity
        string memory normalizedTeam = toLower(team);

        // Increment the vote for the selected team
        votes[normalizedTeam]++;

        // Mark the sender as voted
        hasVoted[msg.sender] = true;

        // Emit a vote event
        emit Voted(msg.sender, normalizedTeam);
    }

    // Function to get the vote count for a team
    function getVotes(string memory team) public view returns (uint256) {
        string memory normalizedTeam = toLower(team);
        return votes[normalizedTeam];
    }

    // Helper function to convert a string to lowercase
    function toLower(string memory str) public pure returns (string memory) {
        bytes memory bStr = bytes(str);
        for (uint i = 0; i < bStr.length; i++) {
            if ((bStr[i] >= 65) && (bStr[i] <= 90)) { // If uppercase letter
                bStr[i] = bytes1(uint8(bStr[i]) + 32); // Convert to lowercase
            }
        }
        return string(bStr);
    }
}
