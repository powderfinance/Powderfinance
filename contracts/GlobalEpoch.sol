// SPDX-License-Identifier: Unlicense

pragma solidity ^0.7.3;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./interfaces/IGlobalEpoch.sol";


contract GlobalEpoch is IGlobalEpoch {
  using SafeMath for uint256;

  uint256 internal _epoch1Start;
  uint256 constant internal EPOCH_DELAY = 7 days;


  // ------------------
  // CONSTRUCTOR
  // ------------------


  constructor(uint256 epoch1Start) public {
    require(epoch1Start > block.timestamp, "GlobalEpoch: First epoch should start in the future!");

    _epoch1Start = epoch1Start;
  }


  // ------------------
  // GETTERS METHODS
  // ------------------


  function getFirstEpochTime() public view override returns (uint256) {
    return _epoch1Start;
  }

  function getEpochDelay() public pure override returns (uint256) {
    return EPOCH_DELAY;
  }

  function getCurrentEpoch() public view override returns (uint256) {
    if (block.timestamp <= _epoch1Start) {
      return 0;
    }

    return getSecondsSinceFirstEpoch().div(EPOCH_DELAY).add(1);
  }

  function getSecondsUntilNextEpoch() public view override returns (uint256) {
    uint256 currentEpoch = getCurrentEpoch();
    uint256 currentEpochEnd = _epoch1Start.add(currentEpoch.mul(EPOCH_DELAY));
    uint256 timeLeft = currentEpochEnd.sub(block.timestamp);

    return timeLeft;
  }

  function getSecondsSinceThisEpoch() public view override returns (uint256) {
    if (block.timestamp <= _epoch1Start) {
      return 0;
    }

    return getSecondsSinceFirstEpoch() % EPOCH_DELAY;
  }

  function getSecondsSinceFirstEpoch() public view override returns (uint256) {
    if (block.timestamp <= _epoch1Start) {
      return 0;
    }

    return block.timestamp.sub(_epoch1Start);
  }

  function isJuniorStakePeriod() public view override returns (bool) {
    if (block.timestamp <= _epoch1Start) {
      return false;
    }

    return getSecondsSinceThisEpoch() < 24 hours;
  }
}