// SPDX-License-Identifier: Unlicense

pragma solidity ^0.7.3;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IGlobalEpoch.sol";


contract GlobalFlexiblePool is ReentrancyGuard {
  using SafeMath for uint256;

  uint256 constant private BASE_MULTIPLIER = 1 ether;

  IGlobalEpoch internal globalEpoch;

  mapping(address => mapping(address => uint256)) private balances;

  struct Pool {
    uint256 size;
    bool set;
  }

  mapping(address => mapping(uint256 => Pool)) private poolSize;

  struct Checkpoint {
    uint256 epochId;
    uint256 multiplier;
    uint256 startBalance;
    uint256 newDeposits;
  }

  mapping(address => uint256) private lastWithdrawEpochId;
  mapping(address => mapping(address => Checkpoint[])) private balanceCheckpoints;

  event Deposit(address indexed user, address indexed tokenAddress, uint256 amount);
  event Withdraw(address indexed user, address indexed tokenAddress, uint256 amount);
  event ManualEpochInit(address indexed caller, uint256 indexed epochId, address[] tokens);
  event EmergencyWithdraw(address indexed user, address indexed tokenAddress, uint256 amount);


  // ------------------
  // CONSTRUCTOR
  // ------------------


  constructor(address _globalEpoch) public {
    globalEpoch = IGlobalEpoch(_globalEpoch);
  }


  // ------------------
  // SETTERS METHODS
  // ------------------


  function deposit(address tokenAddress, uint256 amount) public nonReentrant {
    require(amount > 0, "deposit: Amount must be > 0!");

    IERC20 token = IERC20(tokenAddress);
    uint256 allowance = token.allowance(msg.sender, address(this));
    require(allowance >= amount, "deposit: Token allowance too small!");

    balances[msg.sender][tokenAddress] = balances[msg.sender][tokenAddress].add(amount);
    token.transferFrom(msg.sender, address(this), amount);

    // epoch logic
    uint256 currentEpoch = globalEpoch.getCurrentEpoch();
    uint256 currentMultiplier = currentEpochMultiplier();

    if (!epochIsInitialized(tokenAddress, currentEpoch)) {
      address[] memory tokens = new address[](1);
      tokens[0] = tokenAddress;
      manualEpochInit(tokens, currentEpoch);
    }

    // update the next epoch pool size
    Pool storage pNextEpoch = poolSize[tokenAddress][currentEpoch + 1];
    pNextEpoch.size = token.balanceOf(address(this));
    pNextEpoch.set = true;

    Checkpoint[] storage checkpoints = balanceCheckpoints[msg.sender][tokenAddress];

    uint256 balanceBefore = getEpochUserBalance(msg.sender, tokenAddress, currentEpoch);

    // if there's no checkpoint yet, it means the user didn't have any activity
    // we want to store checkpoints both for the current epoch and next epoch because
    // if a user does a withdraw, the current epoch can also be modified and
    // we don't want to insert another checkpoint in the middle of the array as that could be expensive
    if (checkpoints.length == 0) {
      checkpoints.push(Checkpoint(currentEpoch, currentMultiplier, 0, amount));

      // next epoch => multiplier is 1, epoch deposits is 0
      checkpoints.push(Checkpoint(currentEpoch + 1, BASE_MULTIPLIER, amount, 0));
    } else {
      uint256 last = checkpoints.length - 1;

      // the last action happened in an older epoch (e.g. a deposit in epoch 3, current epoch is >=5)
      if (checkpoints[last].epochId < currentEpoch) {
        uint256 multiplier = computeNewMultiplier(
          _getCheckpointBalance(checkpoints[last]),
          BASE_MULTIPLIER,
          amount,
          currentMultiplier
        );
        checkpoints.push(Checkpoint(currentEpoch, multiplier, _getCheckpointBalance(checkpoints[last]), amount));
        checkpoints.push(Checkpoint(currentEpoch + 1, BASE_MULTIPLIER, balances[msg.sender][tokenAddress], 0));
      }
      // the last action happened in the previous epoch
      else if (checkpoints[last].epochId == currentEpoch) {
        checkpoints[last].multiplier = computeNewMultiplier(
          _getCheckpointBalance(checkpoints[last]),
          checkpoints[last].multiplier,
          amount,
          currentMultiplier
        );
        checkpoints[last].newDeposits = checkpoints[last].newDeposits.add(amount);

        checkpoints.push(Checkpoint(currentEpoch + 1, BASE_MULTIPLIER, balances[msg.sender][tokenAddress], 0));
      }
      // the last action happened in the current epoch
      else {
        if (last >= 1 && checkpoints[last - 1].epochId == currentEpoch) {
          checkpoints[last - 1].multiplier = computeNewMultiplier(
            _getCheckpointBalance(checkpoints[last - 1]),
            checkpoints[last - 1].multiplier,
            amount,
            currentMultiplier
          );
          checkpoints[last - 1].newDeposits = checkpoints[last - 1].newDeposits.add(amount);
        }

        checkpoints[last].startBalance = balances[msg.sender][tokenAddress];
      }
    }

    uint256 balanceAfter = getEpochUserBalance(msg.sender, tokenAddress, currentEpoch);
    poolSize[tokenAddress][currentEpoch].size = poolSize[tokenAddress][currentEpoch].size.add(balanceAfter.sub(balanceBefore));

    emit Deposit(msg.sender, tokenAddress, amount);
  }

  function withdraw(address tokenAddress, uint256 amount) public nonReentrant {
    require(amount > 0, "withdraw: Amount must be > 0!");
    require(balances[msg.sender][tokenAddress] >= amount, "withdraw: Balance too small!");

    balances[msg.sender][tokenAddress] = balances[msg.sender][tokenAddress].sub(amount);

    IERC20 token = IERC20(tokenAddress);
    token.transfer(msg.sender, amount);

    // epoch logic
    uint256 currentEpoch = globalEpoch.getCurrentEpoch();
    lastWithdrawEpochId[tokenAddress] = currentEpoch;

    if (!epochIsInitialized(tokenAddress, currentEpoch)) {
      address[] memory tokens = new address[](1);
      tokens[0] = tokenAddress;
      manualEpochInit(tokens, currentEpoch);
    }

    // update the pool size of the next epoch to its current balance
    Pool storage pNextEpoch = poolSize[tokenAddress][currentEpoch + 1];
    pNextEpoch.size = token.balanceOf(address(this));
    pNextEpoch.set = true;

    Checkpoint[] storage checkpoints = balanceCheckpoints[msg.sender][tokenAddress];
    uint256 last = checkpoints.length - 1;

    // note: it's impossible to have a withdraw and no checkpoints because the balance would be 0 and revert

    // there was a deposit in an older epoch (more than 1 behind [eg: previous 0, now 5]) but no other action since then
    if (checkpoints[last].epochId < currentEpoch) {
      checkpoints.push(Checkpoint(currentEpoch, BASE_MULTIPLIER, balances[msg.sender][tokenAddress], 0));

      poolSize[tokenAddress][currentEpoch].size = poolSize[tokenAddress][currentEpoch].size.sub(amount);
    }
    // there was a deposit in the `epochId - 1` epoch => we have a checkpoint for the current epoch
    else if (checkpoints[last].epochId == currentEpoch) {
      checkpoints[last].startBalance = balances[msg.sender][tokenAddress];
      checkpoints[last].newDeposits = 0;
      checkpoints[last].multiplier = BASE_MULTIPLIER;

      poolSize[tokenAddress][currentEpoch].size = poolSize[tokenAddress][currentEpoch].size.sub(amount);
    }
    // there was a deposit in the current epoch
    else {
      Checkpoint storage currentEpochCheckpoint = checkpoints[last - 1];

      uint256 balanceBefore = _getCheckpointEffectiveBalance(currentEpochCheckpoint);

      // in case of withdraw, we have 2 branches:
      // 1. the user withdraws less than he added in the current epoch
      // 2. the user withdraws more than he added in the current epoch (including 0)
      if (amount < currentEpochCheckpoint.newDeposits) {
        uint256 avgDepositMultiplier = balanceBefore.sub(currentEpochCheckpoint.startBalance).mul(BASE_MULTIPLIER).div(currentEpochCheckpoint.newDeposits);

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
      poolSize[tokenAddress][currentEpoch].size = poolSize[tokenAddress][currentEpoch].size.sub(balanceBefore.sub(balanceAfter));
      checkpoints[last].startBalance = balances[msg.sender][tokenAddress];
    }

    emit Withdraw(msg.sender, tokenAddress, amount);
  }

  function manualEpochInit(address[] memory tokens, uint256 epochId) public {
    require(epochId <= globalEpoch.getCurrentEpoch(), "manualEpochInit: Can't init a future epoch!");

    for (uint256 i = 0; i < tokens.length; i++) {
      Pool storage p = poolSize[tokens[i]][epochId];

      if (epochId > 0) {
        require(!epochIsInitialized(tokens[i], epochId), "manualEpochInit: epoch already initialized!");
        require(epochIsInitialized(tokens[i], epochId - 1), "manualEpochInit: previous epoch not initialized!");
      }

      p.set = true;
      p.size = epochId == 0 ? 0 : poolSize[tokens[i]][epochId - 1].size;
    }

    emit ManualEpochInit(msg.sender, epochId, tokens);
  }

  function emergencyWithdraw(address tokenAddress) public {
    require((globalEpoch.getCurrentEpoch() - lastWithdrawEpochId[tokenAddress]) >= 10, "emergencyWithdraw: At least 10 epochs must pass without success!");

    uint256 totalUserBalance = balances[msg.sender][tokenAddress];
    require(totalUserBalance > 0, "emergencyWithdraw: Amount must be > 0!");

    balances[msg.sender][tokenAddress] = 0;
    IERC20(tokenAddress).transfer(msg.sender, totalUserBalance);

    emit EmergencyWithdraw(msg.sender, tokenAddress, totalUserBalance);
  }


  // ------------------
  // GETTERS METHODS
  // ------------------


  function getEpochUserBalance(address user, address token, uint256 epochId) public view returns (uint256) {
    Checkpoint[] storage checkpoints = balanceCheckpoints[user][token];

    // if there are no checkpoints, it means the user never deposited any tokens, so the balance is 0
    if (checkpoints.length == 0 || epochId < checkpoints[0].epochId) {
      return 0;
    }

    uint256 min = 0;
    uint256 max = checkpoints.length - 1;

    // shortcut for blocks newer than the latest checkpoint == current balance
    if (epochId >= checkpoints[max].epochId) {
      return _getCheckpointEffectiveBalance(checkpoints[max]);
    }

    // binary search of the value in the array
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

  function balanceOf(address user, address token) public view returns (uint256) {
    return balances[user][token];
  }

  function getEpochPoolSize(address tokenAddress, uint256 epochId) public view returns (uint256) {
    // Premises:
    // 1. it's impossible to have gaps of uninitialized epochs
    // - any deposit or withdraw initialize the current epoch which requires the previous one to be initialized
    if (epochIsInitialized(tokenAddress, epochId)) {
      return poolSize[tokenAddress][epochId].size;
    }

    // epochId not initialized and epoch 0 not initialized => there was never any action on this pool
    if (!epochIsInitialized(tokenAddress, 0)) {
      return 0;
    }

    // epoch 0 is initialized => there was an action at some point but none that initialized the epochId
    // which means the current pool size is equal to the current balance of token held by the staking contract
    return IERC20(tokenAddress).balanceOf(address(this));
  }

  function currentEpochMultiplier() public view returns (uint256) {
    uint256 timeLeft = globalEpoch.getSecondsUntilNextEpoch();
    uint256 multiplier = timeLeft * BASE_MULTIPLIER / globalEpoch.getEpochDelay();

    return multiplier;
  }

  function computeNewMultiplier(uint256 prevBalance, uint256 prevMultiplier, uint256 amount, uint256 currentMultiplier) public pure returns (uint256) {
    uint256 prevAmount = prevBalance.mul(prevMultiplier).div(BASE_MULTIPLIER);
    uint256 addAmount = amount.mul(currentMultiplier).div(BASE_MULTIPLIER);
    uint256 newMultiplier = prevAmount.add(addAmount).mul(BASE_MULTIPLIER).div(prevBalance.add(amount));

    return newMultiplier;
  }

  function epochIsInitialized(address token, uint256 epochId) public view returns (bool) {
    return poolSize[token][epochId].set;
  }


  // ------------------
  // INTERNAL METHODS
  // ------------------


  function _getCheckpointBalance(Checkpoint memory c) internal pure returns (uint256) {
    return c.startBalance.add(c.newDeposits);
  }

  function _getCheckpointEffectiveBalance(Checkpoint memory c) internal pure returns (uint256) {
    return _getCheckpointBalance(c).mul(c.multiplier).div(BASE_MULTIPLIER);
  }
}