// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Base.sol";

contract AddressRegistry is CommonBase {
    mapping(string => mapping(string => address)) public addresses;

    constructor() {
        addresses["base"]["PositionManager"] = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
        addresses["base"]["PoolManager"] = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
        addresses["base"]["Permit2"] = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        addresses["base"]["UniversalRouter"] = 0x6fF5693b99212Da76ad316178A184AB56D299b43;

        addresses["base-sepolia"]["PositionManager"] = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
        addresses["base-sepolia"]["PoolManager"] = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
        addresses["base-sepolia"]["Permit2"] = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        addresses["base-sepolia"]["UniversalRouter"] = 0x492E6456D9528771018DeB9E87ef7750EF184104;
    }

    error AddressNotFound(string name, uint256 chainId);

    function getAddress(string memory name) public returns (address addr) {
        VmSafe.Chain memory chain = vm.getChain(block.chainid);
        addr = addresses[chain.name][name];
        require(addr != address(0), AddressNotFound(name, block.chainid));
        vm.label(addr, name);
    }
}
