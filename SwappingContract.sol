// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract SwappingContract {
    address public owner; // Owner of the contract
    IERC20 public token; // ERC20 token contract
    uint256 public rate; // The exchange rate (number of tokens per Ether)

    uint256 public maxSwapAmount; // Maximum allowed Ether to swap in one transaction

    // Reentrancy guard modifier
    bool private locked;

    event Swap(address indexed user, uint256 etherAmount, uint256 tokenAmount);
    event WithdrawEther(address indexed owner, uint256 amount);
    event RateUpdated(uint256 newRate);
    event TokensRecovered(address indexed token, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the contract owner");
        _;
    }

    modifier noReentrancy() {
        require(!locked, "Reentrancy detected");
        locked = true;
        _;
        locked = false;
    }

    constructor(address _tokenAddress, uint256 _rate, uint256 _maxSwapAmount) {
        owner = msg.sender;
        token = IERC20(_tokenAddress);
        rate = _rate;
        maxSwapAmount = _maxSwapAmount;
    }

    // Function to exchange Ether for tokens
    function swapEtherToToken() external payable noReentrancy returns (uint256) {
        require(msg.value > 0, "Must send Ether to swap");
        require(msg.value <= maxSwapAmount, "Swap exceeds maximum limit");

        uint256 tokenAmount = msg.value * rate; // Calculate the number of tokens to send

        uint256 contractTokenBalance = token.balanceOf(address(this));
        require(contractTokenBalance >= tokenAmount, "Not enough tokens in the contract");

        // Transfer the tokens to the user
        token.transfer(msg.sender, tokenAmount);

        emit Swap(msg.sender, msg.value, tokenAmount);
        return tokenAmount;
    }

    // Allow the contract to receive Ether
    receive() external payable {}

    // Fallback function to handle unexpected calls
    fallback() external payable {}

    // Function to withdraw Ether accumulated in the contract
    function withdrawEther(uint256 amount) external onlyOwner noReentrancy {
        require(address(this).balance >= amount, "Not enough Ether in the contract");
        payable(owner).transfer(amount);
        emit WithdrawEther(owner, amount);
    }

    // Function to adjust the exchange rate
    function setRate(uint256 _rate) external onlyOwner {
        rate = _rate;
        emit RateUpdated(_rate);
    }

    // Function to update the maximum allowed swap amount
    function setMaxSwapAmount(uint256 _maxSwapAmount) external onlyOwner {
        maxSwapAmount = _maxSwapAmount;
    }

    // Function to recover tokens accidentally sent to the contract
    function recoverTokens(address _tokenAddress, uint256 _amount) external onlyOwner {
        IERC20(_tokenAddress).transfer(owner, _amount);
        emit TokensRecovered(_tokenAddress, _amount);
    }
}
