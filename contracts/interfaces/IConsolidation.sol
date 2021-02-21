// SPDX-License-Identifier: Unlicense

pragma solidity ^0.7.3;


interface IConsolidation {
  function safeKeep() external payable;
  function safeKeep(address token, uint256 amount) external;
  function safeWithdraw(uint256 amount) external;
  function safeWithdraw(address token, uint256 amount) external;
  function getBalance(address user, address token) external view returns (uint256);
}