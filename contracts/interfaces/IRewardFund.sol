// SPDX-License-Identifier: Unlicense

pragma solidity ^0.7.3;


interface IRewardFund {
  function approveRewards(address pool, uint256 amount) external;
  function modifyReward(address pool, uint256 newAmount) external;
  function getFundBalance() external view returns (uint256);
  function getPoolRewards(address pool) external view returns (uint256, uint256);
}