// SPDX-License-Identifier: Unlicense

pragma solidity ^0.7.3;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IConsolidation.sol";
import "./interfaces/IGlobalEpoch.sol";


contract TranchesPool is Ownable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  uint256 public constant BASE_MULTIPLIER = 1 ether;

  uint256 public epochStart;
  uint256 public epochsCount;
  uint256 public epochDuration;
  uint256 public seniorRatio = 5 * BASE_MULTIPLIER;
  uint256 public rewardPerEpoch;
  uint256 public epochDelayedFromFirst;
  address public rewardFunds;

  IERC20 internal rewardToken;
  IERC20 internal stakingToken;
  IGlobalEpoch internal globalEpoch;
  IConsolidation internal consolidation;

  enum Tranches { JUNIOR, SENIOR }

  struct Balances {
    uint256 junior;
    uint256 senior;
  }

  struct Epoch {
    bool posted;
    Balances staked;
    Balances result;
  }

  mapping(uint256 => Epoch) internal _epochs;

  struct Checkpoint {
    uint256 deposit;
    uint256 multiplier;
  }

  struct UserHistory {
    uint256 juniorBalance;
    uint256 seniorBalance;

    bool juniorRewardsClaimed;
    bool seniorRewardsClaimed;

    Checkpoint[] juniorCheckpoints;
    Checkpoint[] seniorCheckpoints;
  }

  mapping(address => mapping(uint256 => UserHistory)) internal _balances;

  event NewDeposit(address user, uint256 amount, Tranches tranche);
  event NewWithdraw(address user, uint256 amount, Tranches tranche);
  event ResultsPosted(uint256 epochId, uint256 juniorResult, uint256 seniorResult);

  // ------------------
  // CONSTRUCTOR
  // ------------------

  constructor(
    address _rewardToken,
    address _stakingToken,
    address _globalEpoch,
    address _rewardFunds,
    address _consolidation,
    uint256 _rewardPerEpoch,
    uint256 _epochsCount,
    uint256 _epochDelayedFromFirst
  ) public {
    rewardToken = IERC20(_rewardToken);
    stakingToken = IERC20(_stakingToken);
    globalEpoch = IGlobalEpoch(_globalEpoch);
    consolidation = IConsolidation(_consolidation);

    epochsCount = _epochsCount;
    epochDuration = globalEpoch.getEpochDelay();
    epochStart = globalEpoch.getFirstEpochTime() + epochDuration.mul(epochDelayedFromFirst);

    rewardFunds = _rewardFunds;
    rewardPerEpoch = _rewardPerEpoch;
    epochDelayedFromFirst = _epochDelayedFromFirst;
  }

  // ------------------
  // SETTERS
  // ------------------


  function deposit(uint256 amount, Tranches tranche) public {
    require(amount > 0, "deposit: Amount can not be 0!");

    uint256 currentEpoch = _getCurrentEpoch();
    require(currentEpoch > 0, "deposit: Not started yet!");

    Epoch storage epoch = _epochs[currentEpoch];
    UserHistory storage user = _balances[msg.sender][currentEpoch];

    if (tranche == Tranches.JUNIOR) {
      require(globalEpoch.isJuniorStakePeriod(), "deposit: Not junior stake period!");

      // Transfer tokens
      stakingToken.safeTransferFrom(msg.sender, address(this), amount);
      _safeKeep(amount);

      // Update epoch data
      epoch.staked.junior = epoch.staked.junior.add(amount);

      // Update user data
      user.juniorBalance = user.juniorBalance.add(amount);
      user.juniorCheckpoints.push(Checkpoint({
        deposit: amount,
        multiplier: _currentEpochMultiplier()
      }));
    } else if (tranche == Tranches.SENIOR) {
      require(!globalEpoch.isJuniorStakePeriod(), "deposit: Only junior tranche accepted now!");
      require(!_isSeniorLimitReached(currentEpoch, amount), "deposit: Senior pool limit is reached!");

      // Transfer tokens
      stakingToken.safeTransferFrom(msg.sender, address(this), amount);
      _safeKeep(amount);

      // Update epoch data
      epoch.staked.senior = epoch.staked.senior.add(amount);

      // Update user data
      user.seniorBalance = user.seniorBalance.add(amount);
      user.seniorCheckpoints.push(Checkpoint({
        deposit: amount,
        multiplier: _currentEpochMultiplier()
      }));
    }

    emit NewDeposit(msg.sender, amount, Tranches.SENIOR);
  }

  function withdraw(uint256 epochId, Tranches tranche) public {
    require(_getCurrentEpoch() > epochId, "withdraw: This epoch is in the future!");
    require(epochsCount >= epochId, "withdraw: Reached maximum number of epochs!");
    require(_epochs[epochId].posted, "withdraw: Results not posted!");

    uint256 withdrawAmount = _calculateWithdrawAmount(epochId, msg.sender, tranche);

    if (withdrawAmount > 0) {
      if (tranche == Tranches.SENIOR) {
        _balances[msg.sender][epochId].seniorBalance = 0;
      } else {
        _balances[msg.sender][epochId].juniorBalance = 0;
      }

      // Transfer tokens
      consolidation.safeWithdraw(address(stakingToken), withdrawAmount);
      stakingToken.safeTransfer(msg.sender, withdrawAmount);
    }

    emit NewWithdraw(msg.sender, withdrawAmount, tranche);
  }

  function clamReward(uint256 epochId, Tranches tranche) public {
    require(_getCurrentEpoch() > epochId, "clamReward: This epoch is in the future!");
    require(epochsCount >= epochId, "clamReward: Reached maximum number of epochs!");
    require(_epochs[epochId].posted, "clamReward: Results not posted!");

    uint256 availableReward = _calculateReward(epochId, msg.sender, tranche);

    if (tranche == Tranches.JUNIOR && !_balances[msg.sender][epochId].juniorRewardsClaimed) {
      _balances[msg.sender][epochId].juniorRewardsClaimed = true;
      rewardToken.safeTransferFrom(rewardFunds, msg.sender, availableReward);
    } else if (tranche == Tranches.SENIOR && !_balances[msg.sender][epochId].seniorRewardsClaimed) {
      _balances[msg.sender][epochId].seniorRewardsClaimed = true;
      rewardToken.safeTransferFrom(rewardFunds, msg.sender, availableReward);
    }
  }

  function exit(uint256 epochId, Tranches tranche) public {
    withdraw(epochId, tranche);
    clamReward(epochId, tranche);
  }

  function postResults(uint256 epochId, uint256 juniorResult, uint256 seniorResult) public onlyOwner {
    require(_getCurrentEpoch() > epochId, "postResults: This epoch is in the future!");
    require(epochsCount >= epochId, "postResults: Reached maximum number of epochs!");
    require(globalEpoch.isJuniorStakePeriod(), "postResults: Not results posting period!");

    Epoch storage epoch = _epochs[epochId];
    require(!epoch.posted, "postResults: Already posted!");
    require(juniorResult.add(seniorResult) == epoch.staked.junior.add(epoch.staked.senior), "postResults: Results and actual size should be the same!");

    epoch.posted = true;
    epoch.result.junior = juniorResult;
    epoch.result.senior = seniorResult;

    emit ResultsPosted(epochId, juniorResult, seniorResult);
  }

  function changeRewardsPerEpoch(uint256 newRewards) public onlyOwner {
    rewardPerEpoch = newRewards;
  }


  // ------------------
  // GETTERS
  // ------------------

  function getEpochData(uint256 epochId) public view returns (
    uint256 juniorStaked,
    uint256 seniorStaked,
    uint256 juniorResult,
    uint256 seniorResult
  ) {
    Epoch memory _epoch = _epochs[epochId];
    return (
      _epoch.staked.junior,
      _epoch.staked.senior,
      _epoch.result.junior,
      _epoch.result.senior
    );
  }

  function getUserBalances(address userAddress, uint256 epochId) public view returns (
    uint256 juniorStaked,
    uint256 seniorStaked
  ) {
    return (
      _balances[userAddress][epochId].juniorBalance,
      _balances[userAddress][epochId].seniorBalance
    );
  }

  function getAvailableReward(uint256 epochId, address userAddress, Tranches tranche) public view returns (uint256) {
    if (tranche == Tranches.JUNIOR && _balances[userAddress][epochId].juniorRewardsClaimed) {
      return 0;
    }

    if (tranche == Tranches.SENIOR && _balances[userAddress][epochId].seniorRewardsClaimed) {
      return 0;
    }

    return _calculateReward(epochId, userAddress, tranche);
  }

  function currentEpochMultiplier() public view returns (uint256) {
    return _currentEpochMultiplier();
  }

  // ------------------
  // INTERNAL
  // ------------------

  function _getCurrentEpoch() internal view returns (uint256) {
    if (block.timestamp < epochStart) {
      return 0;
    }

    return block.timestamp.sub(epochStart).div(epochDuration).add(1);
  }

  function _calculateWithdrawAmount(uint256 epochId, address userAddress, Tranches tranche) internal view returns (uint256) {
    Epoch memory epoch = _epochs[epochId];
    UserHistory memory user = _balances[userAddress][epochId];

    uint256 poolSize;
    uint256 poolResult;
    uint256 userStake;

    if (tranche == Tranches.JUNIOR) {
      poolSize = epoch.staked.junior;
      poolResult = epoch.result.junior;
      userStake = user.juniorBalance;
    } else if (tranche == Tranches.SENIOR) {
      poolSize = epoch.staked.senior;
      poolResult = epoch.result.senior;
      userStake = user.seniorBalance;
    }

    uint256 diff = poolResult.mul(BASE_MULTIPLIER).div(poolSize.div(100));
    uint256 amount = userStake.mul(diff).div(100).div(BASE_MULTIPLIER);

    return amount;
  }

  function _isSeniorLimitReached(uint256 epochId, uint256 amount) internal view returns (bool) {
    uint256 juniorStaked = _epochs[epochId].staked.junior;
    uint256 seniorStaked = _epochs[epochId].staked.senior;

    return seniorStaked.add(amount).mul(BASE_MULTIPLIER) > juniorStaked.mul(seniorRatio);
  }

  function _currentEpochMultiplier() internal view returns (uint256) {
    uint256 timeLeft = globalEpoch.getSecondsUntilNextEpoch();
    uint256 multiplier = timeLeft.mul(BASE_MULTIPLIER).div(globalEpoch.getEpochDelay());

    return multiplier;
  }

  function _calculateReward(uint256 epochId, address userAddress, Tranches tranche) internal view returns (uint256) {
    uint256 epochPoolSize;
    uint256 availableReward;
    Checkpoint[] memory checkpoints;

    if (tranche == Tranches.JUNIOR) {
      epochPoolSize = _epochs[epochId].staked.junior;
      checkpoints = _balances[userAddress][epochId].juniorCheckpoints;
    } else if (tranche == Tranches.SENIOR) {
      epochPoolSize = _epochs[epochId].staked.senior;
      checkpoints = _balances[userAddress][epochId].seniorCheckpoints;
    }

    for (uint256 i = 0; i < checkpoints.length; i++) {
      uint256 effectiveAmount = checkpoints[i].deposit.mul(checkpoints[i].multiplier).div(BASE_MULTIPLIER);
      availableReward = availableReward.add(rewardPerEpoch.mul(effectiveAmount).div(epochPoolSize));
    }

    return availableReward;
  }

  function _safeKeep(uint256 amount) internal {
    stakingToken.safeApprove(address(consolidation), amount);
    consolidation.safeKeep(address(stakingToken), amount);
    stakingToken.safeApprove(address(consolidation), 0);
  }
}