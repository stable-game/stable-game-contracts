// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./IPoolErc20.sol";


interface IDefaultPoolErc20 is IPoolErc20 {
    // --- Events ---
    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event DefaultPoolGMDebtUpdated(uint _GMDebt);
    event DefaultPoolETHBalanceUpdated(uint _ETH);

    // --- Functions ---
    function sendETHToActivePool(uint _amount) external;
}
