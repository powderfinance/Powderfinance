// SPDX-License-Identifier: Unlicense

pragma solidity ^0.7.3;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


contract LpToken is ERC20, Ownable {
  constructor (string memory name, string memory symbol) public ERC20(name, symbol) {
      // Silence
  }

  function burn(uint256 amount) public onlyOwner {
      _burn(msg.sender, amount);
  }

  function mint(address to, uint256 amount) public onlyOwner {
      _mint(to, amount);
  }
}