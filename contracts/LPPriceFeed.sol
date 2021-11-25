// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/IPriceFeed.sol";
import "./Interfaces/IUniswapV2Pair.sol";
import "./Dependencies/AggregatorV3Interface.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/BaseMath.sol";
import "./Dependencies/GstableMath.sol";
import "./Dependencies/console.sol";

contract LPPriceFeed is Ownable, CheckContract, BaseMath, IPriceFeed {
    using SafeMath for uint256;

    string constant public NAME = "LPPriceFeed";

    mapping(address => address) public tokenPriceFeeds;

    address public pair;

    // Maximum deviation allowed between two consecutive LP prices. 18-digit precision.
    uint256 public maxPriceDeviation = 5e17;

    // The last good price seen from an oracle by Gstable
    uint256 public lastGoodPrice;

    enum Status {
        PriceFetchWorking,
        PriceFetchUntrusted
    }

    // The current status of the LPPriceFeed
    Status public status;

    event MaxPriceDeviationUpdated(uint256 _maxPriceDeviation);
    event LastGoodPriceUpdated(uint256 _lastGoodPrice);
    event PriceFeedStatusChanged(Status _newStatus);

    function setAddresses(address _pair, address /* _notUsedAddress */) external override onlyOwner {
        setAddresses(_pair);
    }

    function setAddresses(address _pair) public onlyOwner {
        require(pair == address(0), "LPPriceFeed: pair address has already been set");
        checkContract(_pair);
        pair = _pair;
    }

    function setPairTokenPriceFeeds(address[] calldata _tokens, address[] calldata _priceFeeds) external onlyOwner {
        require(_tokens.length == 2, "LPPriceFeed: Wrong number of pair tokens");
        require(_priceFeeds.length == 2, "LPPriceFeed: Wrong number of pair priceFeeds");

        for (uint256 i; i < 2; i++) {
            address token = _tokens[i];
            checkContract(token);
            address priceFeed = _priceFeeds[i];
            checkContract(priceFeed);

            tokenPriceFeeds[token] = priceFeed;
            uint256 price = IPriceFeed(priceFeed).fetchPrice();
            require(price > 0, "LPPriceFeed: token price feed not working");
        }

        fetchPrice();
        require(lastGoodPrice > 0, "LPPriceFeed: LP price fetch not working");
    }

    function setMaxPriceDeviation(uint256 _maxPriceDeviation) external onlyOwner {
        maxPriceDeviation = _maxPriceDeviation;
        emit MaxPriceDeviationUpdated(_maxPriceDeviation);
    }

    function fetchPrice() public override returns (uint256) {
        require(pair != address(0), "LPPriceFeed: pair address not set");
        
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        uint256 totalSupply = IUniswapV2Pair(pair).totalSupply();
        (uint256 r0, uint256 r1, ) = IUniswapV2Pair(pair).getReserves();
        uint256 sqrtK = GstableMath._fdiv(GstableMath._sqrt(r0.mul(r1)), totalSupply); // in 2**112
        uint256 px0 = IPriceFeed(tokenPriceFeeds[token0]).fetchPrice(); // in 2**112
        uint256 px1 = IPriceFeed(tokenPriceFeeds[token1]).fetchPrice(); // in 2**112
        // fair token0 amt: sqrtK * sqrt(px1/px0)
        // fair token1 amt: sqrtK * sqrt(px0/px1)
        // fair lp price = 2 * sqrt(px0 * px1)
        // split into 2 sqrts multiplication to prevent uint overflow (note the 2**112)
        uint256 lpPrice = sqrtK.mul(2).mul(GstableMath._sqrt(px0)).div(2**56).mul(GstableMath._sqrt(px1)).div(2**56);

        if (_priceChangeAboveMax(lpPrice)) {
            _changeStatus(Status.PriceFetchUntrusted);
            return lastGoodPrice;
        }

        _changeStatus(Status.PriceFetchWorking);
        return _storePrice(lpPrice);
    }

    function _changeStatus(Status _status) internal {
        status = _status;
        emit PriceFeedStatusChanged(_status);
    }

    function _priceChangeAboveMax(uint256 currentPrice) internal view returns (bool) {
        if (lastGoodPrice == 0) {
            return false;
        }
        uint256 previousPrice = lastGoodPrice;
        uint256 minPrice = GstableMath._min(currentPrice, previousPrice);
        uint256 maxPrice = GstableMath._max(currentPrice, previousPrice);
        uint256 percentDeviation = maxPrice.sub(minPrice).mul(DECIMAL_PRECISION).div(maxPrice);
        return percentDeviation > maxPriceDeviation;
    }

    function _storePrice(uint256 _currentPrice) internal returns (uint256) {
        lastGoodPrice = _currentPrice;
        emit LastGoodPriceUpdated(_currentPrice);
        return _currentPrice;
    }
}
