// SPDX-License-Identifier: Unlicense

pragma solidity ^0.7.3;


interface IGlobalEpoch {
function getCurrentEpoch() external view returns (uint256);
function getSecondsUntilNextEpoch() external view returns (uint256);
function getSecondsSinceThisEpoch() external view returns (uint256);
function getSecondsSinceFirstEpoch() external view returns (uint256);
function isJuniorStakePeriod() external view returns (bool);
function getFirstEpochTime() external view returns (uint256);
function getEpochDelay() external pure returns (uint256);
}