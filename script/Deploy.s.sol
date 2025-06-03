// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-deploy/DeployScript.sol";

import "generated/deployer/DeployerFunctions.g.sol";
import "./CreatePoolAndAddLiquidity.s.sol";
import {Actions as UniswapActions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {IPoolManager, PoolKey, Currency, IHooks} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {console} from "forge-std/console.sol";

contract Deploy is DeployScript, CreatePoolAndAddLiquidityScript {
    using DeployerFunctions for Deployer;

    mapping(string => mapping(string => address)) public addresses;

    constructor() {
        addresses["base"]["PositionManager"] = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
        addresses["base"]["PoolManager"] = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
        addresses["base"]["Permit2"] = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

        addresses["base-sepolia"]["PositionManager"] = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
        addresses["base-sepolia"]["PoolManager"] = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
        addresses["base-sepolia"]["Permit2"] = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    }

    struct DeployResponse {
        NGUToken nguToken;
        NGUGlyph nguGlyph;
        PoolKey poolKey;
    }

    function deploy() public returns (DeployResponse memory res) {
        uint256 privateKey = vm.envUint("DEPLOYER_PK");
        return deploy(vm.addr(privateKey));
    }

    function deploy(address admin) public sync returns (DeployResponse memory res) {
        address poolManager = getAddress("PoolManager");
        address permit2 = getAddress("Permit2");
        address positionManager = getAddress("PositionManager");

        res.nguGlyph = deployer.deploy_NGUGlyph("NGUGlyph", admin);
        res.nguToken = deployer.deploy_NGUToken("NGUToken", admin, 1_000 ether, poolManager, address(res.nguGlyph));

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(res.nguToken)),
            fee: 10_000, // 1%
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.broadcast(admin);
        res.nguToken.setPoolParams(poolKey.fee, poolKey.tickSpacing, poolKey.hooks);

        CreatePoolAndAddLiquidityScript.Args memory args;
        args.permit2 = IAllowanceTransfer(permit2);
        args.posm = IPositionManager(positionManager);
        args.poolKey = poolKey;
        args.tickLower = -600;
        args.tickUpper = 600;
        args.amount0 = 100 ether;
        args.amount1 = 100 ether;
        _createPoolAndAddLiquidity(admin, args);
    }

    function getAddress(string memory name) public view returns (address) {
        VmSafe.Chain memory chain = vmSafe.getChain(block.chainid);
        return addresses[chain.name][name];
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
