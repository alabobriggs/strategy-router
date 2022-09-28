// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.7;

interface IStargateFarm {


    /// @notice returns number of pool in farm
    function poolLength() external view returns (uint256 poolLength);

    /// @notice handles adding a new LP token (Can only be called by the owner)
    /// @param _allocPoint The alloc point is used as the weight of the pool against all other alloc points added.
    /// @param _lpToken The lp token address
    function add(uint256 _allocPoint, address _lpToken) external;

    function set(uint256 _pid, uint256 _allocPoint) external;

    function getMultiplier(uint256 _from, uint256 _to) external view returns (uint256 multiplier);

    function pendingStargate(uint256 _pid, address _user) external view returns (uint256 usePendingAmount);

    function massUpdatePools() external;

    function updatePool(uint256 _pid) external;

    function deposit(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount) external;

    /// @notice Withdraw without caring about rewards.
    /// @param _pid The pid specifies the pool
    function emergencyWithdraw(uint256 _pid) external;

    function setStargatePerBlock(uint256 _stargatePerBlock) external;

    // Override the renounce ownership inherited by zeppelin ownable
}
