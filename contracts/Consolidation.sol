// SPDX-License-Identifier: Unlicense

pragma solidity ^0.7.3;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


contract Consolidation is ReentrancyGuard {
  using SafeERC20 for IERC20;
  using SafeMath for uint256;

  address internal constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  mapping(address => mapping(address => uint256)) internal _balances;

  //  ----------------
  //  DEPOSIT
  //  ----------------

  function safeKeep() external payable nonReentrant {
    require(msg.value > 0, "safeKeep: MSG value should not be 0!");

    // Increase contract deposited funds
    _balances[msg.sender][ETH_ADDRESS] = _balances[msg.sender][ETH_ADDRESS].add(msg.value);
  }

  function safeKeep(IERC20 token, uint256 amount) external nonReentrant {
    // Receive tokens from the sender address
    token.safeTransferFrom(msg.sender, address(this), amount);

    // Increase contract deposited funds
    _balances[msg.sender][address(token)] = _balances[msg.sender][address(token)].add(amount);
  }

  //  ----------------
  //  WITHDRAW
  //  ----------------

  function safeWithdraw(uint256 amount) external nonReentrant {
    require(_balances[msg.sender][ETH_ADDRESS] >= amount, "safeWithdraw: Not enough funds!");

    // Decrease contract deposited funds
    _balances[msg.sender][ETH_ADDRESS] = _balances[msg.sender][ETH_ADDRESS].sub(amount);

    // Send ETH back to the sender address
    msg.sender.transfer(amount);
  }

  function safeWithdraw(IERC20 token, uint256 amount) external nonReentrant {
    require(_balances[msg.sender][address(token)] >= amount, "safeWithdraw: Not enough funds!");

    // Decrease contract deposited funds
    _balances[msg.sender][address(token)] = _balances[msg.sender][address(token)].sub(amount);

    // Send tokens to the sender address
    token.safeTransfer(msg.sender, amount);
  }

  //  ----------------
  //  GETTERS
  //  ----------------

  function getBalance(address user, address token) external view returns (uint256) {
    return _balances[user][token];
  }
}