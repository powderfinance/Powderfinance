// SPDX-License-Identifier: Unlicense

pragma solidity ^0.7.3;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";


contract PoolsFactory is AccessControl {
  using SafeMath for uint256;
  using Clones for address;

  address internal _poolContractTemplate;
  bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE");

  struct Pool {
    address token;
  }


  event NewInstance(address instance);

  mapping(address => Pool) internal _pools;


  constructor(address templateAddress, address admin, address poolCreator) public {
    _poolContractTemplate = templateAddress;

    _setupRole(DEFAULT_ADMIN_ROLE, admin);
    _setupRole(GOVERNANCE_ROLE, poolCreator);
  }


  function createPool(
    address token,
    uint256 oracle,
    uint256 reward
  ) external {
    require(hasRole(GOVERNANCE_ROLE, _msgSender()), "createPool: must have pool creator role to create");

    address newPool = _poolContractTemplate.clone();
  }

}