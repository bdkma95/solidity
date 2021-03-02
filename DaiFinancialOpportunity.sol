// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import { Dai, TrueUSD } from "./StableCoins.sol";
import { FinancialOpportunity } from "./FinancialOpportunity.sol";
import { DaiPot, DSRMock } from "./DSR.sol";
import { SwapContract, SwapContractMock } from "./SwapContract.sol";

/**
 * @title Dai Financial Opportunity
 * @dev Pool TUSD deposits to earn interest using DSR
 *
 * When a user wants to deposit TrueUSD** the contract will exchange 
 * the TUSD for Dai using Uniswap, and then deposit DAI into a DSR.
 *
 * When a user wants to redeem their stake for TrueUSD the contract will 
 * withdraw DAI from a DSR, then swap the DAI for TrueUSD using Uniswap.

 * Implement the 4 functions from FinancialOpportunity in a new contract: 
 * deposit(), redeem(), tokenValue(), and totalSupply(). 
 * 
 * Make sure to read the documentation in FinaicialOpportunity.sol carefully 
 * to make sure you understand the purpose of each of these functions. 
 *
 * Note: the contract mocks are untested and might require modifications!
 *
**/
contract ERC20Interface {
    function deposit(address from, uint amount) external payable returns (uint);
    function redeem(address to, uint amount) external returns (uint);
    function tokenValue() external view returns (uint);
    function totalSupply() external view returns (uint);

    event Transfer(address indexed from, address indexed to, uint tokens);
    event Approval(address indexed tokenOwner, address indexed spender, uint tokens);
}

contract DaiFinancialOpportunity is FinancialOpportunity {
    address admin;
    IERC20 dai = IERC20(0x6b175474e89094c44da98b954eedeac495271d0f);
    IERC20 yTUSD = IERC20(0x73a052500105205d34daf004eab301916da8190f);
    IERC20 TUSD = IERC20(0x0000000000085d4780B73119b644AE5ecd22b376);
    
    constructor() public {
        admin = msg.sender;
    }
    
    function deposit(address from, uint amount) external payable returns(uint) {
        uint256 amount = msg.value;
        deposits[_seller] = deposits[_seller] + amount;
        return uint;
    }

    /**
     * @dev Redeem yTUSD for TUSD and withdraw to account
     *
     * This function should use tokenValue to calculate
     * how much TUSD is owed. This function should burn yTUSD
     * after redemption
     *
     * This function must return value in TUSD
     *
     * @param to account to transfer TUSD for
     * @param amount amount in TUSD to withdraw from finOp
     * @return TUSD amount returned from this transaction
     */
    }
    
    function redeem(address to, uint amount) external returns(uint) {
        _tusd: uint256 = min(ERC20(tusd).balanceOf(msg.sender), ERC20(tusd).allowance(msg.sender, self));
        uint256 senderEligibility = redeemBalanceOf[msg.sender];
        uint256 tokensAvailable = token.balanceOf(this);
        require(senderEligibility >= baseUnits);
        require( tokensAvailable >= baseUnits);
        if(token.transfer(msg.sender,baseUnits)){
            redeemBalanceOf[msg.sender] -= baseUnits;
            Redeemed(msg.sender,quantity);
      }
    };
    
    function tokenValue() external view returns(uint) {
        return _tokenValue  - balances[address(0)];
    };

    /**
     * @dev deposits TrueUSD and returns yTUSD minted
     *
     * We can think of deposit as a minting function which
     * will increase totalSupply of yTUSD based on the deposit
     *
     * @param from account to transferFrom
     * @param amount amount in TUSD to deposit
     * @return yTUSD minted from this deposit
     */
     function totalSupply() external view returns (uint) {
         return _totalSupply  - balances[address(0)];
     };
     

    /**
     * @dev Exchange rate between TUSD and yTUSD
     *
     * tokenValue should never decrease
     *
     * @return TUSD / yTUSD price ratio
     */
}
