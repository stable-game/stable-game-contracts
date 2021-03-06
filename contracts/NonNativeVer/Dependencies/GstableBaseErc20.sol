// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../../Dependencies/BaseMath.sol";
import "../../Dependencies/GstableMath.sol";
import "../../Dependencies/IERC20.sol";
import "../Interfaces/IActivePoolErc20.sol";
import "../Interfaces/IDefaultPoolErc20.sol";
import "../../Interfaces/IPriceFeed.sol";
import "../../Interfaces/IGstableBase.sol";

contract GstableBaseErc20 is BaseMath, IGstableBase {
    using SafeMath for uint;

    uint constant public _100pct = 1000000000000000000; // 1e18 == 100%

    // Minimum collateral ratio for individual troves
    uint constant public MCR = 1100000000000000000; // 110%

    // Critical system collateral ratio. If the system's total collateral ratio (TCR) falls below the CCR, Recovery Mode is triggered.
    uint constant public CCR = 1500000000000000000; // 150%

    // Amount of GM to be locked in gas pool on opening troves
    uint constant public GM_GAS_COMPENSATION = 200e18;

    // Minimum amount of net GM debt a trove must have
    uint constant public MIN_NET_DEBT = 1800e18;
    // uint constant public MIN_NET_DEBT = 0;

    uint constant public PERCENT_DIVISOR = 200; // dividing by 200 yields 0.5%

    uint constant public BORROWING_FEE_FLOOR = DECIMAL_PRECISION / 1000 * 5; // 0.5%

    IActivePoolErc20 public activePool;

    IDefaultPoolErc20 public defaultPool;

    IPriceFeed public override priceFeed;

    // --- Gas compensation functions ---

    // Returns the composite debt (drawn debt + gas compensation) of a trove, for the purpose of ICR calculation
    function _getCompositeDebt(uint _debt) internal pure returns (uint) {
        return _debt.add(GM_GAS_COMPENSATION);
    }

    function _getNetDebt(uint _debt) internal pure returns (uint) {
        return _debt.sub(GM_GAS_COMPENSATION);
    }

    // Return the amount of ETH to be drawn from a trove's collateral and sent as gas compensation.
    function _getCollGasCompensation(uint _entireColl) internal pure returns (uint) {
        return _entireColl / PERCENT_DIVISOR;
    }

    function getEntireSystemColl() public view returns (uint entireSystemColl) {
        uint activeColl = activePool.getETH();
        uint liquidatedColl = defaultPool.getETH();

        return activeColl.add(liquidatedColl);
    }

    function getEntireSystemDebt() public view returns (uint entireSystemDebt) {
        uint activeDebt = activePool.getGMDebt();
        uint closedDebt = defaultPool.getGMDebt();

        return activeDebt.add(closedDebt);
    }

    function _getTCR(uint _price) internal view returns (uint TCR) {
        uint entireSystemColl = getEntireSystemColl();
        uint entireSystemDebt = getEntireSystemDebt();
        uint256 collDecimals;
        collDecimals = IERC20(activePool.collTokenAddress()).decimals();

        TCR = GstableMath._computeCR(entireSystemColl.mul(DECIMAL_PRECISION).div(10**collDecimals), entireSystemDebt, _price);

        return TCR;
    }

    function _computeCR(uint _coll, uint _debt, uint _price) internal view returns (uint CR) {
        uint256 collDecimals = getCollDecimals();
        uint256 coll = _coll.mul(DECIMAL_PRECISION).div(10**collDecimals);
        CR = GstableMath._computeCR(coll, _debt, _price);
    }

    function _computeNominalCR(uint _coll, uint _debt) internal view returns (uint CR) {
        uint256 collDecimals = getCollDecimals();
        uint256 coll = _coll.mul(DECIMAL_PRECISION).div(10**collDecimals);
        CR = GstableMath._computeNominalCR(coll, _debt);
    }

    function getCollDecimals() internal view returns (uint256) {
        uint256 collDecimals;

        collDecimals = IERC20(activePool.collTokenAddress()).decimals();

        return collDecimals;
    }

     function collToDebt(uint _coll, uint _price) public view returns (uint256 debt) {
        uint256 collDecimals = getCollDecimals();
        debt = _coll.mul(_price).div(10**collDecimals);
    }

    function debtToColl(uint _debt, uint _price) public view returns (uint256 coll) {
        uint256 collDecimals = getCollDecimals();
        coll = _debt.mul(10**collDecimals).div(_price);
    }


    function _checkRecoveryMode(uint _price) internal view returns (bool) {
        uint TCR = _getTCR(_price);

        return TCR < CCR;
    }

    function _requireUserAcceptsFee(uint _fee, uint _amount, uint _maxFeePercentage) internal pure {
        uint feePercentage = _fee.mul(DECIMAL_PRECISION).div(_amount);
        require(feePercentage <= _maxFeePercentage, "Fee exceeded provided maximum");
    }
}
