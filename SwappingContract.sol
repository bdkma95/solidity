// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

interface ERC20Swapper {
    /// @dev swaps the `msg.value` Ether to at least `minAmount` of tokens in `address`, or reverts
    /// @param token The address of ERC-20 token to swap
    /// @param minAmount The minimum amount of tokens transferred to msg.sender
    /// @return The actual amount of transferred tokens
    function swapEtherToToken(address token, uint minAmount) external payable returns (uint);
}

// Interface to interact with an ERC20 token
interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract SwappingContract {
    address public owner; // Owner of the contract
    IERC20 public token; // ERC20 token contract
    uint256 public rate; // The exchange rate (number of tokens per Ether)

    event Swap(address indexed user, uint256 etherAmount, uint256 tokenAmount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the contract owner");
        _;
    }

    constructor(address _tokenAddress, uint256 _rate) {
        owner = msg.sender;
        token = IERC20(_tokenAddress);
        rate = _rate;
    }

    // Function to exchange Ether for tokens
    function swapEtherToToken() external payable returns (uint256) {
        
        require(address(token) != address(0));
        require(msg.value >= 0);
        uint256 tokenAmount = msg.value * rate; // Calculate the number of tokens to send
       
        uint256 contractTokenBalance = token.balanceOf(address(this));
        require(contractTokenBalance >= tokenAmount, "Not enough tokens in the contract");

        (token.transfer(msg.sender, tokenAmount));

        emit Swap(msg.sender, msg.value, tokenAmount);
        return tokenAmount;
    }

    // Allow the contract to receive Ether
    receive() external payable {}

    // Function to withdraw Ether accumulated in the contract
    function withdrawEther(uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "Not enough ether in the contract");
        payable(owner).transfer(amount);
    }

    // Function to adjust the exchange rate
    function setRate(uint256 _rate) external onlyOwner {
        rate = _rate;
    }

    // Function to retrieve tokens accidentally sent to the contract
    function recoverTokens(address _tokenAddress, uint256 _amount) external onlyOwner {
        IERC20(_tokenAddress).transfer(owner, _amount);

    } 
}
