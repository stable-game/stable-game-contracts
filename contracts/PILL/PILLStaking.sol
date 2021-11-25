// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/IERC20.sol";
import "../Dependencies/SafeMath.sol";
import "../Interfaces/IPILLToken.sol";
import "hardhat/console.sol";

contract PILLStaking  {
    using SafeMath for uint256;

    string constant public NAME = "PILLStaking";

    IPILLToken public pillToken;

    mapping(address => uint256) public stakes;
    uint256 public totalPILLStaked;

    // Other reward tokens
    address[] public rewardTokens;
    mapping(address => bool) public rewardTokensList;
    mapping(address => address) public rewardTokenCollectors;
    mapping(address => uint256) private _accRewardPerBalance;
    /// @dev A mapping of all of the user reward debt mapped first by reward token and then by address.
    mapping(address => mapping(address => uint256)) private _rewardDebt;

    /// @dev The address of the account which currently has administrative capabilities over this contract.
    address public governance;
    address public pendingGovernance;

    event PendingGovernanceUpdated(address pendingGovernance);
    event GovernanceUpdated(address governance);
    event RewardTokenAdded(address rewardToken);

    event TotalPILLStakedUpdated(uint totalPILLStaked);
    event StakeChanged(address indexed staker, uint newStake);

    event RewardClaimed(address indexed user, address rewardAddress, uint256 reward);
    event RewardCollectorUpdated(address rewardAddress, address collector);

    // solium-disable-next-line
    constructor(address _pillToken,
                address[] memory _rewardTokens,
                address[] memory _rewardCollectors, 
                address _governance) public {
        require(_pillToken != address(0), "PILLStaking: pillToken address cannot be 0x0");
        require(_governance != address(0), "PILLStaking: governance address cannot be 0x0");
        require(_rewardTokens.length == _rewardCollectors.length, "PILLStaking: reward token and reward collector length mismatch");

        pillToken = IPILLToken(_pillToken);
        governance = _governance;
        emit GovernanceUpdated(_governance);

        for (uint i=0; i<_rewardTokens.length; i++) {
            address rewardToken = _rewardTokens[i];
            require(rewardToken != address(0), "PILLStaking: other reward token address cannot be 0x0");

            address rewardCollector = _rewardCollectors[i];
            require(rewardCollector != address(0), "PILLStaking: reward collector address cannot be 0x0");

            if (!rewardTokensList[rewardToken]) {
                rewardTokensList[rewardToken] = true;
                rewardTokens.push(rewardToken);
                rewardTokenCollectors[rewardToken] = rewardCollector;
                emit RewardTokenAdded(rewardToken);
                emit RewardCollectorUpdated(rewardToken, rewardCollector);
            }
        }
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "PILLStaking: only governance");
        _;
    }

    function setPendingGovernance(address _pendingGovernance) external onlyGovernance {
        require(_pendingGovernance != address(0), "PILLStaking: pending governance address cannot be 0x0");
        pendingGovernance = _pendingGovernance;

        emit PendingGovernanceUpdated(_pendingGovernance);
    }

    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "PILLStaking: only pending governance");

        address _pendingGovernance = pendingGovernance;
        governance = _pendingGovernance;

        emit GovernanceUpdated(_pendingGovernance);
    }

    function setRewardCollector(address _rewardToken, address _collector) external onlyGovernance {
        require(_collector != address(0), "PILLStaking: collector address cannot be 0x0");
        rewardTokenCollectors[_rewardToken] = _collector;
        emit RewardCollectorUpdated(_rewardToken, _collector);
    }

    function addRewardToken(address _rewardToken, address _collector) external onlyGovernance {
        require(_rewardToken != address(0), "PILLStaking: new reward token address cannot be 0x0");
        require(_collector != address(0), "PILLStaking: new reward collector address cannot be 0x0");

        if (!rewardTokensList[_rewardToken]) {
            rewardTokens.push(_rewardToken);
            rewardTokensList[_rewardToken] = true;
            rewardTokenCollectors[_rewardToken] = _collector;
            emit RewardTokenAdded(_rewardToken);
            emit RewardCollectorUpdated(_rewardToken, _collector);
        }
    }

    function rewardTokensLength() public view returns (uint256) {
        return rewardTokens.length;
    }

    function stake(uint256 _amount) public claimReward(msg.sender) {
        _requireNonZeroAmount(_amount);

        totalPILLStaked = totalPILLStaked.add(_amount);
        emit TotalPILLStakedUpdated(totalPILLStaked);

        stakes[msg.sender] = stakes[msg.sender].add(_amount);

        // Transfer PILL from caller to this contract
        pillToken.sendToPILLStaking(msg.sender, _amount);

        emit StakeChanged(msg.sender, stakes[msg.sender]);
    }

    function stakeAll() external returns(bool){
        uint256 balance = pillToken.balanceOf(msg.sender);
        stake(balance);
    }

    function unstake(uint256 _amount) public claimReward(msg.sender) {
        _requireNonZeroAmount(_amount);
        require(_amount <= stakes[msg.sender], 'PILLStaking: Cannot unstake more than your staked');

        totalPILLStaked = totalPILLStaked.sub(_amount);
        emit TotalPILLStakedUpdated(totalPILLStaked);

        stakes[msg.sender] = stakes[msg.sender].sub(_amount);

        pillToken.transfer(msg.sender, _amount);

        emit StakeChanged(msg.sender, stakes[msg.sender]);
    }

    function unstakeAll() external {
        unstake(stakes[msg.sender]);
    }

    function collectReward() public {
        if (totalPILLStaked == 0) {
            return;
        }

        for (uint i=0; i<rewardTokens.length; i++) {
            address tokenAddress = rewardTokens[i];
            address rewardCollector = rewardTokenCollectors[tokenAddress];
            if (tokenAddress != address(0)) {
                IERC20 token = IERC20(tokenAddress);
                uint256 newReward = token.balanceOf(rewardCollector);
                if (newReward == 0) {
                    return;
                }
                token.transferFrom(rewardCollector, address(this), newReward);
                _accRewardPerBalance[tokenAddress] = _accRewardPerBalance[tokenAddress].add(newReward.mul(1e18).div(totalPILLStaked));
           }
        }
    }

    function pendingReward(address account, address tokenAddress) public view returns (uint256) {
        require(tokenAddress != address(0), "PILLStaking: reward token address cannot be 0x0");
        IERC20 token = IERC20(tokenAddress);
        address rewardCollector = rewardTokenCollectors[tokenAddress];

        uint256 pending;
        if (stakes[account] > 0) {
            uint256 newReward = token.balanceOf(rewardCollector);
            uint256 newAccRewardPerBalance = _accRewardPerBalance[tokenAddress].add(newReward.mul(1e18).div(totalPILLStaked));
            pending = stakes[account].mul(newAccRewardPerBalance).div(1e18).sub(_rewardDebt[account][tokenAddress]);
        }
        return pending;
    }

    // solium-disable-next-line no-empty-blocks
    function getReward() external claimReward(msg.sender) {
    }

    modifier claimReward(address _addr) {
        collectReward();
        uint256 balance = stakes[_addr];
        if (balance > 0) {
            for (uint i=0; i<rewardTokens.length; i++) {
                address tokenAddress = rewardTokens[i];
                if (tokenAddress != address(0)) {
                    IERC20 token = IERC20(tokenAddress);
                    uint256 pending = balance.mul(_accRewardPerBalance[tokenAddress]).div(1e18).sub(_rewardDebt[_addr][tokenAddress]);
                    if (pending > 0) {
                        _safeTokenTransfer(tokenAddress, _addr, pending);
                        emit RewardClaimed(_addr, tokenAddress, pending);
                    }
                }
            }
        }
        _; // stakes[msg.sender] may changed.
        balance = stakes[_addr];
        for (uint i=0; i<rewardTokens.length; i++) {
            address tokenAddress = rewardTokens[i];
            if (tokenAddress != address(0)) {
                _rewardDebt[_addr][tokenAddress] = balance.mul(_accRewardPerBalance[tokenAddress]).div(1e18);
            }
        }
    }

    function _safeTokenTransfer(address tokenAddress, address _to, uint256 _amount) internal {
        IERC20 token = IERC20(tokenAddress);
        if (_amount > 0) {
            uint256 tokenBal = token.balanceOf(address(this));
            if (_amount > tokenBal) {
                token.transfer(_to, tokenBal);
            } else {
                token.transfer(_to, _amount);
            }
        }
    }

    // --- 'require' functions ---
    function _requireNonZeroAmount(uint _amount) internal pure {
        require(_amount > 0, 'PILLStaking: Amount must be non-zero');
    }
}