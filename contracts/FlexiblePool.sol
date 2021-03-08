// SPDX-License-Identifier: MIT

pragma solidity ^0.7.1;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./interfaces/IGlobalFlexiblePool.sol";
import "./interfaces/IGlobalEpoch.sol";


contract FlexiblePool is ReentrancyGuard {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  uint256 public epochStart;
  uint256 public epochsCount;
  uint256 public epochDuration;
  uint256 public totalRewardPerEpoch;
  uint256 public lastInitializedEpoch;
  uint256 public epochDelayedFromFirst;
  uint256[] private _epochs;

  // Staking and reward tokens amounts
  address public stakingToken;
  address public rewardFunds;

  // contracts
  IERC20 public rewardToken;
  IGlobalEpoch public globalEpoch;
  IGlobalFlexiblePool public globalFlexiblePool;

  mapping(address => uint256) private lastEpochIdHarvested;

  event MassHarvest(address indexed user, uint256 epochsHarvested, uint256 totalValue);
  event Harvest(address indexed user, uint256 indexed epochId, uint256 amount);


  // ------------------
  // CONSTRUCTOR
  // ------------------


  constructor(
    address _rewardToken,
    address _stakingToken,
    address _globalEpoch,
    address _globalFlexiblePool,
    address _rewardFunds,
    uint256 _rewardPerEpoch,
    uint256 _epochsCount,
    uint256 _epochDelayedFromFirst
  ) public {
    // Reward and staking tokens
    rewardToken = IERC20(_rewardToken);
    stakingToken = _stakingToken;

    // Internal contracts for interaction
    globalEpoch = IGlobalEpoch(_globalEpoch);
    globalFlexiblePool = IGlobalFlexiblePool(_globalFlexiblePool);

    // Address, from where users receive rewards
    rewardFunds = _rewardFunds;

    epochDuration = globalEpoch.getEpochDelay();
    epochDelayedFromFirst = _epochDelayedFromFirst;
    epochStart = globalEpoch.getFirstEpochTime() + epochDuration.mul(epochDelayedFromFirst);

    totalRewardPerEpoch = _rewardPerEpoch;
    epochsCount = _epochsCount;
    _epochs = new uint256[](epochsCount + 1);
  }


  // ------------------
  // SETTERS METHODS
  // ------------------


  function massHarvest() external nonReentrant returns (uint256) {
    uint256 totalDistributedValue;
    uint256 epochId = _getEpochId().sub(1);

    if (epochId > epochsCount) {
      epochId = epochsCount;
    }

    for (uint256 i = lastEpochIdHarvested[msg.sender] + 1; i <= epochId; i++) {
      totalDistributedValue += _harvest(i);
    }

    emit MassHarvest(msg.sender, epochId - lastEpochIdHarvested[msg.sender], totalDistributedValue);

    if (totalDistributedValue > 0) {
      rewardToken.safeTransferFrom(rewardFunds, msg.sender, totalDistributedValue);
    }

    return totalDistributedValue;
  }

  function harvest(uint256 epochId) external nonReentrant returns (uint256) {
    require(_getEpochId() > epochId, "harvest: This epoch is in the future!");
    require(epochId <= epochsCount, "harvest: Reached maximum number of epochs!");
    require(lastEpochIdHarvested[msg.sender].add(1) == epochId, "harvest: Harvest in order!");

    uint256 userReward = _harvest(epochId);
    if (userReward > 0) {
      rewardToken.safeTransferFrom(rewardFunds, msg.sender, userReward);
    }

    emit Harvest(msg.sender, epochId, userReward);

    return userReward;
  }


  // ------------------
  // GETTERS METHODS
  // ------------------


  function getPoolSize(uint256 epochId) external view returns (uint256) {
    return _getPoolSize(epochId);
  }

  function getEpochStake(address userAddress, uint256 epochId) external view returns (uint256) {
    return _getUserBalancePerEpoch(userAddress, epochId);
  }

  function userLastEpochIdHarvested() external view returns (uint256) {
    return lastEpochIdHarvested[msg.sender];
  }


  // ------------------
  // INTERNAL METHODS
  // ------------------


  function _harvest(uint256 epochId) internal returns (uint256) {
    // try to initialize an epoch. if it can't it fails
    // if it fails either user either a BarnBridge account will init not init epochs
    if (lastInitializedEpoch < epochId) {
      _initEpoch(epochId);
    }
    // Set user state for last harvested
    lastEpochIdHarvested[msg.sender] = epochId;
    // compute and return user total reward. For optimization reasons the transfer have been moved to an upper layer (i.e. massHarvest needs to do a single transfer)

    // exit if there is no stake on the epoch
    if (_epochs[epochId] == 0) {
      return 0;
    }

    return totalRewardPerEpoch
      .mul(_getUserBalancePerEpoch(msg.sender, epochId))
      .div(_epochs[epochId]);
  }

  function _initEpoch(uint256 epochId) internal {
    require(lastInitializedEpoch.add(1) == epochId, "_initEpoch: Epoch can be init only in order!");
    lastInitializedEpoch = epochId;
    // call the staking smart contract to init the epoch
    _epochs[epochId] = _getPoolSize(epochId);
  }

  function _getPoolSize(uint256 epochId) internal view returns (uint256) {
    return globalFlexiblePool.getEpochPoolSize(stakingToken, globalFlexiblePoolEpochId(epochId));
  }

  function _getEpochId() internal view returns (uint256) {
    if (block.timestamp < epochStart) {
      return 0;
    }

    return block.timestamp.sub(epochStart).div(epochDuration).add(1);
  }

  function _getUserBalancePerEpoch(address userAddress, uint256 epochId) internal view returns (uint256) {
    return globalFlexiblePool.getEpochUserBalance(userAddress, stakingToken, globalFlexiblePoolEpochId(epochId));
  }

  function globalFlexiblePoolEpochId(uint256 epochId) view internal returns (uint256) {
    return epochId + epochDelayedFromFirst;
  }
}