// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IChainlinkPriceFeed {
    function latestRoundData() external view returns (
        uint80 roundId, 
        int256 answer, 
        uint256 startedAt, 
        uint256 updatedAt, 
        uint80 answeredInRound
    );
}

contract SwappingContract {
    address public owner; // Owner of the contract
    IERC20 public token; // ERC20 token contract
    uint256 public rate; // The exchange rate (number of tokens per Ether)
    uint256 public feePercent; // Fee percentage for the swap (in basis points, e.g., 100 = 1%)
    address public feeRecipient; // Address to receive the fees

    uint256 public maxSwapAmount; // Maximum allowed Ether to swap in one transaction

    IChainlinkPriceFeed public priceFeed; // Chainlink price feed for dynamic slippage
    uint256 public slippageThreshold; // Max slippage percentage allowed (in basis points, e.g., 500 = 5%)

    bool private locked;

    event Swap(address indexed user, uint256 etherAmount, uint256 tokenAmount, uint256 feeAmount);
    event WithdrawEther(address indexed owner, uint256 amount);
    event RateUpdated(uint256 newRate);
    event FeeUpdated(uint256 newFeePercent);
    event FeeRecipientUpdated(address newFeeRecipient);
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

    constructor(address _tokenAddress, uint256 _rate, uint256 _maxSwapAmount, uint256 _feePercent, address _feeRecipient, address _priceFeedAddress) {
        owner = msg.sender;
        token = IERC20(_tokenAddress);
        rate = _rate;
        maxSwapAmount = _maxSwapAmount;
        feePercent = _feePercent;
        feeRecipient = _feeRecipient;
        priceFeed = IChainlinkPriceFeed(_priceFeedAddress);
        slippageThreshold = 500; // Default 5% slippage tolerance
    }

    // Fetch the latest price from Chainlink
    function getLatestPrice() public view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price feed response");
        return uint256(price);
    }

    // Function to exchange Ether for tokens with fee and dynamic slippage protection
    function swapEtherToToken(uint256 slippage) external payable noReentrancy returns (uint256) {
        require(msg.value > 0, "Must send Ether to swap");
        require(msg.value <= maxSwapAmount, "Swap exceeds maximum limit");

        uint256 tokenAmount = msg.value * rate; // Calculate the number of tokens to send

        // Fetch current price and calculate dynamic slippage
        uint256 currentPrice = getLatestPrice();
        uint256 slippageAmount = (tokenAmount * slippage) / 10000;
        uint256 minAmountToReceive = tokenAmount - slippageAmount;

        // If the slippage exceeds the threshold, revert
        require(tokenAmount >= minAmountToReceive, "Slippage too high");

        uint256 feeAmount = (tokenAmount * feePercent) / 10000;
        uint256 amountToTransfer = tokenAmount - feeAmount;

        uint256 contractTokenBalance = token.balanceOf(address(this));
        require(contractTokenBalance >= amountToTransfer, "Not enough tokens in the contract");

        // Transfer the tokens to the user
        token.transfer(msg.sender, amountToTransfer);

        // Transfer the fee to the feeRecipient
        if (feeAmount > 0) {
            token.transfer(feeRecipient, feeAmount);
        }

        emit Swap(msg.sender, msg.value, amountToTransfer, feeAmount);
        return amountToTransfer;
    }

    // Function to swap ERC20 tokens for Ether or another ERC20 token
    function swapTokenToToken(address fromToken, address toToken, uint256 amount, uint256 minAmountOut) external noReentrancy returns (uint256) {
        require(amount > 0, "Must send tokens to swap");

        IERC20(fromToken).transferFrom(msg.sender, address(this), amount);

        uint256 rateFrom = rate; // Define the rate for the swap based on tokens
        uint256 amountToTransfer = amount * rateFrom;

        // Ensure slippage protection
        require(amountToTransfer >= minAmountOut, "Slippage too high");

        // Transfer the swapped tokens to the user
        IERC20(toToken).transfer(msg.sender, amountToTransfer);

        emit Swap(msg.sender, amount, amountToTransfer, 0); // No fee for token-to-token swaps
        return amountToTransfer;
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

    // Function to set the fee percentage (in basis points, e.g., 100 = 1%)
    function setFeePercent(uint256 _feePercent) external onlyOwner {
        feePercent = _feePercent;
        emit FeeUpdated(_feePercent);
    }

    // Function to set the fee recipient address
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    // Function to update the slippage threshold
    function setSlippageThreshold(uint256 _slippageThreshold) external onlyOwner {
        slippageThreshold = _slippageThreshold;
    }

    // Function to recover tokens accidentally sent to the contract
    function recoverTokens(address _tokenAddress, uint256 _amount) external onlyOwner {
        IERC20(_tokenAddress).transfer(owner, _amount);
        emit TokensRecovered(_tokenAddress, _amount);
    }
}
