// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

interface IToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract TokenSwap {
    address public owner;
    mapping(address => mapping(address => uint256)) public exchangeRates; // [tokenA][tokenB] => rate

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setExchangeRate(address tokenA, address tokenB, uint256 rate) public onlyOwner {
        exchangeRates[tokenA][tokenB] = rate;
    }

    function swap(address tokenA, address tokenB, uint256 amount) public {
        uint256 rate = exchangeRates[tokenA][tokenB];
        require(rate > 0, "Exchange rate not set");

        IToken(tokenA).transferFrom(msg.sender, address(this), amount);
        uint256 amountToReceive = amount * rate;
        IToken(tokenB).transfer(msg.sender, amountToReceive);
    }
}
