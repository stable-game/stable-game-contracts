// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import '../../Interfaces/IPool.sol';

interface IPoolErc20 is IPool {

    // --- Functions ---
    
    function increaseColl(uint256 _amount) external;
}
