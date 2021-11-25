// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/CheckContract.sol";
import "../Dependencies/SafeMath.sol";
import "../Interfaces/IPILLToken.sol";
import "../Dependencies/console.sol";
import "../Dependencies/Ownable.sol";
import {IUniswapV2Router02} from "../Interfaces/IUniswapV2Router.sol";
import {IUniswapFactory} from "../Interfaces/IUniswapFactory.sol";

contract PILLToken is CheckContract, IPILLToken, Ownable {
    using SafeMath for uint256;

    // --- ERC20 Data ---

    string constant internal _NAME = "PILLToken";
    string constant internal _SYMBOL = "PILL";
    uint8 constant internal  _DECIMALS = 18;

    mapping (address => uint256) private _balances;
    mapping (address => mapping (address => uint256)) private _allowances;
    uint private _totalSupply;

    // --- Transfer fee ---
    address public uniswapV2RouterAddress;
    address public uniswapV2PairAddress;

    address public transferFeeCollector;

    bool whiteListInitialized;
    uint public transferFee;  // divided by 1000
    mapping(address => bool) public isExcludedFromFee;

    // uint for use with SafeMath
    uint internal _1_MILLION = 1e24;    // 1e6 * 1e18 = 1e24

    uint internal deploymentStartTime;
    address public multisigAddress;
    address public communityMultisigAddress;

    address public pillStakingAddress;
    uint internal lpRewardsEntitlement;

    // --- Events ---
    event WhiteListInitialized();
    event TransferFeeCollectorUpdated(address transferFeeCollector);
    event WhiteListUpdated(address targetAddress, bool isWhiteList);
    event TransferFeeUpdated(uint newFee);

    event CommunityIssuanceAddressSet(address _communityIssuanceAddress);
    event PILLStakingAddressSet(address _pillStakingAddress);

    // --- Functions ---

    constructor(
        address _lpRewardsAddress,
        address _multisigAddress,
        address _communityMultisigAddress,
        address _transferFeeCollector
    ) public {
        multisigAddress = _multisigAddress;
        communityMultisigAddress = _communityMultisigAddress;
        deploymentStartTime  = block.timestamp;

        transferFeeCollector = _transferFeeCollector;
        isExcludedFromFee[transferFeeCollector] = true;

        // --- Initial PILL allocations ---

        // mint to reward
        uint depositorsAndFrontEndsEntitlement = _1_MILLION.mul(32); // Allocate 32 million to the algorithmic issuance schedule
        _mint(communityMultisigAddress, depositorsAndFrontEndsEntitlement);

        // mint to LP reward
        uint _lpRewardsEntitlement = _1_MILLION.mul(4).div(3);  // Allocate 1.33 million for LP rewards
        lpRewardsEntitlement = _lpRewardsEntitlement;
        _mint(_lpRewardsAddress, _lpRewardsEntitlement);

        // Allocate the remainder to the PILL Multisig
        uint multisigEntitlement = _1_MILLION.mul(100) // Allocate (100-32-1.33) million for multisig
            .sub(depositorsAndFrontEndsEntitlement)
            .sub(_lpRewardsEntitlement);

        _mint(_multisigAddress, multisigEntitlement);
    }

    function setAddresses(address _pillStakingAddress) external onlyOwner {
        checkContract(_pillStakingAddress);

        pillStakingAddress = _pillStakingAddress;
        isExcludedFromFee[pillStakingAddress] = true;

        emit PILLStakingAddressSet(_pillStakingAddress);
    }

    // init whitlist
    function initWhiteList(address _uniswapV2RouterAddress, address _usdtTokenAddress) external onlyOwner {
        require(!whiteListInitialized, "PILLToken: whiteList already initialized");
        require(_uniswapV2RouterAddress != address(0), "PILLToken: uniswapV2RouterAddress address cannot be 0x0");
        require(_usdtTokenAddress != address(0), "PILLToken: usdtTokenAddress address cannot be 0x0");

        uniswapV2RouterAddress = _uniswapV2RouterAddress;
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(_uniswapV2RouterAddress);
        uniswapV2PairAddress = IUniswapFactory(_uniswapV2Router.factory()).createPair(address(this), _usdtTokenAddress);

        isExcludedFromFee[address(this)] = true;
        isExcludedFromFee[uniswapV2RouterAddress] = true;

        whiteListInitialized = true;
        emit WhiteListInitialized();
    }

    // transfer fee setting
    function setTransferFeeCollector(address _transferFeeCollector) external onlyOwner {
        require(_transferFeeCollector != address(0), "PILLToken: transferFeeCollector address cannot be 0x0");
        transferFeeCollector = _transferFeeCollector;
        emit TransferFeeCollectorUpdated(transferFeeCollector);
    }

    function setTransferFee(uint _newTransferFee) external onlyOwner {
        transferFee = _newTransferFee;
        emit TransferFeeUpdated(_newTransferFee);
    }

    function alterWhitelist(address _targetAddress, bool _isWhiteList) external onlyOwner {
        require(_targetAddress != address(0), "PILLToken: whiteList address cannot be 0x0");
        isExcludedFromFee[_targetAddress] = _isWhiteList;
        emit WhiteListUpdated(_targetAddress, _isWhiteList);
    }

    // --- External functions ---
    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function getDeploymentStartTime() external view override returns (uint256) {
        return deploymentStartTime;
    }

    function getLpRewardsEntitlement() external view override returns (uint256) {
        return lpRewardsEntitlement;
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {

        _requireValidRecipient(recipient);

        // Otherwise, standard transfer functionality
        _tokenTransfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {

        _requireValidRecipient(recipient);

        _tokenTransfer(sender, recipient, amount);
        _approve(sender, msg.sender, _allowances[sender][msg.sender].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external override returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external override returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function sendToPILLStaking(address _sender, uint256 _amount) external override {
        _requireCallerIsPILLStaking();
        _transfer(_sender, pillStakingAddress, _amount);
    }

    // --- Internal operations ---

    function _tokenTransfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "PILLToken: transfer from the zero address");
        require(recipient != address(0), "PILLToken: transfer to the zero address");

        bool excludedFromFee = (sender == uniswapV2PairAddress || isExcludedFromFee[sender] || isExcludedFromFee[recipient]);

        if (!excludedFromFee) {
            (uint256 stakingFee) = _calculateFees(amount);

            if (stakingFee > 0) {
                _transfer(sender, transferFeeCollector, stakingFee);
            }

            amount = amount.sub(stakingFee);
        }

        _transfer(sender, recipient, amount);
    }

    function _calculateFees(uint256 amount) internal view returns (uint256){
        if(transferFee > 0){
          uint256 stakingFee = amount.mul(transferFee).div(1000);
          return stakingFee;
        } else {
          return 0;
        }
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    // --- Helper functions ---

    function _callerIsMultisig() internal view returns (bool) {
        return (msg.sender == multisigAddress);
    }

    // --- 'require' functions ---

    function _requireValidRecipient(address _recipient) internal view {
        require(
            _recipient != address(0) &&
            _recipient != address(this),
            "PILL: Cannot transfer tokens directly to the PILL token contract or the zero address"
        );
        require(
            _recipient != pillStakingAddress,
            "PILL: Cannot transfer tokens directly to the staking contract"
        );
    }


    function _requireCallerIsPILLStaking() internal view {
         require(msg.sender == pillStakingAddress, "PILLToken: caller must be the PILLStaking contract");
    }

    // --- Optional functions ---

    function name() external view override returns (string memory) {
        return _NAME;
    }

    function symbol() external view override returns (string memory) {
        return _SYMBOL;
    }

    function decimals() external view override returns (uint8) {
        return _DECIMALS;
    }
}