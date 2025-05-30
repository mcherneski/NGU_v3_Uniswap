// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "../../src/NGUToken.sol";

contract MockNGUToken is NGUToken {
    constructor(uint256 initialSupply) NGUToken(initialSupply) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(_msgSender(), amount);
    }
}
