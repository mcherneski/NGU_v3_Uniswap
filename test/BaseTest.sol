// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, Vm, console} from "forge-std/Test.sol";

contract BaseTest is Test {
    Vm.Wallet internal alice = vm.createWallet("alice");
    Vm.Wallet internal bob = vm.createWallet("bob");
    Vm.Wallet internal charlie = vm.createWallet("charlie");

    function setUp() public virtual {
    }
}
