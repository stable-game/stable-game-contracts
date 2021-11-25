// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Interfaces/IPILLToken.sol";
import "../Interfaces/ICommunityIssuance.sol";
import "../Interfaces/IStabilityPool.sol";
import "../Dependencies/BaseMath.sol";
import "../Dependencies/GstableMath.sol";
import "../Dependencies/Ownable.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/SafeMath.sol";

contract CommunityIssuance is ICommunityIssuance, Ownable, CheckContract, BaseMath {
    using SafeMath for uint;

    // --- Data ---
    string constant public NAME = "CommunityIssuance";

    IPILLToken public pillToken;
    address public stabilityPoolAddress;
    address public rewardMultisigAddress;

    uint public totalPILLIssued;
    uint256 public lastRewardBlock;
    uint256 public rewardRate;

    bool public initialized;

    // --- Events ---
    event RewardMultisigAddressSet(address _rewardMultisigAddress);
    event PILLTokenAddressSet(address _pillTokenAddress);
    event StabilityPoolAddressSet(address _stabilityPoolAddress);
    event TotalPILLIssuedUpdated(uint _totalPILLIssued);
    event RewardRateUpdated(uint256 _rewardRate);
    event LastRewardBlockUpdated(uint256 _lastRewardBlock);

    // --- Functions ---
    constructor(uint256 _rewardRate, address _rewardMultisigAddress) public {
        lastRewardBlock = block.number;
        emit LastRewardBlockUpdated(block.number);

        rewardRate = _rewardRate;
        emit RewardRateUpdated(_rewardRate);

        rewardMultisigAddress = _rewardMultisigAddress;
        emit RewardMultisigAddressSet(_rewardMultisigAddress);
    }

    function setAddresses(
        address _pillTokenAddress, 
        address _stabilityPoolAddress
    )
        external
        onlyOwner
        override
    {
        _requireNotInitialized();

        checkContract(_pillTokenAddress);
        checkContract(_stabilityPoolAddress);

        pillToken = IPILLToken(_pillTokenAddress);
        
        stabilityPoolAddress = _stabilityPoolAddress;

        emit PILLTokenAddressSet(_pillTokenAddress);
        emit StabilityPoolAddressSet(_stabilityPoolAddress);
        initialized = true;
    }

    function setRewardRate(uint256 _rewardRate) external onlyOwner {
        _requireInitialized();

        uint totalGM = IStabilityPool(stabilityPoolAddress).getTotalGMDeposits();
        if (totalGM > 0) {
            uint issuance = _getBlockReward(lastRewardBlock, block.number);
            totalPILLIssued = totalPILLIssued.add(issuance);
            emit TotalPILLIssuedUpdated(totalPILLIssued);
            
            IStabilityPool(stabilityPoolAddress).updateG(issuance);
        }

        lastRewardBlock = block.number;
        rewardRate = _rewardRate;

        emit RewardRateUpdated(_rewardRate);
    }

    function setRewardMultisigAddress(address _rewardMultisigAddress) external onlyOwner {
        _requireInitialized();

        rewardMultisigAddress = _rewardMultisigAddress;

        emit RewardMultisigAddressSet(_rewardMultisigAddress);
    }

    function _getBlockReward(uint256 _from, uint256 _to) internal view returns (uint256) {
        uint256 to = _to;
        uint256 from = _from;

        if (from > to) {
            return 0;
        }

        uint256 rewardPerBlock = rewardRate;
        uint256 totalRewards = (to.sub(from)).mul(rewardPerBlock);

        return totalRewards;
    }

    function issuePILL() external override returns (uint) {
        _requireInitialized();
        _requireCallerIsStabilityPool();

        uint totalGM = IStabilityPool(stabilityPoolAddress).getTotalGMDeposits();
        uint issuance;
        if (totalGM > 0) {
            issuance = _getBlockReward(lastRewardBlock, block.number);
            totalPILLIssued = totalPILLIssued.add(issuance);
            emit TotalPILLIssuedUpdated(totalPILLIssued);
        }
        
        lastRewardBlock = block.number;
        emit LastRewardBlockUpdated(lastRewardBlock);
        
        return issuance;
    }

    function sendPILL(address _account, uint _PILLamount) external override {
        _requireInitialized();
        _requireCallerIsStabilityPool();

        pillToken.transferFrom(rewardMultisigAddress, _account, _PILLamount);
    }

    // --- 'require' functions ---
    function _requireNotInitialized() internal view {
        require(!initialized, "CommunityIssuance: Already initialized");
    }

    function _requireInitialized() internal view {
        require(initialized, "CommunityIssuance: Not initialized");
    }

    function _requireCallerIsStabilityPool() internal view {
        require(msg.sender == stabilityPoolAddress, "CommunityIssuance: caller is not SP");
    }
}
