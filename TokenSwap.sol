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
    mapping(address => uint256) public userSwapCount; // Tracks how many swaps a user has made
    uint256 public baseFeePercentage; // Base fee percentage

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    event ExchangeRateSet(address indexed tokenA, address indexed tokenB, uint256 rate);
    event TokensSwapped(address indexed user, address[] tokenSequence, uint256[] amountsIn, uint256[] amountsOut, uint256 fee);

    constructor() {
        owner = msg.sender;
        baseFeePercentage = 1; // Default fee of 1%
    }

    // Set the exchange rate between tokenA and tokenB
    function setExchangeRate(address tokenA, address tokenB, uint256 rate) public onlyOwner {
        require(rate > 0, "Rate must be greater than zero");
        exchangeRates[tokenA][tokenB] = rate;
        emit ExchangeRateSet(tokenA, tokenB, rate);
    }

    // Set the base fee percentage for each swap
    function setBaseFeePercentage(uint256 newFeePercentage) public onlyOwner {
        require(newFeePercentage <= 100, "Fee percentage cannot exceed 100");
        baseFeePercentage = newFeePercentage;
    }

    // Calculate dynamic fee based on user swap count
    function getDynamicFee(address user) public view returns (uint256) {
        uint256 swaps = userSwapCount[user];
        // Example dynamic fee structure: reduce fee after 10 swaps
        if (swaps > 10) {
            return baseFeePercentage / 2; // 50% discount after 10 swaps
        }
        return baseFeePercentage; // Default fee
    }

    // Swap multiple tokens in sequence
    function multiTokenSwap(address[] memory tokens, uint256[] memory amounts) public {
        require(tokens.length == amounts.length, "Token list and amount list length mismatch");
        require(tokens.length > 1, "At least 2 tokens are needed to perform a multi-token swap");

        uint256 totalFee;
        uint256[] memory amountsOut = new uint256[](tokens.length);
        
        // Iterate through the token sequence and perform swaps
        for (uint256 i = 0; i < tokens.length - 1; i++) {
            address tokenA = tokens[i];
            address tokenB = tokens[i + 1];
            uint256 amountIn = amounts[i];

            uint256 rate = exchangeRates[tokenA][tokenB];
            require(rate > 0, "Exchange rate not set");

            // Apply dynamic fee based on user swaps
            uint256 fee = (amountIn * getDynamicFee(msg.sender)) / 100;
            uint256 amountAfterFee = amountIn - fee;

            // Transfer tokenA from the sender to the contract
            IToken(tokenA).transferFrom(msg.sender, address(this), amountIn);

            // Calculate the amount to receive in tokenB
            uint256 amountToReceive = amountAfterFee * rate;

            // Ensure the contract has enough tokens to send
            uint256 balanceTokenB = IToken(tokenB).balanceOf(address(this));
            require(balanceTokenB >= amountToReceive, "Insufficient contract balance");

            // Transfer fee to the owner
            IToken(tokenA).transfer(owner, fee);

            // Update the amount to send in the next swap
            amountsOut[i + 1] = amountToReceive;
            emit TokensSwapped(msg.sender, tokens, amounts, amountsOut, fee);

            // Increment swap count for the user
            userSwapCount[msg.sender]++;
        }
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
