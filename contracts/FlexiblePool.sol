// SPDX-License-Identifier: Unlicense

pragma solidity ^0.7.3;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


contract FlexiblePool is ReentrancyGuard {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  uint256 [] internal _epochs;
  uint256 public epoch1Start;
  uint256 public epochsCount;
  uint256 public totalAmountPerEpoch;
  uint256 public lastWithdrawEpochId;
  uint256 public lastInitializedEpoch;

  uint256 constant internal EPOCH_DELAY = 7 days;
  uint256 constant internal BASE_MULTIPLIER = 10 ** 18;

  address public rewardFund;

  IERC20 public rewardsToken;
  IERC20 public stakingToken;

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
  mapping(address => uint256) internal _lastEpochIdRewarded;

  mapping(uint256 => Pool) internal _poolSize;
  mapping(address => Checkpoint[]) internal _balanceCheckpoints;

  event Deposit(address indexed user, uint256 amount);
  event Withdraw(address indexed user, uint256 amount);
  event ManualEpochInit(address indexed caller, uint256 indexed epochId);
  event EmergencyWithdraw(address indexed user, uint256 amount);
  event RewardsPaid(address indexed user, uint256 indexed epochId, uint256 amount);
  event MassRewardsPaid(address indexed user, uint256 epochsRewarded, uint256 totalValue);

  constructor(
    address _rewardsToken,
    address _stakingToken,
    address _rewardFund,
    uint256 _epoch1Start,
    uint256 _epochsCount,
    uint256 _tokensPerEpoch
  ) public {
    rewardsToken = IERC20(_rewardsToken);
    stakingToken = IERC20(_stakingToken);

    epoch1Start = _epoch1Start;
    epochsCount = _epochsCount;
    rewardFund = _rewardFund;
    _epochs = new uint256[](_epochsCount + 1);
    totalAmountPerEpoch = _tokensPerEpoch;
  }

  // ------------------
  // SETTERS METHODS
  // ------------------

  function stake(uint256 amount) external nonReentrant {
    require(amount > 0, "stake: Amount should be bigger 0!");

    stakingToken.safeTransferFrom(msg.sender, address(this), amount);
    _balances[msg.sender] = _balances[msg.sender].add(amount);

    uint256 currentEpoch = getCurrentEpoch();
    uint256 currentMultiplier = getCurrentEpochMultiplier();

    if (!epochIsInitialized(currentEpoch)) {
      _manualEpochInit(currentEpoch);
    }

    Pool storage pNextEpoch = _poolSize[currentEpoch + 1];
    pNextEpoch.size = stakingToken.balanceOf(address(this));
    pNextEpoch.set = true;

    Checkpoint[] storage checkpoints = _balanceCheckpoints[msg.sender];
    uint256 balanceBefore = getEpochUserBalance(msg.sender, currentEpoch);

    if (checkpoints.length == 0) {
      checkpoints.push(Checkpoint(currentEpoch, currentMultiplier, 0, amount));
      checkpoints.push(Checkpoint(currentEpoch + 1, BASE_MULTIPLIER, amount, 0));
    } else {
      uint256 last = checkpoints.length - 1;

      if (checkpoints[last].epochId < currentEpoch) {
        uint256 multiplier = computeNewMultiplier(
        _getCheckpointBalance(checkpoints[last]),
          BASE_MULTIPLIER,
          amount,
          currentMultiplier
        );
        checkpoints.push(Checkpoint(currentEpoch, multiplier, _getCheckpointBalance(checkpoints[last]), amount));
        checkpoints.push(Checkpoint(currentEpoch + 1, BASE_MULTIPLIER, _balances[msg.sender], 0));
      } else if (checkpoints[last].epochId == currentEpoch) {
        checkpoints[last].multiplier = computeNewMultiplier(
          _getCheckpointBalance(checkpoints[last]),
          checkpoints[last].multiplier,
          amount,
          currentMultiplier
        );
        checkpoints[last].newDeposits = checkpoints[last].newDeposits.add(amount);
        checkpoints.push(Checkpoint(currentEpoch + 1, BASE_MULTIPLIER, _balances[msg.sender], 0));
      } else {
        if (last >= 1 && checkpoints[last - 1].epochId == currentEpoch) {
          checkpoints[last - 1].multiplier = computeNewMultiplier(
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

    uint256 balanceAfter = getEpochUserBalance(msg.sender, currentEpoch);
    _poolSize[currentEpoch].size = _poolSize[currentEpoch].size.add(balanceAfter.sub(balanceBefore));

    emit Deposit(msg.sender, amount);
  }

  function withdraw(uint256 amount) public nonReentrant {
    require(_balances[msg.sender] >= amount, "withdraw: Not enough balance!");

    _balances[msg.sender] = _balances[msg.sender].sub(amount);
    stakingToken.safeTransfer(msg.sender, amount);

    uint256 currentEpoch = getCurrentEpoch();
    lastWithdrawEpochId = currentEpoch;

    if (!epochIsInitialized(currentEpoch)) {
      _manualEpochInit(currentEpoch);
    }

    Pool storage pNextEpoch = _poolSize[currentEpoch + 1];
    pNextEpoch.size = stakingToken.balanceOf(address(this));
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
        currentEpochCheckpoint.multiplier = computeNewMultiplier(
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
    require((getCurrentEpoch() - lastWithdrawEpochId) >= 10, "emergencyWithdraw: At least 10 epochs must pass without success!");

    uint256 totalUserBalance = _balances[msg.sender];
    require(totalUserBalance > 0, "emergencyWithdraw: Amount must be > 0!");

    _balances[msg.sender] = 0;
    stakingToken.safeTransfer(msg.sender, totalUserBalance);

    emit EmergencyWithdraw(msg.sender, totalUserBalance);
  }

  function claimReward(uint256 epochId) public nonReentrant returns (uint256) {
    require(getCurrentEpoch() > epochId, "claimReward: Provided epoch is in the future!");
    require(_lastEpochIdRewarded[msg.sender].add(1) == epochId, "claimReward: Reward in order!");

    uint256 userReward = _rewardsAmount(epochId);
    if (userReward > 0) {
      rewardsToken.safeTransferFrom(rewardFund, msg.sender, userReward);
    }

    emit RewardsPaid(msg.sender, epochId, userReward);

    return userReward;
  }

  function massRewards() external returns (uint256) {
    uint256 totalDistributedValue;
    uint256 epochId = getCurrentEpoch().sub(1);

    if (epochId > epochsCount) {
      epochId = epochsCount;
    }

    for (uint256 i = _lastEpochIdRewarded[msg.sender] + 1; i <= epochId; i++) {
      totalDistributedValue = totalDistributedValue.add(_rewardsAmount(i));
    }

    emit MassRewardsPaid(msg.sender, epochId - _lastEpochIdRewarded[msg.sender], totalDistributedValue);

    if (totalDistributedValue > 0) {
      rewardsToken.safeTransferFrom(rewardFund, msg.sender, totalDistributedValue);
    }

    return totalDistributedValue;
  }

  // ------------------
  // GETTERS METHODS
  // ------------------

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

  function getEpochPoolSize(uint256 epochId) public view returns (uint256) {
    if (epochIsInitialized(epochId)) {
      return _poolSize[epochId].size;
    }

    if (!epochIsInitialized(0)) {
      return 0;
    }

    return stakingToken.balanceOf(address(this));
  }

  function getCurrentEpochMultiplier() public view returns (uint256) {
    uint256 currentEpoch = getCurrentEpoch();
    uint256 currentEpochEnd = epoch1Start.add(currentEpoch.mul(EPOCH_DELAY));
    uint256 timeLeft = currentEpochEnd.sub(block.timestamp);
    uint256 multiplier = uint256(timeLeft.mul(BASE_MULTIPLIER).div(EPOCH_DELAY));

    return multiplier;
  }

  function computeNewMultiplier(uint256 prevBalance, uint256 prevMultiplier, uint256 amount, uint256 currentMultiplier) public pure returns (uint256) {
    uint256 prevAmount = prevBalance.mul(prevMultiplier).div(BASE_MULTIPLIER);
    uint256 addAmount = amount.mul(currentMultiplier).div(BASE_MULTIPLIER);
    uint256 newMultiplier = prevAmount.add(addAmount).mul(BASE_MULTIPLIER).div(prevBalance.add(amount));

    return newMultiplier;
  }

  function epochIsInitialized(uint256 epochId) public view returns (bool) {
    return _poolSize[epochId].set;
  }

  function getEpochUserBalance(address user, uint256 epochId) public view returns (uint256) {
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

  function getCurrentEpoch() public view returns (uint256) {
    if (block.timestamp < epoch1Start) {
      return 0;
    }

    return block.timestamp.sub(epoch1Start).div(EPOCH_DELAY).add(1);
  }

  // ------------------
  // INTERNAL METHODS
  // ------------------

  function _initEpoch(uint256 epochId) internal {
    require(lastInitializedEpoch.add(1) == epochId, "_initEpoch: Epoch can be init only in order!");

    lastInitializedEpoch = epochId;
    _epochs[epochId] = getEpochPoolSize(epochId);
  }

  function _manualEpochInit(uint256 epochId) internal {
    require(epochId <= getCurrentEpoch(), "_manualEpochInit: Can't init a future epoch!");
    require(epochId <= epochsCount, "_manualEpochInit: Should be less from max epochs count!");

    Pool storage pool = _poolSize[epochId];

    if (epochId == 0) {
      pool.size = 0;
      pool.set = true;
    } else {
      require(!epochIsInitialized(epochId), "_manualEpochInit: epoch already initialized");
      require(epochIsInitialized(epochId - 1), "_manualEpochInit: previous epoch not initialized");

      pool.size = _poolSize[epochId - 1].size;
      pool.set = true;
    }

    emit ManualEpochInit(msg.sender, epochId);
  }

  function _rewardsAmount(uint256 epochId) internal returns (uint256) {
    if (lastInitializedEpoch < epochId) {
      _initEpoch(epochId);
    }

    _lastEpochIdRewarded[msg.sender] = epochId;

    if (_epochs[epochId] == 0) {
      return 0;
    }

    return totalAmountPerEpoch.mul(getEpochUserBalance(msg.sender, epochId + 1)).div(_epochs[epochId]);
  }

  function _getCheckpointEffectiveBalance(Checkpoint memory checkpoint) internal pure returns (uint256) {
    return _getCheckpointBalance(checkpoint).mul(checkpoint.multiplier).div(BASE_MULTIPLIER);
  }

  function _getCheckpointBalance(Checkpoint memory checkpoint) internal pure returns (uint256) {
    return checkpoint.startBalance.add(checkpoint.newDeposits);
  }
}