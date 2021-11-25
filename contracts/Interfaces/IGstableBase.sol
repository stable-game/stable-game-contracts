// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./IPriceFeed.sol";


interface IGstableBase {
    function priceFeed() external view returns (IPriceFeed);
}
