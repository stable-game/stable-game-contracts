// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/IERC20.sol";

interface IPILLToken is IERC20 {

    // --- Events ---

    event CommunityIssuanceAddressSet(address _communityIssuanceAddress);
    event PILLStakingAddressSet(address _pillStakingAddress);
    event LockupContractFactoryAddressSet(address _lockupContractFactoryAddress);

    // --- Functions ---

    function sendToPILLStaking(address _sender, uint256 _amount) external;

    function getDeploymentStartTime() external view returns (uint256);

    function getLpRewardsEntitlement() external view returns (uint256);
}
