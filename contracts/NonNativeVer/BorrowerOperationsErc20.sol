// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/IBorrowerOperationsErc20.sol";
import "../Interfaces/ITroveManager.sol";
import "../Interfaces/IGMToken.sol";
import "./Interfaces/ICollSurplusPoolErc20.sol";
import "../Interfaces/ISortedTroves.sol";
import "./Dependencies/GstableBaseErc20.sol";
import "../Dependencies/Ownable.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/console.sol";

contract BorrowerOperationsErc20 is GstableBaseErc20, Ownable, CheckContract, IBorrowerOperationsErc20 {
  string constant public NAME = "BorrowerOperationsErc20";

  // --- Connected contract declarations ---
  address stabilityPoolAddress;
  address gasPoolAddress;

  ITroveManager public troveManager;
  ISortedTroves public sortedTroves;
  ICollSurplusPoolErc20 public collSurplusPool;
  IGMToken public gmToken;

  address public collTokenAddress;
  address public borrowingFeeCollectorAddress;

  /*
      --- Variable container structs  ---
      Used to hold, return and assign variables inside a function, in order to avoid the error:
      "CompilerError: Stack too deep".
  */

  struct LocalVariables_adjustTrove {
      uint price;
      uint collChange;
      uint netDebtChange;
      bool isCollIncrease;
      uint debt;
      uint coll;
      uint oldICR;
      uint newICR;
      uint newTCR;
      uint GMFee;
      uint newDebt;
      uint newColl;
      uint stake;
  }

  struct LocalVariables_openTrove {
      uint price;
      uint GMFee;
      uint netDebt;
      uint compositeDebt;
      uint ICR;
      uint NICR;
      uint stake;
      uint arrayIndex;
  }

  struct ContractsCache {
      ITroveManager troveManager;
      IActivePoolErc20 activePool;
      IGMToken gmToken;
  }

  enum BorrowerOperation {
      openTrove,
      closeTrove,
      adjustTrove
  }

  event TroveManagerAddressChanged(address _newTroveManagerAddress);
  event ActivePoolAddressChanged(address _activePoolAddress);
  event DefaultPoolAddressChanged(address _defaultPoolAddress);
  event StabilityPoolAddressChanged(address _stabilityPoolAddress);
  event GasPoolAddressChanged(address _gasPoolAddress);
  event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
  event PriceFeedAddressChanged(address  _newPriceFeedAddress);
  event SortedTrovesAddressChanged(address _sortedTrovesAddress);
  event GMTokenAddressChanged(address _gmTokenAddress);
  event BorrowingFeeCollectorAddressChanged(address _borrowingFeeCollectorAddress);

  event TroveCreated(address indexed _borrower, uint arrayIndex);
  event TroveUpdated(address indexed _borrower, uint _debt, uint _coll, uint stake, BorrowerOperation operation);
  event GMBorrowingFeePaid(address indexed _borrower, uint _GMFee);

  // --- Dependency setters ---

  function setAddresses(
      address _collTokenAddress,
      address _troveManagerAddress,
      address _activePoolAddress,
      address _defaultPoolAddress,
      address _stabilityPoolAddress,
      address _gasPoolAddress,
      address _collSurplusPoolAddress,
      address _priceFeedAddress,
      address _sortedTrovesAddress,
      address _gmTokenAddress,
      address _borrowingFeeCollectorAddress
  )
      external
      override
      onlyOwner
  {
      // This makes impossible to open a trove with zero withdrawn GM
      assert(MIN_NET_DEBT > 0);

      require(_collTokenAddress != address(0), "BorrowerOperations: collToken address cannot be zero address");
      require(_borrowingFeeCollectorAddress != address(0), "BorrowerOperations: borrowingFeeCollector address cannot be zero address");

      collTokenAddress = _collTokenAddress;
      borrowingFeeCollectorAddress = _borrowingFeeCollectorAddress;
      troveManager = ITroveManager(_troveManagerAddress);
      activePool = IActivePoolErc20(_activePoolAddress);
      defaultPool = IDefaultPoolErc20(_defaultPoolAddress);
      stabilityPoolAddress = _stabilityPoolAddress;
      gasPoolAddress = _gasPoolAddress;
      collSurplusPool = ICollSurplusPoolErc20(_collSurplusPoolAddress);
      priceFeed = IPriceFeed(_priceFeedAddress);
      sortedTroves = ISortedTroves(_sortedTrovesAddress);
      gmToken = IGMToken(_gmTokenAddress);

      emit TroveManagerAddressChanged(_troveManagerAddress);
      emit ActivePoolAddressChanged(_activePoolAddress);
      emit DefaultPoolAddressChanged(_defaultPoolAddress);
      emit StabilityPoolAddressChanged(_stabilityPoolAddress);
      emit GasPoolAddressChanged(_gasPoolAddress);
      emit CollSurplusPoolAddressChanged(_collSurplusPoolAddress);
      emit PriceFeedAddressChanged(_priceFeedAddress);
      emit SortedTrovesAddressChanged(_sortedTrovesAddress);
      emit GMTokenAddressChanged(_gmTokenAddress);
      emit BorrowingFeeCollectorAddressChanged(_borrowingFeeCollectorAddress);

      _renounceOwnership();
  }

  // --- Borrower Trove Operations ---

  function openTrove(
      uint _collAmount,
      uint _maxFeePercentage,
      uint _GMAmount,
      address _upperHint,
      address _lowerHint
  ) external override {

      ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, gmToken);
      LocalVariables_openTrove memory vars;

      vars.price = priceFeed.fetchPrice();
      bool isRecoveryMode = _checkRecoveryMode(vars.price);

      _requireValidMaxFeePercentage(_maxFeePercentage, isRecoveryMode);
      _requireTroveisNotActive(contractsCache.troveManager, msg.sender);

      vars.GMFee;
      vars.netDebt = _GMAmount;

      if (!isRecoveryMode) {
          vars.GMFee = _triggerBorrowingFee(contractsCache.troveManager, contractsCache.gmToken, _GMAmount, _maxFeePercentage);
          vars.netDebt = vars.netDebt.add(vars.GMFee);
      }
      _requireAtLeastMinNetDebt(vars.netDebt);

      // ICR is based on the composite debt, i.e. the requested GM amount + GM borrowing fee + GM gas comp.
      vars.compositeDebt = _getCompositeDebt(vars.netDebt);
      assert(vars.compositeDebt > 0);

      vars.ICR = _computeCR(_collAmount, vars.compositeDebt, vars.price);
      vars.NICR = _computeNominalCR(_collAmount, vars.compositeDebt);

      if (isRecoveryMode) {
          _requireICRisAboveCCR(vars.ICR);
      } else {
          _requireICRisAboveMCR(vars.ICR);
          uint newTCR = _getNewTCRFromTroveChange(
              _collAmount,
              true, vars.compositeDebt,
              true,
              vars.price
          );  // bools: coll increase, debt increase
          _requireNewTCRisAboveCCR(newTCR);
      }

      // Set the trove struct's properties
      contractsCache.troveManager.setTroveStatus(msg.sender, 1);
      contractsCache.troveManager.increaseTroveColl(msg.sender, _collAmount);
      contractsCache.troveManager.increaseTroveDebt(msg.sender, vars.compositeDebt);

      contractsCache.troveManager.updateTroveRewardSnapshots(msg.sender);
      vars.stake = contractsCache.troveManager.updateStakeAndTotalStakes(msg.sender);

      sortedTroves.insert(msg.sender, vars.NICR, _upperHint, _lowerHint);
      vars.arrayIndex = contractsCache.troveManager.addTroveOwnerToArray(msg.sender);
      emit TroveCreated(msg.sender, vars.arrayIndex);

      // Move the ether to the Active Pool, and mint the GMAmount to the borrower
      _activePoolAddColl(contractsCache.activePool, _collAmount);
      _withdrawGM(contractsCache.activePool, contractsCache.gmToken, msg.sender, _GMAmount, vars.netDebt);
      // Move the GM gas compensation to the Gas Pool
      _withdrawGM(contractsCache.activePool, contractsCache.gmToken, gasPoolAddress, GM_GAS_COMPENSATION, GM_GAS_COMPENSATION);

      emit TroveUpdated(
          msg.sender,
          vars.compositeDebt,
          _collAmount,
          vars.stake,
          BorrowerOperation.openTrove
      );
      emit GMBorrowingFeePaid(msg.sender, vars.GMFee);
  }

  // Send ETH as collateral to a trove
  function addColl(uint _collAmount, address _upperHint, address _lowerHint) external override {
      _adjustTrove(_collAmount, msg.sender, 0, 0, false, _upperHint, _lowerHint, 0);
  }

  // Send ETH as collateral to a trove. Called by only the Stability Pool.
  function moveETHGainToTrove(uint _collAmount, address _borrower, address _upperHint, address _lowerHint) external override {
      _requireCallerIsStabilityPool();
      _adjustTrove(_collAmount, _borrower, 0, 0, false, _upperHint, _lowerHint, 0);
  }

  // Withdraw ETH collateral from a trove
  function withdrawColl(uint _collWithdrawal, address _upperHint, address _lowerHint) external override {
      _adjustTrove(0, msg.sender, _collWithdrawal, 0, false, _upperHint, _lowerHint, 0);
  }

  // Withdraw GM tokens from a trove: mint new GM tokens to the owner, and increase the trove's debt accordingly
  function withdrawGM(uint _maxFeePercentage, uint _GMAmount, address _upperHint, address _lowerHint) external override {
      _adjustTrove(0, msg.sender, 0, _GMAmount, true, _upperHint, _lowerHint, _maxFeePercentage);
  }

  // Repay GM tokens to a Trove: Burn the repaid GM tokens, and reduce the trove's debt accordingly
  function repayGM(uint _GMAmount, address _upperHint, address _lowerHint) external override {
      _adjustTrove(0, msg.sender, 0, _GMAmount, false, _upperHint, _lowerHint, 0);
  }

  function adjustTrove(uint _collAmount, uint _maxFeePercentage, uint _collWithdrawal, uint _GMChange, bool _isDebtIncrease, address _upperHint, address _lowerHint) external override {
      _adjustTrove(_collAmount, msg.sender, _collWithdrawal, _GMChange, _isDebtIncrease, _upperHint, _lowerHint, _maxFeePercentage);
  }

  /*
  * _adjustTrove(): Alongside a debt change, this function can perform either a collateral top-up or a collateral withdrawal.
  *
  * It therefore expects either a positive msg.value, or a positive _collWithdrawal argument.
  *
  * If both are positive, it will revert.
  */
  function _adjustTrove(uint _collAmount, address _borrower, uint _collWithdrawal, uint _GMChange, bool _isDebtIncrease, address _upperHint, address _lowerHint, uint _maxFeePercentage) internal {
      ContractsCache memory contractsCache = ContractsCache(troveManager, activePool, gmToken);
      LocalVariables_adjustTrove memory vars;

      vars.price = priceFeed.fetchPrice();
      bool isRecoveryMode = _checkRecoveryMode(vars.price);

      require(address(contractsCache.troveManager) != address(0), "troveManager not exist");

      if (_isDebtIncrease) {
          _requireValidMaxFeePercentage(_maxFeePercentage, isRecoveryMode);
          _requireNonZeroDebtChange(_GMChange);
      }
      _requireSingularCollChange(_collAmount, _collWithdrawal);
      _requireNonZeroAdjustment(_collAmount, _collWithdrawal, _GMChange);
      _requireTroveisActive(contractsCache.troveManager, _borrower);

      // Confirm the operation is either a borrower adjusting their own trove, or a pure ETH transfer from the Stability Pool to a trove
      assert(msg.sender == _borrower || (msg.sender == stabilityPoolAddress && _collAmount > 0 && _GMChange == 0));

      contractsCache.troveManager.applyPendingRewards(_borrower);

      // Get the collChange based on whether or not ETH was sent in the transaction
      (vars.collChange, vars.isCollIncrease) = _getCollChange(_collAmount, _collWithdrawal);

      vars.netDebtChange = _GMChange;

      // If the adjustment incorporates a debt increase and system is in Normal Mode, then trigger a borrowing fee
      if (_isDebtIncrease && !isRecoveryMode) {
          vars.GMFee = _triggerBorrowingFee(contractsCache.troveManager, contractsCache.gmToken, _GMChange, _maxFeePercentage);
          vars.netDebtChange = vars.netDebtChange.add(vars.GMFee); // The raw debt change includes the fee
      }

      vars.debt = contractsCache.troveManager.getTroveDebt(_borrower);
      vars.coll = contractsCache.troveManager.getTroveColl(_borrower);

      // Get the trove's old ICR before the adjustment, and what its new ICR will be after the adjustment
      vars.oldICR = _computeCR(vars.coll, vars.debt, vars.price);
      vars.newICR = _getNewICRFromTroveChange(vars.coll, vars.debt, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease, vars.price);
      assert(_collWithdrawal <= vars.coll);

      // Check the adjustment satisfies all conditions for the current system mode
      _requireValidAdjustmentInCurrentMode(isRecoveryMode, _collWithdrawal, _isDebtIncrease, vars);

      // When the adjustment is a debt repayment, check it's a valid amount and that the caller has enough GM
      if (!_isDebtIncrease && _GMChange > 0) {
          _requireAtLeastMinNetDebt(_getNetDebt(vars.debt).sub(vars.netDebtChange));
          _requireValidGMRepayment(vars.debt, vars.netDebtChange);
          _requireSufficientGMBalance(contractsCache.gmToken, _borrower, vars.netDebtChange);
      }

      (vars.newColl, vars.newDebt) = _updateTroveFromAdjustment(contractsCache.troveManager, _borrower, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease);
      vars.stake = contractsCache.troveManager.updateStakeAndTotalStakes(_borrower);

      // Re-insert trove in to the sorted list
      uint newNICR = _getNewNominalICRFromTroveChange(vars.coll, vars.debt, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease);
      sortedTroves.reInsert(_borrower, newNICR, _upperHint, _lowerHint);

      emit TroveUpdated(_borrower, vars.newDebt, vars.newColl, vars.stake, BorrowerOperation.adjustTrove);
      emit GMBorrowingFeePaid(msg.sender,  vars.GMFee);

      // Use the unmodified _GMChange here, as we don't send the fee to the user
      _moveTokensAndETHfromAdjustment(
          contractsCache.activePool,
          contractsCache.gmToken,
          msg.sender,
          vars.collChange,
          vars.isCollIncrease,
          _GMChange,
          _isDebtIncrease,
          vars.netDebtChange
      );
  }

  function closeTrove() external override {
      ITroveManager troveManagerCached = troveManager;
      IActivePoolErc20 activePoolCached = activePool;
      IGMToken gmTokenCached = gmToken;

      _requireTroveisActive(troveManagerCached, msg.sender);
      uint price = priceFeed.fetchPrice();
      _requireNotInRecoveryMode(price);

      troveManagerCached.applyPendingRewards(msg.sender);

      uint coll = troveManagerCached.getTroveColl(msg.sender);
      uint debt = troveManagerCached.getTroveDebt(msg.sender);

      _requireSufficientGMBalance(gmTokenCached, msg.sender, debt.sub(GM_GAS_COMPENSATION));

      uint newTCR = _getNewTCRFromTroveChange(coll, false, debt, false, price);
      _requireNewTCRisAboveCCR(newTCR);

      troveManagerCached.removeStake(msg.sender);
      troveManagerCached.closeTrove(msg.sender);

      emit TroveUpdated(msg.sender, 0, 0, 0, BorrowerOperation.closeTrove);

      // Burn the repaid GM from the user's balance and the gas compensation from the Gas Pool
      _repayGM(activePoolCached, gmTokenCached, msg.sender, debt.sub(GM_GAS_COMPENSATION));
      _repayGM(activePoolCached, gmTokenCached, gasPoolAddress, GM_GAS_COMPENSATION);

      // Send the collateral back to the user
      activePoolCached.sendETH(msg.sender, coll);
  }

  /**
   * Claim remaining collateral from a redemption or from a liquidation with ICR > MCR in Recovery Mode
   */
  function claimCollateral() external override {
      // send Token from CollSurplus Pool to owner
      collSurplusPool.claimColl(msg.sender);
  }

  // --- Helper functions ---

  function _triggerBorrowingFee(ITroveManager _troveManager, IGMToken _gmToken, uint _GMAmount, uint _maxFeePercentage) internal returns (uint) {
      _troveManager.decayBaseRateFromBorrowing(); // decay the baseRate state variable
      uint GMFee = _troveManager.getBorrowingFee(_GMAmount);

      _requireUserAcceptsFee(GMFee, _GMAmount, _maxFeePercentage);

      // Send fee to borrowerFeeCollector address
      _gmToken.mint(borrowingFeeCollectorAddress, GMFee);

      return GMFee;
  }

  function _getUSDValue(uint _coll, uint _price) internal pure returns (uint) {
      uint usdValue = _price.mul(_coll).div(DECIMAL_PRECISION);

      return usdValue;
  }

  function _getCollChange(
      uint _collReceived,
      uint _requestedCollWithdrawal
  )
      internal
      pure
      returns(uint collChange, bool isCollIncrease)
  {
      if (_collReceived != 0) {
          collChange = _collReceived;
          isCollIncrease = true;
      } else {
          collChange = _requestedCollWithdrawal;
      }
  }

  // Update trove's coll and debt based on whether they increase or decrease
  function _updateTroveFromAdjustment(
      ITroveManager _troveManager,
      address _borrower,
      uint _collChange,
      bool _isCollIncrease,
      uint _debtChange,
      bool _isDebtIncrease
  )
      internal
      returns (uint, uint)
  {
      uint newColl = (_isCollIncrease) ? _troveManager.increaseTroveColl(_borrower, _collChange)
                                      : _troveManager.decreaseTroveColl(_borrower, _collChange);
      uint newDebt = (_isDebtIncrease) ? _troveManager.increaseTroveDebt(_borrower, _debtChange)
                                      : _troveManager.decreaseTroveDebt(_borrower, _debtChange);

      return (newColl, newDebt);
  }

  function _moveTokensAndETHfromAdjustment(
      IActivePoolErc20 _activePool,
      IGMToken _gmToken,
      address _borrower,
      uint _collChange,
      bool _isCollIncrease,
      uint _GMChange,
      bool _isDebtIncrease,
      uint _netDebtChange
  )
      internal
  {
      if (_isDebtIncrease) {
          _withdrawGM(_activePool, _gmToken, _borrower, _GMChange, _netDebtChange);
      } else {
          _repayGM(_activePool, _gmToken, _borrower, _GMChange);
      }

      if (_isCollIncrease) {
          _activePoolAddColl(_activePool, _collChange);
      } else {
          _activePool.sendETH(_borrower, _collChange);
      }
  }

  // Get token from msg.sender
  function _transferTokenToActivePool(IActivePoolErc20 _activePool, uint256 _amount) internal {
    IERC20(collTokenAddress).transferFrom(msg.sender, address(_activePool), _amount);
    _activePool.increaseColl(_amount);
  }

  // Send ETH to Active Pool and increase its recorded ETH balance
  function _activePoolAddColl(IActivePoolErc20 _activePool, uint _amount) internal {
      _transferTokenToActivePool(_activePool, _amount);
  }

  // Issue the specified amount of GM to _account and increases the total active debt (_netDebtIncrease potentially includes a GMFee)
  function _withdrawGM(IActivePoolErc20 _activePool, IGMToken _gmToken, address _account, uint _GMAmount, uint _netDebtIncrease) internal {
      _activePool.increaseGMDebt(_netDebtIncrease);
      _gmToken.mint(_account, _GMAmount);
  }

  // Burn the specified amount of GM from _account and decreases the total active debt
  function _repayGM(IActivePoolErc20 _activePool, IGMToken _gmToken, address _account, uint _GM) internal {
      _activePool.decreaseGMDebt(_GM);
      _gmToken.burn(_account, _GM);
  }

  // --- 'Require' wrapper functions ---

  function _requireSingularCollChange(uint _collAmount, uint _collWithdrawal) internal pure {
      require(
          _collAmount == 0 || _collWithdrawal == 0,
          "BorrowerOperations: Cannot withdraw and add coll"
      );
  }

  function _requireCallerIsBorrower(address _borrower) internal view {
      require(msg.sender == _borrower, "BorrowerOps: Caller must be the borrower for a withdrawal");
  }

  function _requireNonZeroAdjustment(uint amount, uint _collWithdrawal, uint _GMChange) internal pure {
      require(
           amount != 0 || _collWithdrawal != 0 || _GMChange != 0,
          "BorrowerOps: There must be either a collateral change or a debt change"
      );
  }

  function _requireTroveisActive(ITroveManager _troveManager, address _borrower) internal view {
      uint status = _troveManager.getTroveStatus(_borrower);
      require(status == 1, "BorrowerOps: Trove does not exist or is closed");
  }

  function _requireTroveisNotActive(ITroveManager _troveManager, address _borrower) internal view {
      uint status = _troveManager.getTroveStatus(_borrower);
      require(status != 1, "BorrowerOps: Trove is active");
  }

  function _requireNonZeroDebtChange(uint _GMChange) internal pure {
      require(_GMChange > 0, "BorrowerOps: Debt increase requires non-zero debtChange");
  }

  function _requireNotInRecoveryMode(uint _price) internal view {
      require(!_checkRecoveryMode(_price), "BorrowerOps: Operation not permitted during Recovery Mode");
  }

  function _requireNoCollWithdrawal(uint _collWithdrawal) internal pure {
      require(_collWithdrawal == 0, "BorrowerOps: Collateral withdrawal not permitted Recovery Mode");
  }

  function _requireValidAdjustmentInCurrentMode (
      bool _isRecoveryMode,
      uint _collWithdrawal,
      bool _isDebtIncrease,
      LocalVariables_adjustTrove memory _vars
  )
      internal
      view
  {
      /*
      * In Recovery Mode, only allow:
      *
      * - Pure collateral top-up
      * - Pure debt repayment
      * - Collateral top-up with debt repayment
      * - A debt increase combined with a collateral top-up which makes the ICR >= 150% and improves the ICR (and by extension improves the TCR).
      *
      * In Normal Mode, ensure:
      *
      * - The new ICR is above MCR
      * - The adjustment won't pull the TCR below CCR
      */
      if (_isRecoveryMode) {
          _requireNoCollWithdrawal(_collWithdrawal);
          if (_isDebtIncrease) {
              _requireICRisAboveCCR(_vars.newICR);
              _requireNewICRisAboveOldICR(_vars.newICR, _vars.oldICR);
          }
      } else { // if Normal Mode
          _requireICRisAboveMCR(_vars.newICR);
          _vars.newTCR = _getNewTCRFromTroveChange(_vars.collChange, _vars.isCollIncrease, _vars.netDebtChange, _isDebtIncrease, _vars.price);
          _requireNewTCRisAboveCCR(_vars.newTCR);
      }
  }

  function _requireICRisAboveMCR(uint _newICR) internal pure {
      require(_newICR >= MCR, "BorrowerOps: An operation that would result in ICR < MCR is not permitted");
  }

  function _requireICRisAboveCCR(uint _newICR) internal pure {
      require(_newICR >= CCR, "BorrowerOps: Operation must leave trove with ICR >= CCR");
  }

  function _requireNewICRisAboveOldICR(uint _newICR, uint _oldICR) internal pure {
      require(_newICR >= _oldICR, "BorrowerOps: Cannot decrease your Trove's ICR in Recovery Mode");
  }

  function _requireNewTCRisAboveCCR(uint _newTCR) internal pure {
      require(_newTCR >= CCR, "BorrowerOps: An operation that would result in TCR < CCR is not permitted");
  }

  function _requireAtLeastMinNetDebt(uint _netDebt) internal pure {
      require (_netDebt >= MIN_NET_DEBT, "BorrowerOps: Trove's net debt must be greater than minimum");
  }

  function _requireValidGMRepayment(uint _currentDebt, uint _debtRepayment) internal pure {
      require(_debtRepayment <= _currentDebt.sub(GM_GAS_COMPENSATION), "BorrowerOps: Amount repaid must not be larger than the Trove's debt");
  }

  function _requireCallerIsStabilityPool() internal view {
      require(msg.sender == stabilityPoolAddress, "BorrowerOps: Caller is not Stability Pool");
  }

  function _requireSufficientGMBalance(IGMToken _gmToken, address _borrower, uint _debtRepayment) internal view {
      require(_gmToken.balanceOf(_borrower) >= _debtRepayment, "BorrowerOps: Caller doesnt have enough GM to make repayment");
  }

  function _requireValidMaxFeePercentage(uint _maxFeePercentage, bool _isRecoveryMode) internal pure {
      if (_isRecoveryMode) {
          require(_maxFeePercentage <= DECIMAL_PRECISION,
              "Max fee percentage must less than or equal to 100%");
      } else {
          require(_maxFeePercentage >= BORROWING_FEE_FLOOR && _maxFeePercentage <= DECIMAL_PRECISION,
              "Max fee percentage must be between 0.5% and 100%");
      }
  }

  // --- ICR and TCR getters ---

  // Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
  function _getNewNominalICRFromTroveChange
  (
      uint _coll,
      uint _debt,
      uint _collChange,
      bool _isCollIncrease,
      uint _debtChange,
      bool _isDebtIncrease
  )
      view
      internal
      returns (uint)
  {
      (uint newColl, uint newDebt) = _getNewTroveAmounts(_coll, _debt, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease);

      uint newNICR = _computeNominalCR(newColl, newDebt);
      return newNICR;
  }

  // Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
  function _getNewICRFromTroveChange
  (
      uint _coll,
      uint _debt,
      uint _collChange,
      bool _isCollIncrease,
      uint _debtChange,
      bool _isDebtIncrease,
      uint _price
  )
      view
      internal
      returns (uint)
  {
      (uint newColl, uint newDebt) = _getNewTroveAmounts(_coll, _debt, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease);

      uint newICR = _computeCR(newColl, newDebt, _price);
      return newICR;
  }

  function _getNewTroveAmounts(
      uint _coll,
      uint _debt,
      uint _collChange,
      bool _isCollIncrease,
      uint _debtChange,
      bool _isDebtIncrease
  )
      internal
      pure
      returns (uint, uint)
  {
      uint newColl = _coll;
      uint newDebt = _debt;

      newColl = _isCollIncrease ? _coll.add(_collChange) :  _coll.sub(_collChange);
      newDebt = _isDebtIncrease ? _debt.add(_debtChange) : _debt.sub(_debtChange);

      return (newColl, newDebt);
  }

  function _getNewTCRFromTroveChange
  (
      uint _collChange,
      bool _isCollIncrease,
      uint _debtChange,
      bool _isDebtIncrease,
      uint _price
  )
      internal
      view
      returns (uint)
  {
      uint totalColl = getEntireSystemColl();
      uint totalDebt = getEntireSystemDebt();

      totalColl = _isCollIncrease ? totalColl.add(_collChange) : totalColl.sub(_collChange);
      totalDebt = _isDebtIncrease ? totalDebt.add(_debtChange) : totalDebt.sub(_debtChange);

      uint newTCR = _computeCR(totalColl, totalDebt, _price);
      return newTCR;
  }

  function getCompositeDebt(uint _debt) external pure override returns (uint) {
      return _getCompositeDebt(_debt);
  }
}
