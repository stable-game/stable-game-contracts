// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import './Interfaces/IDefaultPoolErc20.sol';
import './Interfaces/IActivePoolErc20.sol';
import "../Dependencies/SafeMath.sol";
import "../Dependencies/Ownable.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/console.sol";
import "../Dependencies/IERC20.sol";

contract DefaultPoolErc20 is Ownable, CheckContract, IDefaultPoolErc20 {
    using SafeMath for uint256;

    string constant public NAME = "DefaultPoolErc20";

    address public troveManagerAddress;
    address public activePoolAddress;

    address public collToken;
    uint256 internal collAmount;  // deposited ETH tracker
    uint256 internal GMDebt;  // debt

    event CollTokenAddressChanged(address _collToken);
    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event DefaultPoolGMDebtUpdated(uint _GMDebt);
    event DefaultPoolETHBalanceUpdated(uint _ETH);

    // --- Dependency setters ---

    function setAddresses(
        address _collToken,
        address _troveManagerAddress,
        address _activePoolAddress
    )
        external
        onlyOwner
    {
        checkContract(_collToken);
        checkContract(_troveManagerAddress);
        checkContract(_activePoolAddress);

        collToken = _collToken;
        troveManagerAddress = _troveManagerAddress;
        activePoolAddress = _activePoolAddress;

        emit CollTokenAddressChanged(_collToken);
        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);

        _renounceOwnership();
    }

    // --- Getters for public variables. Required by IPool interface ---

    /*
    * Returns the ETH state variable.
    *
    * Not necessarily equal to the the contract's raw ETH balance - ether can be forcibly sent to contracts.
    */
    function getETH() external view override returns (uint) {
        return collAmount;
    }

    function getGMDebt() external view override returns (uint) {
        return GMDebt;
    }

    // --- Pool functionality ---

    function sendETHToActivePool(uint _amount) external override {
        _requireCallerIsTroveManager();
        address activePool = activePoolAddress; // cache to save an SLOAD
        collAmount = collAmount.sub(_amount);
        emit DefaultPoolETHBalanceUpdated(collAmount);
        emit EtherSent(activePool, _amount);

        IERC20(collToken).transfer(activePool, _amount);
        IActivePoolErc20(activePool).increaseColl(_amount);
    }

    function increaseGMDebt(uint _amount) external override {
        _requireCallerIsTroveManager();
        GMDebt = GMDebt.add(_amount);
        emit DefaultPoolGMDebtUpdated(GMDebt);
    }

    function decreaseGMDebt(uint _amount) external override {
        _requireCallerIsTroveManager();
        GMDebt = GMDebt.sub(_amount);
        emit DefaultPoolGMDebtUpdated(GMDebt);
    }

     function increaseColl(uint256 _amount) external override {
        _requireCallerIsActivePool();
        collAmount = collAmount.add(_amount);
        emit DefaultPoolETHBalanceUpdated(collAmount);
    }

    // --- 'require' functions ---

    function _requireCallerIsActivePool() internal view {
        require(msg.sender == activePoolAddress, "DefaultPool: Caller is not the ActivePool");
    }

    function _requireCallerIsTroveManager() internal view {
        require(msg.sender == troveManagerAddress, "DefaultPool: Caller is not the TroveManager");
    }
}