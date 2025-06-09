// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-deploy/DeployScript.sol";
import {console} from "forge-std/console.sol";
import "generated/deployer/DeployerFunctions.g.sol";

import {Actions as UniswapActions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {IPoolManager, PoolKey, Currency, IHooks} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {CreatePoolAndAddLiquidityScript} from "../utils/CreatePoolAndAddLiquidity.s.sol";
import {AddressRegistry} from "../utils/AddressRegistry.sol";

contract Deploy is DeployScript, AddressRegistry, CreatePoolAndAddLiquidityScript {
    using DeployerFunctions for Deployer;

    struct DeployResponse {
        NGUToken nguToken;
        NGUGlyph nguGlyph;
        IHooks hooks;
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

        bytes32 hookSalt = _mineHookAddressSalt(poolManager, address(res.nguToken));
        res.hooks = deployer.deploy_UniswapHook(
            "UniswapHook", IPoolManager(poolManager), res.nguToken, DeployOptions({salt: uint256(hookSalt)})
        );

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(res.nguToken)),
            fee: 10_000, // 1%
            tickSpacing: 60,
            hooks: res.hooks
        });

        vm.startBroadcast(admin);
        res.nguGlyph.grantRole(keccak256("COMPTROLLER_ROLE"), address(res.nguToken));
        res.nguToken.grantRole(keccak256("COMPTROLLER_ROLE"), address(res.hooks));
        res.nguToken.setPoolParams(poolKey.fee, poolKey.tickSpacing, poolKey.hooks);
        vm.stopBroadcast();

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

    function _mineHookAddressSalt(address poolManager, address nguToken) internal view returns (bytes32 salt) {
        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(poolManager, nguToken);
        address CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
        ( /* address hookAddress */ , salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(UniswapHook).creationCode, constructorArgs);
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
