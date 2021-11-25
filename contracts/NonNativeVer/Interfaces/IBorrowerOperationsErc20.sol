// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

interface IBorrowerOperationsErc20 {

  // --- Functions ---

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
  ) external;

  function openTrove(uint _collAmount, uint _maxFee, uint _GMAmount, address _upperHint, address _lowerHint) external;

  function addColl(uint _collAmount, address _upperHint, address _lowerHint) external;

  function moveETHGainToTrove(uint _collAmount, address _user, address _upperHint, address _lowerHint) external;

  function withdrawColl(uint _amount, address _upperHint, address _lowerHint) external;

  function withdrawGM(uint _maxFee, uint _amount, address _upperHint, address _lowerHint) external;

  function repayGM(uint _amount, address _upperHint, address _lowerHint) external;

  function closeTrove() external;

  function adjustTrove(uint _collAmount, uint _maxFee, uint _collWithdrawal, uint _debtChange, bool isDebtIncrease, address _upperHint, address _lowerHint) external;

  function claimCollateral() external;

  function getCompositeDebt(uint _debt) external pure returns (uint);
}
