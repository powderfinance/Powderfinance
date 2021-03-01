// SPDX-License-Identifier: Unlicense

pragma solidity ^0.7.3;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";


contract Powder is ERC20Burnable {
    using SafeMath for uint256;

    uint256 public constant TOTAL_SUPPLY = 10000000 ether;

    constructor(address receiver) public ERC20("Powder", "POWDER") {
        _mint(receiver, TOTAL_SUPPLY);
    }
}
