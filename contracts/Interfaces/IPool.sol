// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface IPool {
    
    // --- Events ---
    
    event ETHBalanceUpdated(uint _newBalance);
    event GMBalanceUpdated(uint _newBalance);
    event ActivePoolAddressChanged(address _newActivePoolAddress);
    event DefaultPoolAddressChanged(address _newDefaultPoolAddress);
    event StabilityPoolAddressChanged(address _newStabilityPoolAddress);
    event EtherSent(address _to, uint _amount);

    // --- Functions ---
    
    function getETH() external view returns (uint);

    function getGMDebt() external view returns (uint);

    function increaseGMDebt(uint _amount) external;

    function decreaseGMDebt(uint _amount) external;
}
