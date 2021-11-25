// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./IPoolErc20.sol";


interface IActivePoolErc20 is IPoolErc20 {
    // --- Events ---
    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event ActivePoolGMDebtUpdated(uint _GMDebt);
    event ActivePoolETHBalanceUpdated(uint _ETH);

    // --- Functions ---
    function sendETH(address _account, uint _amount) external;
    function sendWETH(address _account, uint _amount) external;
    function collTokenAddress() external view returns (address);
}
