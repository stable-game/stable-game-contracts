// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface ICommunityIssuance { 
    
    // --- Events ---
    
    event PILLTokenAddressSet(address _pillTokenAddress);
    event StabilityPoolAddressSet(address _stabilityPoolAddress);
    event TotalPILLIssuedUpdated(uint _totalPILLIssued);

    // --- Functions ---

    function setAddresses(address _pillTokenAddress, address _stabilityPoolAddress) external;

    function issuePILL() external returns (uint);

    function sendPILL(address _account, uint _PILLamount) external;
}
