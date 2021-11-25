// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface IPriceFeed {

    // --- Events ---
    event LastGoodPriceUpdated(uint _lastGoodPrice);
   
    // --- Function ---
    function setAddresses(address _firstPriceAggregatorAddress, address _secondPriceAggregatorAddress) external;
    function fetchPrice() external returns (uint);
}
