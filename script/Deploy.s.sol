// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-deploy/DeployScript.sol";
import "generated/deployer/DeployerFunctions.g.sol";

import {console} from "forge-std/console.sol";

contract Deploy is DeployScript {
    using DeployerFunctions for Deployer;

    mapping(string => mapping(string => address)) public addresses;

    constructor() {
        addresses["base"]["PositionManager"] = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
        addresses["base"]["PoolManager"] = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

        addresses["base-sepolia"]["PositionManager"] = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
        addresses["base-sepolia"]["PoolManager"] = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    }

    struct Contracts {
        NGUToken nguToken;
        NGUGlyph nguGlyph;
    }

    function deploy() external sync returns (Contracts memory res) {
        VmSafe.Chain memory chain = vmSafe.getChain(block.chainid);
        address poolManager = addresses[chain.name]["PoolManager"];

        res.nguGlyph = deployer.deploy_NGUGlyph("NGUGlyph", msg.sender);
        res.nguToken = deployer.deploy_NGUToken("NGUToken", msg.sender, 1_000 ether, poolManager, address(res.nguGlyph));
    }

    modifier sync() {
        _;

        bool isScript = vmSafe.isContext(VmSafe.ForgeContext.ScriptGroup);
        if (!isScript) return;

        string[] memory command = new string[](2);
        command[0] = "./forge-deploy";
        command[1] = "sync";
        bytes memory output = vmSafe.ffi(command);
        console.log(string(output));
    }
}
