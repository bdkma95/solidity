// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

interface IToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract TokenSwap {
    address public owner;
    mapping(address => mapping(address => uint256)) public exchangeRates; // [tokenA][tokenB] => rate
    uint256 public feePercentage; // Fee as a percentage of the swap amount

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    event ExchangeRateSet(address indexed tokenA, address indexed tokenB, uint256 rate);
    event TokensSwapped(address indexed user, address indexed tokenA, address indexed tokenB, uint256 amountIn, uint256 amountOut, uint256 fee);

    constructor() {
        owner = msg.sender;
        feePercentage = 1; // Default fee of 1%
    }

    // Set the exchange rate between tokenA and tokenB
    function setExchangeRate(address tokenA, address tokenB, uint256 rate) public onlyOwner {
        require(rate > 0, "Rate must be greater than zero");
        exchangeRates[tokenA][tokenB] = rate;
        emit ExchangeRateSet(tokenA, tokenB, rate);
    }

    // Set a fee percentage for each swap (e.g., 1% fee)
    function setFeePercentage(uint256 newFeePercentage) public onlyOwner {
        require(newFeePercentage <= 100, "Fee percentage cannot exceed 100");
        feePercentage = newFeePercentage;
    }

    // Swap tokenA for tokenB with a fee mechanism
    function swap(address tokenA, address tokenB, uint256 amount) public {
        uint256 rate = exchangeRates[tokenA][tokenB];
        require(rate > 0, "Exchange rate not set");
        require(amount > 0, "Amount must be greater than zero");

        // Transfer tokenA from the sender to the contract
        uint256 fee = (amount * feePercentage) / 100;
        uint256 amountAfterFee = amount - fee;
        IToken(tokenA).transferFrom(msg.sender, address(this), amount);

        // Calculate the amount to receive in tokenB (taking the rate into account)
        uint256 amountToReceive = amountAfterFee * rate;

        // Ensure the contract has enough tokens to send
        uint256 balanceTokenB = IToken(tokenB).balanceOf(address(this));
        require(balanceTokenB >= amountToReceive, "Insufficient contract balance");

        // Transfer the fee to the owner and the remaining amount to the sender
        IToken(tokenA).transfer(owner, fee); // Fee is transferred to the owner
        IToken(tokenB).transfer(msg.sender, amountToReceive);

        // Emit event for the swap
        emit TokensSwapped(msg.sender, tokenA, tokenB, amount, amountToReceive, fee);
    }

    // Function to add liquidity (tokens) to the contract, allowing swaps
    function addLiquidity(address token, uint256 amount) public onlyOwner {
        IToken(token).transferFrom(msg.sender, address(this), amount);
    }

    // Function to remove liquidity (tokens) from the contract
    function removeLiquidity(address token, uint256 amount) public onlyOwner {
        uint256 contractBalance = IToken(token).balanceOf(address(this));
        require(contractBalance >= amount, "Insufficient contract balance");
        IToken(token).transfer(msg.sender, amount);
    }

    // Function to get the current exchange rate between two tokens
    function getExchangeRate(address tokenA, address tokenB) public view returns (uint256) {
        return exchangeRates[tokenA][tokenB];
    }

    // Function to get the contract balance of a specific token
    function getBalance(address token) public view returns (uint256) {
        return IToken(token).balanceOf(address(this));
    }
}
