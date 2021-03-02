// SPDX-License-Identifier: Unlicense

pragma solidity ^0.7.3;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract RewardFund is AccessControl {
  using SafeERC20 for IERC20;

  IERC20 internal _powder;

  mapping(address => uint256) internal _rewards;

  bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE");

  event RewardApproved(address pool, uint256 amount);
  event RewardChanged(address pool, uint256 prevAmount, uint256 newAmount);

  // ------------------
  // CONSTRUCTOR
  // ------------------

  constructor(
    address admin,
    address powder,
    address governance
  ) public {
    _powder = IERC20(powder);

    _setupRole(DEFAULT_ADMIN_ROLE, admin);
    _setupRole(GOVERNANCE_ROLE, governance);
  }

  // ------------------
  // SETTERS
  // ------------------

  function approveRewards(address pool, uint256 amount) public {
    require(hasRole(GOVERNANCE_ROLE, msg.sender), "approveRewards: Only governance can call this method!");
    require(_rewards[pool] == 0, "modifyReward: This pool already has approved rewards!");

    _rewards[pool] = amount;
    _powder.safeApprove(pool, amount);

    emit RewardApproved(pool, amount);
  }

  function modifyReward(address pool, uint256 newAmount) public {
    require(hasRole(GOVERNANCE_ROLE, msg.sender), "modifyReward: Only governance can call this method!");
    require(_rewards[pool] != 0, "modifyReward: This pool is not exists yet!");

    uint256 prevAmount = _rewards[pool];
    _rewards[pool] = newAmount;
    _powder.safeApprove(pool, newAmount);

    emit RewardChanged(pool, prevAmount, newAmount);
  }

  // ------------------
  // GETTERS
  // ------------------

  function getFundBalance() public view returns (uint256) {
    return _powder.balanceOf(address(this));
  }

  function getPoolRewards(address pool) public view returns (uint256, uint256) {
    uint256 availableRewards = _powder.allowance(address(this), pool);
    uint256 totalRewards = _rewards[pool];

    return (
      availableRewards, totalRewards
    );
  }
}