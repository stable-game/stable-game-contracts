// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import './Interfaces/IActivePoolErc20.sol';
import './Interfaces/IDefaultPoolErc20.sol';
import './Interfaces/ICollSurplusPoolErc20.sol';
import './Interfaces/IStabilityPoolErc20.sol';
import '../Interfaces/IStrategy.sol';
import "../Dependencies/SafeMath.sol";
import "../Dependencies/Ownable.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/console.sol";
import "../Dependencies/IERC20.sol";

contract ActivePoolErc20 is Ownable, CheckContract, IActivePoolErc20 {
    using SafeMath for uint256;

    string constant public NAME = "ActivePoolErc20";

    address public borrowerOperationsAddress;
    address public troveManagerAddress;
    address public stabilityPoolAddress;
    address public defaultPoolAddress;
    address public collSurplusPoolAddress;

    address public collToken;
    uint256 internal collAmount;  // deposited collateral tracker
    uint256 internal GMDebt;
    uint256 public debtCeiling;

    bool public initialized;
    IStrategy[] _strategies;
    bool public pauseEarning = true;
    address public rewardCollector;

    // --- Events ---

    event Initialized();
    event PauseEarningUpdated(bool _status);
    event StrategyDeposited(address _strategy, uint _amount);
    event StrategyRecalled(address _strategy, uint _withdrawnAmount, uint _decreasedValue);
    event StrategyHarvested(address _strategy, uint _harvestedAmount, uint _decreasedValue);
    event ActiveStrategyUpdated(address _strategy);
    event RewardCollectorAddressUpdated(address _rewardCollector);

    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event ActivePoolDebtCeilingUpdated(uint _debtCeiling);
    event ActivePoolGMDebtUpdated(uint _GMDebt);
    event ActivePoolETHBalanceUpdated(uint _ETH);

    event CollSurplusPoolAddressChanged(address _newCollSurplusPoolAddress);
    event CollTokenAddressChanged(address _collToken);

    // --- Contract setters ---

    function setAddresses(
        address _collToken,
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _stabilityPoolAddress,
        address _defaultPoolAddress,
        address _collSurplusPoolAddress
    )
        external
        onlyOwner
    {
        require(!initialized, "ActivePool: already initialized");

        checkContract(_collToken);
        checkContract(_borrowerOperationsAddress);
        checkContract(_troveManagerAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_defaultPoolAddress);
        checkContract(_collSurplusPoolAddress);

        collToken = _collToken;
        borrowerOperationsAddress = _borrowerOperationsAddress;
        troveManagerAddress = _troveManagerAddress;
        stabilityPoolAddress = _stabilityPoolAddress;
        defaultPoolAddress = _defaultPoolAddress;
        collSurplusPoolAddress = _collSurplusPoolAddress;
        initialized = true;

        emit CollTokenAddressChanged(_collToken);
        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
        emit DefaultPoolAddressChanged(_defaultPoolAddress);
        emit CollSurplusPoolAddressChanged(_collSurplusPoolAddress);
        emit Initialized();
    }

    function setPauseEarning(bool _pauseEarning) public onlyOwner {
        pauseEarning = _pauseEarning;
        emit PauseEarningUpdated(_pauseEarning);
    }

    function setRewardCollector(address _rewardCollector) external onlyOwner {
        require(_rewardCollector != address(0), "ActivePool: rewardCollector cannot be zero address");
        rewardCollector = _rewardCollector;
        emit RewardCollectorAddressUpdated(_rewardCollector);
    }

    function setDebtCeiling(uint256 _debtCeiling) external onlyOwner {
        debtCeiling = _debtCeiling;
        emit ActivePoolDebtCeilingUpdated(_debtCeiling);
    }

    // --- Getters for public variables. Required by IPool interface ---

    function collTokenAddress() external view override returns (address) {
        return collToken;
    }
    /*
    * Returns the ETH state variable.
    *
    *Not necessarily equal to the the contract's raw ETH balance - ether can be forcibly sent to contracts.
    */
    function getETH() external view override returns (uint) {
        return collAmount;
    }

    function getGMDebt() external view override returns (uint) {
        return GMDebt;
    }

    // --- Pool functionality ---

    function sendETH(address _account, uint _amount) public override {
        _requireInitialized();
        _requireCallerIsBOorTroveMorSP();
        _ensureSufficientFundsExistLocally(_amount);

        collAmount = collAmount.sub(_amount);
        emit ActivePoolETHBalanceUpdated(collAmount);
        emit EtherSent(_account, _amount);

        IERC20(collToken).transfer(_account, _amount);
        if(_account == defaultPoolAddress ) {
            IDefaultPoolErc20(defaultPoolAddress).increaseColl(_amount);
        } else if (_account == collSurplusPoolAddress) {
            ICollSurplusPoolErc20(collSurplusPoolAddress).increaseColl(_amount);
        } else if (_account == stabilityPoolAddress) {
            IStabilityPoolErc20(stabilityPoolAddress).increaseColl(_amount);
        }
    }

    function sendWETH(address _account, uint _amount) external override {
        sendETH(_account, _amount);
    }

    function _ensureSufficientFundsExistLocally(uint256 _amt) internal {
        uint256 currentBal = IERC20(collToken).balanceOf(address(this));
        if (currentBal < _amt) {
            uint256 diff = _amt - currentBal;
            _recallExcessFundsFromActiveStrategy(diff);
        }
    }

    function _recallExcessFundsFromActiveStrategy(uint256 _recallAmt) internal {
        _requireHasActiveStrategy();

        uint strategiesLength = _strategies.length;
        IStrategy _activeStrategy = _strategies[strategiesLength.sub(1)];
        uint256 activeStrategyVal = _activeStrategy.totalDeposited();
        if (activeStrategyVal < _recallAmt) {
            _recallAmt = activeStrategyVal;
        }
        if (_recallAmt > 0) {
            (uint256 _withdrawnAmount, uint256 _decreasedValue) = _activeStrategy.withdraw(address(this), _recallAmt);
            emit StrategyRecalled(address(_activeStrategy), _withdrawnAmount, _decreasedValue);
        }
    }

    function increaseGMDebt(uint _amount) external override {
        _requireInitialized();
        _requireCallerIsBOorTroveM();
        GMDebt  = GMDebt.add(_amount);
        require(GMDebt <= debtCeiling,"ActivePool: GM's debt ceiling was breached.");
        emit ActivePoolGMDebtUpdated(GMDebt);
    }

    function decreaseGMDebt(uint _amount) external override {
        _requireInitialized();
        _requireCallerIsBOorTroveMorSP();
        GMDebt = GMDebt.sub(_amount);
        emit ActivePoolGMDebtUpdated(GMDebt);
    }

    function increaseColl(uint256 _amount) external override {
        _requireInitialized();
        _requireCallerIsBorrowerOperationsOrDefaultPool();
        collAmount = collAmount.add(_amount);
        emit ActivePoolETHBalanceUpdated(collAmount);
    }

    function flush(uint _amount) external onlyOwner {
        _requireInitialized();
        require(!pauseEarning, "ActivePool: Earning strategy paused");
        _requireHasActiveStrategy();

        uint strategiesLength = _strategies.length;
        IStrategy _activeStrategy = _strategies[strategiesLength.sub(1)];
        IERC20(collToken).transfer(address(_activeStrategy), _amount);
        _activeStrategy.deposit(msg.sender, _amount);
        emit StrategyDeposited(address(_activeStrategy), _amount);
    }

    function recallAll(uint strategyId) public onlyOwner {
        _requireInitialized();
        require(pauseEarning, "ActivePool: Earning strategy not paused");

        IStrategy _activeStrategy = _strategies[strategyId];
        (uint256 _withdrawnAmount, uint256 _decreasedValue) = _activeStrategy.withdrawAll(address(this));
        emit StrategyRecalled(address(_activeStrategy), _withdrawnAmount, _decreasedValue);
    }

    function harvest(uint strategyId) public onlyOwner {
        _requireInitialized();

        IStrategy _activeStrategy = _strategies[strategyId];
        _activeStrategy.harvest(rewardCollector);
    }

    function migrate(IStrategy _strategy) external onlyOwner {
        _requireInitialized();
        _requireHasActiveStrategy();
        require(pauseEarning, "ActivePool: Earning strategy not paused");

        uint activeStrategyId = _strategies.length.sub(1);
        harvest(activeStrategyId);
        recallAll(activeStrategyId);
        updateActiveStrategy(_strategy);
        setPauseEarning(false);
    }

    function updateActiveStrategy(IStrategy _strategy) public onlyOwner {
        require(_strategy != IStrategy(address(0)), "ActivePool: new strategy address cannot be 0x0.");
        require(_strategy.token() == collToken, "ActivePool: token mismatch.");

        _strategies.push(_strategy);

        emit ActiveStrategyUpdated(address(_strategy));
    }

    function strategyCount() external view returns (uint256) {
        return _strategies.length;
    }

    function getStrategy(uint256 _strategyId) external view returns (IStrategy) {
        IStrategy _strategy = _strategies[_strategyId];
        return _strategy;
    }

    // --- 'require' functions ---

    function _requireInitialized() internal view {
        require(initialized, "ActivePool: not initialized.");
    }

    function _requireHasActiveStrategy() internal view {
        bool hasActiveStrategy = _strategies.length > 0;
        require(hasActiveStrategy, "ActivePool: No active strategy");
    }

    function _requireCallerIsBorrowerOperationsOrDefaultPool() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == defaultPoolAddress,
            "ActivePool: Caller is neither BO nor Default Pool");
    }

    function _requireCallerIsBOorTroveMorSP() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == troveManagerAddress ||
            msg.sender == stabilityPoolAddress,
            "ActivePool: Caller is neither BorrowerOperations nor TroveManager nor StabilityPool");
    }

    function _requireCallerIsBOorTroveM() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == troveManagerAddress,
            "ActivePool: Caller is neither BorrowerOperations nor TroveManager");
    }
}
