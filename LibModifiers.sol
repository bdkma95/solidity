// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibErrors} from "./LibErrors.sol";

library LibModifiers {

    function checkNotPaused(bool isPaused) internal pure {
        if (isPaused) revert LibErrors.TokenPaused();
    }

    function checkNonZero(address account) internal pure {
        if (account == address(0)) revert LibErrors.ZeroAddress();
    }

    function checkNonZeroAmount(uint256 amount) internal pure {
        if (amount == 0) revert LibErrors.ZeroAmount();
    }

}
