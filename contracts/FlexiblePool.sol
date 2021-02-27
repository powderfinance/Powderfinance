// SPDX-License-Identifier: Unlicense

pragma solidity ^0.7.3;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


contract FlexiblePool is ReentrancyGuard {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  uint256 [] internal _epochs;
  uint256 internal _epoch1Start;
  uint256 internal _epochsCount;
  uint256 internal _totalAmountPerEpoch;
  uint256 internal _lastWithdrawEpochId;
  uint256 internal _lastInitializedEpoch;

  uint256 constant internal EPOCH_DELAY = 7 days;
  uint256 constant internal BASE_MULTIPLIER = 10 ** 18;

  address internal _rewardFunds;

  IERC20 internal _rewardsToken;
  IERC20 internal _stakingToken;

  struct Checkpoint {
    uint256 epochId;
    uint256 multiplier;
    uint256 startBalance;
    uint256 newDeposits;
  }

  struct Pool {
    uint256 size;
    bool set;
  }

  mapping(address => uint256) internal _balances;
  mapping(address => uint256) private _lastEpochIdRewarded;

  mapping(uint256 => Pool) internal _poolSize;
  mapping(address => Checkpoint[]) internal _balanceCheckpoints;

  event Deposit(address indexed user, uint256 amount);
  event Withdraw(address indexed user, uint256 amount);
  event ManualEpochInit(address indexed caller, uint256 indexed epochId);
  event EmergencyWithdraw(address indexed user, uint256 amount);
  event RewardsPaid(address indexed user, uint256 indexed epochId, uint256 amount);
  event MassRewardsPaid(address indexed user, uint256 epochsRewarded, uint256 totalValue);

  constructor (
    address rewardsToken,
    address stakingToken,
    address rewardFunds,
    uint256 epoch1Start,
    uint256 epochsCount,
    uint256 tokensPerEpoch
  ) public {
    _rewardsToken = IERC20(rewardsToken);
    _stakingToken = IERC20(stakingToken);

    _epoch1Start = epoch1Start;
    _epochsCount = epochsCount;
    _rewardFunds = rewardFunds;
    _epochs = new uint256[](_epochsCount + 1);
    _totalAmountPerEpoch = tokensPerEpoch;
  }

  // ------------------
  // SETTERS METHODS
  // ------------------

  function stake(uint256 amount) external nonReentrant {
    require(amount > 0, "stake: Amount should be bigger 0!");

    _stakingToken.safeTransferFrom(msg.sender, address(this), amount);
    _balances[msg.sender] = _balances[msg.sender].add(amount);

    uint256 currentEpoch = _getCurrentEpoch();
    uint256 currentMultiplier = _currentEpochMultiplier();

    if (!_epochIsInitialized(currentEpoch)) {
      _manualEpochInit(currentEpoch);
    }

    Pool storage pNextEpoch = _poolSize[currentEpoch + 1];
    pNextEpoch.size = _stakingToken.balanceOf(address(this));
    pNextEpoch.set = true;

    Checkpoint[] storage checkpoints = _balanceCheckpoints[msg.sender];
    uint256 balanceBefore = _getEpochUserBalance(msg.sender, currentEpoch);

    if (checkpoints.length == 0) {
      checkpoints.push(Checkpoint(currentEpoch, currentMultiplier, 0, amount));
      checkpoints.push(Checkpoint(currentEpoch + 1, BASE_MULTIPLIER, amount, 0));
    } else {
      uint256 last = checkpoints.length - 1;

      if (checkpoints[last].epochId < currentEpoch) {
        uint256 multiplier = _computeNewMultiplier(
        _getCheckpointBalance(checkpoints[last]),
          BASE_MULTIPLIER,
          amount,
          currentMultiplier
        );
        checkpoints.push(Checkpoint(currentEpoch, multiplier, _getCheckpointBalance(checkpoints[last]), amount));
        checkpoints.push(Checkpoint(currentEpoch + 1, BASE_MULTIPLIER, _balances[msg.sender], 0));
      } else if (checkpoints[last].epochId == currentEpoch) {
        checkpoints[last].multiplier = _computeNewMultiplier(
          _getCheckpointBalance(checkpoints[last]),
          checkpoints[last].multiplier,
          amount,
          currentMultiplier
        );
        checkpoints[last].newDeposits = checkpoints[last].newDeposits.add(amount);
        checkpoints.push(Checkpoint(currentEpoch + 1, BASE_MULTIPLIER, _balances[msg.sender], 0));
      } else {
        if (last >= 1 && checkpoints[last - 1].epochId == currentEpoch) {
          checkpoints[last - 1].multiplier = _computeNewMultiplier(
            _getCheckpointBalance(checkpoints[last - 1]),
            checkpoints[last - 1].multiplier,
            amount,
            currentMultiplier
          );

          checkpoints[last - 1].newDeposits = checkpoints[last - 1].newDeposits.add(amount);
        }

        checkpoints[last].startBalance = _balances[msg.sender];
      }
    }

    uint256 balanceAfter = _getEpochUserBalance(msg.sender, currentEpoch);
    _poolSize[currentEpoch].size = _poolSize[currentEpoch].size.add(balanceAfter.sub(balanceBefore));

    emit Deposit(msg.sender, amount);
  }

  function withdraw(uint256 amount) public nonReentrant {
    require(_balances[msg.sender] >= amount, "withdraw: Not enough balance!");

    _balances[msg.sender] = _balances[msg.sender].sub(amount);
    _stakingToken.safeTransfer(msg.sender, amount);

    uint256 currentEpoch = _getCurrentEpoch();
    _lastWithdrawEpochId = currentEpoch;

    if (!_epochIsInitialized(currentEpoch)) {
      _manualEpochInit(currentEpoch);
    }

    Pool storage pNextEpoch = _poolSize[currentEpoch + 1];
    pNextEpoch.size = _stakingToken.balanceOf(address(this));
    pNextEpoch.set = true;

    Checkpoint[] storage checkpoints = _balanceCheckpoints[msg.sender];
    uint256 last = checkpoints.length - 1;

    if (checkpoints[last].epochId < currentEpoch) {
      checkpoints.push(Checkpoint(currentEpoch, BASE_MULTIPLIER, _balances[msg.sender], 0));
      _poolSize[currentEpoch].size = _poolSize[currentEpoch].size.sub(amount);
    } else if (checkpoints[last].epochId == currentEpoch) {
      checkpoints[last].startBalance = _balances[msg.sender];
      checkpoints[last].newDeposits = 0;
      checkpoints[last].multiplier = BASE_MULTIPLIER;

      _poolSize[currentEpoch].size = _poolSize[currentEpoch].size.sub(amount);
    } else {
      Checkpoint storage currentEpochCheckpoint = checkpoints[last - 1];
      uint256 balanceBefore = _getCheckpointEffectiveBalance(currentEpochCheckpoint);

      if (amount < currentEpochCheckpoint.newDeposits) {
        uint256 avgDepositMultiplier = uint256(
          balanceBefore.sub(currentEpochCheckpoint.startBalance).mul(BASE_MULTIPLIER).div(currentEpochCheckpoint.newDeposits)
        );

        currentEpochCheckpoint.newDeposits = currentEpochCheckpoint.newDeposits.sub(amount);
        currentEpochCheckpoint.multiplier = _computeNewMultiplier(
          currentEpochCheckpoint.startBalance,
          BASE_MULTIPLIER,
          currentEpochCheckpoint.newDeposits,
          avgDepositMultiplier
        );
      } else {
        currentEpochCheckpoint.startBalance = currentEpochCheckpoint.startBalance.sub(
          amount.sub(currentEpochCheckpoint.newDeposits)
        );
        currentEpochCheckpoint.newDeposits = 0;
        currentEpochCheckpoint.multiplier = BASE_MULTIPLIER;
      }

      uint256 balanceAfter = _getCheckpointEffectiveBalance(currentEpochCheckpoint);
      _poolSize[currentEpoch].size = _poolSize[currentEpoch].size.sub(balanceBefore.sub(balanceAfter));
      checkpoints[last].startBalance = _balances[msg.sender];
    }

    emit Withdraw(msg.sender, amount);
  }

  function emergencyWithdraw() public nonReentrant {
    require((_getCurrentEpoch() - _lastWithdrawEpochId) >= 10, "emergencyWithdraw: At least 10 epochs must pass without success!");

    uint256 totalUserBalance = _balances[msg.sender];
    require(totalUserBalance > 0, "emergencyWithdraw: Amount must be > 0!");

    _balances[msg.sender] = 0;
    _stakingToken.safeTransfer(msg.sender, totalUserBalance);

    emit EmergencyWithdraw(msg.sender, totalUserBalance);
  }

  function getReward(uint256 epochId) public nonReentrant returns (uint256) {
    require(_getCurrentEpoch() > epochId, "getReward: Provided epoch is in the future!");
    require(_lastEpochIdRewarded[msg.sender].add(1) == epochId, "getReward: Reward in order!");

    uint256 userReward = _rewardsAmount(epochId);
    if (userReward > 0) {
      _rewardsToken.safeTransferFrom(_rewardFunds, msg.sender, userReward);
    }

    emit RewardsPaid(msg.sender, epochId, userReward);

    return userReward;
  }

  function massRewards() external returns (uint256) {
    uint256 totalDistributedValue;
    uint256 epochId = _getCurrentEpoch().sub(1);

    if (epochId > _epochsCount) {
      epochId = _epochsCount;
    }

    for (uint256 i = _lastEpochIdRewarded[msg.sender] + 1; i <= epochId; i++) {
      totalDistributedValue = totalDistributedValue.add(_rewardsAmount(i));
    }

    emit MassRewardsPaid(msg.sender, epochId - _lastEpochIdRewarded[msg.sender], totalDistributedValue);

    if (totalDistributedValue > 0) {
      _rewardsToken.safeTransferFrom(_rewardFunds, msg.sender, totalDistributedValue);
    }

    return totalDistributedValue;
  }

  // ------------------
  // GETTERS METHODS
  // ------------------

  function getEpoch1Start() external view returns (uint256) {
    return _epoch1Start;
  }

  function getEpochsCount() external view returns (uint256) {
    return _epochsCount;
  }

  function getAmountPerEpoch() external view returns (uint256) {
    return _totalAmountPerEpoch;
  }

  function getLastWithdrawEpochId() external view returns (uint256) {
    return _lastWithdrawEpochId;
  }

  function getLastInitializedEpoch() external view returns (uint256) {
    return _lastInitializedEpoch;
  }

  function getTokens() external view returns (address, address) {
    return (
      address(_rewardsToken),
      address(_stakingToken)
    );
  }

  function getPoolSize(uint256 epochId) external view returns (uint256, bool) {
    return (
      _poolSize[epochId + 1].size,
      _poolSize[epochId + 1].set
    );
  }

  function getUserBalance(address user) external view returns (uint256) {
    return _balances[user];
  }

  function getUserLastEpochIdRewarded(address user) external view returns (uint256) {
    return _lastEpochIdRewarded[user];
  }

  function getCurrentEpochMultiplier() external view returns (uint256) {
    return _currentEpochMultiplier();
  }

  function getEpochPoolSize(uint256 epochId) external view returns (uint256) {
    return _getEpochPoolSize(epochId);
  }

  function getComputeNewMultiplier(uint256 prevBalance, uint128 prevMultiplier, uint256 amount, uint128 currentMultiplier) external pure returns (uint256) {
    return _computeNewMultiplier(prevBalance, prevMultiplier, amount, currentMultiplier);
  }

  function getUserEpochStake(address user, uint128 epochId) external view returns (uint256) {
    return _getEpochUserBalance(user, epochId);
  }

  function getCurrentEpoch() external view returns (uint256) {
    return _getCurrentEpoch();
  }

  function isEpochInitialized(uint256 epochId) external view returns (bool) {
    return _epochIsInitialized(epochId);
  }

  // ------------------
  // INTERNAL METHODS
  // ------------------

  function _manualEpochInit(uint256 epochId) internal {
    require(epochId <= _getCurrentEpoch(), "_manualEpochInit: Can't init a future epoch!");
    require(epochId <= _epochsCount, "_manualEpochInit: Should be less from max epochs count!");

    Pool storage pool = _poolSize[epochId];

    if (epochId == 0) {
      pool.size = 0;
      pool.set = true;
    } else {
      require(!_epochIsInitialized(epochId), "_manualEpochInit: epoch already initialized");
      require(_epochIsInitialized(epochId - 1), "_manualEpochInit: previous epoch not initialized");

      pool.size = _poolSize[epochId - 1].size;
      pool.set = true;
    }

    emit ManualEpochInit(msg.sender, epochId);
  }

  function _getCurrentEpoch() internal view returns (uint256) {
    if (block.timestamp < _epoch1Start) {
      return 0;
    }

    return block.timestamp.sub(_epoch1Start).div(EPOCH_DELAY).add(1);
  }

  function _rewardsAmount(uint256 epochId) internal returns (uint256) {
    if (_lastInitializedEpoch < epochId) {
      _initEpoch(epochId);
    }

    _lastEpochIdRewarded[msg.sender] = epochId;

    if (_epochs[epochId] == 0) {
      return 0;
    }

    return _totalAmountPerEpoch.mul(_getEpochUserBalance(msg.sender, epochId + 1)).div(_epochs[epochId]);
  }

  function _initEpoch(uint256 epochId) internal {
    require(_lastInitializedEpoch.add(1) == epochId, "_initEpoch: Epoch can be init only in order!");

    _lastInitializedEpoch = epochId;
    _epochs[epochId] = _getEpochPoolSize(epochId);
  }

  function _getEpochPoolSize(uint256 epochId) internal view returns (uint256) {
    if (_epochIsInitialized(epochId)) {
      return _poolSize[epochId].size;
    }

    if (!_epochIsInitialized(0)) {
      return 0;
    }

    return _stakingToken.balanceOf(address(this));
  }

  function _currentEpochMultiplier() internal view returns (uint256) {
    uint256 currentEpoch = _getCurrentEpoch();
    uint256 currentEpochEnd = _epoch1Start.add(currentEpoch.mul(EPOCH_DELAY));
    uint256 timeLeft = currentEpochEnd.sub(block.timestamp);
    uint256 multiplier = uint256(timeLeft.mul(BASE_MULTIPLIER).div(EPOCH_DELAY));

    return multiplier;
  }

  function _computeNewMultiplier(uint256 prevBalance, uint256 prevMultiplier, uint256 amount, uint256 currentMultiplier) internal pure returns (uint256) {
    uint256 prevAmount = prevBalance.mul(prevMultiplier).div(BASE_MULTIPLIER);
    uint256 addAmount = amount.mul(currentMultiplier).div(BASE_MULTIPLIER);
    uint256 newMultiplier = prevAmount.add(addAmount).mul(BASE_MULTIPLIER).div(prevBalance.add(amount));

    return newMultiplier;
  }

  function _epochIsInitialized(uint256 epochId) internal view returns (bool) {
    return _poolSize[epochId].set;
  }

  function _getEpochUserBalance(address user, uint256 epochId) internal view returns (uint256) {
    Checkpoint[] storage checkpoints = _balanceCheckpoints[user];

    if (checkpoints.length == 0 || epochId < checkpoints[0].epochId) {
      return 0;
    }

    uint256 min = 0;
    uint256 max = checkpoints.length - 1;
    if (epochId >= checkpoints[max].epochId) {
      return _getCheckpointEffectiveBalance(checkpoints[max]);
    }

    while (max > min) {
      uint256 mid = (max + min + 1) / 2;

      if (checkpoints[mid].epochId <= epochId) {
        min = mid;
      } else {
        max = mid - 1;
      }
    }

    return _getCheckpointEffectiveBalance(checkpoints[min]);
  }

  function _getCheckpointEffectiveBalance(Checkpoint memory checkpoint) internal pure returns (uint256) {
    return _getCheckpointBalance(checkpoint).mul(checkpoint.multiplier).div(BASE_MULTIPLIER);
  }

  function _getCheckpointBalance(Checkpoint memory checkpoint) internal pure returns (uint256) {
    return checkpoint.startBalance.add(checkpoint.newDeposits);
  }
}