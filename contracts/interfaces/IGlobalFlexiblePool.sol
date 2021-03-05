// SPDX-License-Identifier: MIT

pragma solidity ^0.7.1;


interface IGlobalFlexiblePool {
function getEpochUserBalance(address user, address token, uint256 epochId) external view returns (uint256);
function balanceOf(address user, address token) external view returns (uint256);
function getEpochPoolSize(address tokenAddress, uint256 epochId) external view returns (uint256);
function currentEpochMultiplier() external view returns (uint256);
function computeNewMultiplier(uint256 prevBalance, uint256 prevMultiplier, uint256 amount, uint256 currentMultiplier) external pure returns (uint256);
function epochIsInitialized(address token, uint256 epochId) external view returns (bool);
}