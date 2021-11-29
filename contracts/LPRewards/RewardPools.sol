// SPDX-License-Identifier: MIT
pragma solidity 0.6.11;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import {IVotingEscrow} from "./Interfaces/IVotingEscrow.sol";

contract RewardPool {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public stakingToken;

    // Minted Reward
    address public veToken;
    bool public veBoostEnabled;
    address public pillToken;
    uint256 public pillTokenRewardRate;
    uint256 lastRewardBlock; //Last block number that pill token distribution occurs.
    uint256 private _accPillTokenRewardPerBalance;
    mapping (address => uint256) private _pillTokenRewardDebts;


    // Other reward tokens
    address[] public rewardTokens;
    mapping(address => bool) public rewardTokensList;
    mapping (address => uint256) private _accRewardPerBalance;
    /// @dev A mapping of all of the user reward debt mapped first by reward token and then by address.
    mapping(address => mapping(address => uint256)) private _rewardDebt;

    /// @dev The address of the account which currently has administrative capabilities over this contract.
    address public governance;
    address public pendingGovernance;
    address public collector;
    address public pillCollector;

    uint256 private _totalSupply;
    mapping (address => uint256) private _balances;

    uint256 private _workingSupply;
    mapping (address => uint256) private _workingAmount;

    event PendingGovernanceUpdated(address pendingGovernance);
    event GovernanceUpdated(address governance);
    event RewardTokenAdded(address rewardToken);
    event PillTokenRewardRateUpdated(uint256 pillTokenRewardRate);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, address rewardAddress, uint256 reward);
    event CollectorUpdated(address collector);
    event PillCollectorUpdated(address pillCollector);
    event VeBoostedEnableUpdated(bool enable);
    event WorkingAmountUpdate(
        address indexed user,
        uint256 newWorkingAmount,
        uint256 newWorkingSupply
    );

    // solium-disable-next-line
    constructor(address _stakingToken, address _pillToken, uint256 _pillTokenRewardRate, bool _veBoostEnabled, address _veToken,
                address[] memory _rewardTokens, address _governance, address _collector, address _pillCollector) public {
        require(_stakingToken != address(0), "RewardPool: staking token address cannot be 0x0");
        require(_pillToken != address(0), "RewardPool: pill reward token address cannot be 0x0");
        require(_governance != address(0), "RewardPool: governance address cannot be 0x0");
        require(_collector != address(0), "RewardPool: collector address cannot be 0x0");
        require(_pillCollector != address(0), "RewardPool: pillCollector address cannot be 0x0");
        require(_veToken != address(0), "RewardPool: veToken address cannot be 0x0");

        stakingToken = _stakingToken;
        pillToken = _pillToken;
        pillTokenRewardRate = _pillTokenRewardRate;
        veToken = _veToken;
        veBoostEnabled = _veBoostEnabled;

        for (uint i=0; i<_rewardTokens.length; i++) {
            address rewardToken = _rewardTokens[i];
            if (!rewardTokensList[rewardToken]) {
                rewardTokensList[rewardToken] = true;
                rewardTokens.push(rewardToken);
            }
        }
        governance = _governance;
        collector = _collector;
        pillCollector = _pillCollector;
        lastRewardBlock = block.number;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "RewardPool: only governance");
        _;
    }

    function setPendingGovernance(address _pendingGovernance) external onlyGovernance {
        require(_pendingGovernance != address(0), "RewardPool: pending governance address cannot be 0x0");
        pendingGovernance = _pendingGovernance;

        emit PendingGovernanceUpdated(_pendingGovernance);
    }

    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "RewardPool: only pending governance");

        address _pendingGovernance = pendingGovernance;
        governance = _pendingGovernance;

        emit GovernanceUpdated(_pendingGovernance);
    }

    function setCollector(address _collector) external onlyGovernance {
        require(_collector != address(0), "RewardPool: collector address cannot be 0x0.");
        collector = _collector;
        emit CollectorUpdated(_collector);
    }

    function setPillCollector(address _pillCollector) external onlyGovernance {
        require(_pillCollector != address(0), "RewardPool: pillCollector address cannot be 0x0.");
        pillCollector = _pillCollector;
        emit PillCollectorUpdated(_pillCollector);
    }

    function setVeBoostedEnable(bool _veBoostEnabled) external onlyGovernance {
        collectReward();
        veBoostEnabled = _veBoostEnabled;
        emit VeBoostedEnableUpdated(_veBoostEnabled);
    }

    function addRewardToken(address _rewardToken) external onlyGovernance {
        require(_rewardToken != address(0), "RewardPool: new reward token address cannot be 0x0");
        require(_rewardToken != pillToken, "RewardPool: new reward token address cannot be the pill token");

        if (!rewardTokensList[_rewardToken]) {
            rewardTokens.push(_rewardToken);
            rewardTokensList[_rewardToken] = true;
            emit RewardTokenAdded(_rewardToken);
        }
    }

    function setPillTokenRewardRate(uint256 _pillTokenRewardRate) external onlyGovernance {
        collectReward();
        pillTokenRewardRate = _pillTokenRewardRate;
        emit PillTokenRewardRateUpdated(_pillTokenRewardRate);
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function workingAmount(address account) public view returns (uint256) {
      return _workingAmount[account];
    }

    function workingSupply() public view returns (uint256) {
      return _workingSupply;
    }

    function rewardTokensLength() public view returns (uint256) {
        return rewardTokens.length;
    }

    function stake(uint256 _amount) public claimReward(msg.sender) {
        require(_amount > 0, 'RewardPool : Cannot stake 0');

        _totalSupply = _totalSupply.add(_amount);
        _balances[msg.sender] = _balances[msg.sender].add(_amount);

        IERC20(stakingToken).safeTransferFrom(msg.sender, address(this), _amount);
        emit Staked(msg.sender, _amount);
    }

    function stakeAll() external returns(bool){
        uint256 balance = IERC20(stakingToken).balanceOf(msg.sender);
        stake(balance);
    }

    function stakeFor(address _for, uint256 _amount) external claimReward(_for) {
        require(_amount > 0, 'RewardPool : Cannot stake 0');

        //give to _for
        _totalSupply = _totalSupply.add(_amount);
        _balances[_for] = _balances[_for].add(_amount);

        IERC20(stakingToken).safeTransferFrom(msg.sender, address(this), _amount);
        emit Staked(_for, _amount);
    }

    function withdraw(uint256 _amount) public claimReward(msg.sender) {
        require(_amount > 0, 'RewardPool : Cannot withdraw 0');
        require(_amount <= _balances[msg.sender], 'RewardPool : Cannot withdraw more than your staked');

        _totalSupply = _totalSupply.sub(_amount);
        _balances[msg.sender] = _balances[msg.sender].sub(_amount);

        IERC20(stakingToken).safeTransfer(msg.sender, _amount);

        emit Withdrawn(msg.sender, _amount);
    }

    function withdrawAll() external {
        withdraw(_balances[msg.sender]);
    }

    // Return block rewards over the given _from (inclusive) to _to (inclusive) block.
    function getBlockReward(uint256 _from, uint256 _to) public view returns (uint256) {
        uint256 to = _to;
        uint256 from = _from;

        if (from > to) {
            return 0;
        }

        uint256 rewardPerBlock = pillTokenRewardRate;
        uint256 totalRewards = (to.sub(from)).mul(rewardPerBlock);

        return totalRewards;
    }

    function collectReward() public {
        if (block.number <= lastRewardBlock) {
            return;
        }

        if (_totalSupply == 0) {
            lastRewardBlock = block.number;
            return;
        }

        uint256 pillTokenReward = getBlockReward(lastRewardBlock, block.number);
        if (pillTokenReward > 0) {
            IERC20(pillToken).transferFrom(pillCollector, address(this), pillTokenReward);
            _accPillTokenRewardPerBalance = _accPillTokenRewardPerBalance.add(pillTokenReward.mul(1e18).div(_workingSupply));
        }
        lastRewardBlock = block.number;

        for (uint i=0; i<rewardTokens.length; i++) {
            address tokenAddress = rewardTokens[i];
            if (tokenAddress != address(0)) {
                IERC20 token = IERC20(tokenAddress);
                uint256 newReward = token.balanceOf(collector);
                if (newReward == 0) {
                    return;
                }
                token.transferFrom(collector, address(this), newReward);
                _accRewardPerBalance[tokenAddress] = _accRewardPerBalance[tokenAddress].add(newReward.mul(1e18).div(_totalSupply));
           }
        }
    }

    function pendingReward(address account, address tokenAddress) public view returns (uint256) {
        require(tokenAddress != address(0), "RewardPool: reward token address cannot be 0x0.");
        IERC20 token = IERC20(tokenAddress);

        uint256 pending;
        if (_balances[account] > 0) {
            uint256 newReward = token.balanceOf(collector);
            uint256 newAccRewardPerBalance = _accRewardPerBalance[tokenAddress].add(newReward.mul(1e18).div(_totalSupply));
            pending = _balances[account].mul(newAccRewardPerBalance).div(1e18).sub(_rewardDebt[account][tokenAddress]);
        }
        return pending;
    }

    function pendingPillReward(address account) public view returns (uint256) {
        uint256 pending;

        if (_workingAmount[account] > 0) {
            uint256 accRewardPerBalance = _accPillTokenRewardPerBalance;
            if (block.number > lastRewardBlock) {
                uint256 pillTokenReward = getBlockReward(lastRewardBlock, block.number);
                accRewardPerBalance = _accPillTokenRewardPerBalance.add(pillTokenReward.mul(1e18).div(_workingSupply));
            }
            pending = _workingAmount[account].mul(accRewardPerBalance).div(1e18).sub(_pillTokenRewardDebts[account]);
        }
        return pending;
    }

    // solium-disable-next-line no-empty-blocks
    function getReward() external claimReward(msg.sender) {
    }

    modifier claimReward(address _addr) {
        collectReward();
        uint256 balance = _balances[_addr];
        uint256 userWorkingAmount = _workingAmount[_addr];
        if (balance > 0) {
            uint256 pillRewardPending = userWorkingAmount.mul(_accPillTokenRewardPerBalance).div(1e18).sub(_pillTokenRewardDebts[_addr]);
            if (pillRewardPending > 0) {
                _safeTokenTransfer(pillToken, _addr, pillRewardPending);
                emit RewardClaimed(_addr, pillToken, pillRewardPending);
            }
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
        _; // _balances[msg.sender] may changed.
        balance = _balances[_addr];
        for (uint i=0; i<rewardTokens.length; i++) {
            address tokenAddress = rewardTokens[i];
            if (tokenAddress != address(0)) {
                _rewardDebt[_addr][tokenAddress] = balance.mul(_accRewardPerBalance[tokenAddress]).div(1e18);
            }
        }

        _updateWorkingAmount(_addr);
        userWorkingAmount = _workingAmount[_addr];
        _pillTokenRewardDebts[_addr] = userWorkingAmount.mul(_accPillTokenRewardPerBalance).div(1e18);
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

    function _updateWorkingAmount(
        address _account
    ) internal
    {
        uint256 userAmount = _balances[_account];

        uint256 lim = userAmount.mul(4).div(10);

        uint256 votingBalance = IVotingEscrow(veToken).balanceOf(_account);
        uint256 totalBalance = IVotingEscrow(veToken).totalSupply();

        if (totalBalance != 0 && veBoostEnabled) {
            lim = lim.add(_totalSupply.mul(votingBalance).div(totalBalance).mul(6).div(10));
        }

        uint256 veAmount = Math.min(userAmount, lim);

        _workingSupply = _workingSupply.sub(_workingAmount[_account]).add(veAmount);
        _workingAmount[_account] = veAmount;

        emit WorkingAmountUpdate(_account, veAmount, _workingSupply);
    }
}
