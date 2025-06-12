// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-deploy/DeployScript.sol";
import {console} from "forge-std/console.sol";
import "generated/deployer/DeployerFunctions.g.sol";

import {IPoolManager, PoolKey, Currency, IHooks} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {PoolActions} from "./PoolActions.s.sol";
import {AddressRegistry} from "../utils/AddressRegistry.sol";

contract Deploy is DeployScript, AddressRegistry, PoolActions {
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

    function deploy(address admin) public returns (DeployResponse memory res) {
        res = _deployContracts(admin);

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

        _setupUniswapV4(poolKey, admin);

        vm.stopBroadcast();
    }

    function _deployContracts(address admin) internal returns (DeployResponse memory res) {
        address poolManager = getAddress("PoolManager");

        res.nguGlyph = deployer.deploy_NGUGlyph("NGUGlyph", admin);
        res.nguToken =
            deployer.deploy_NGUToken("NGUToken", admin, 1_000_000_000 ether, poolManager, address(res.nguGlyph));

        bytes32 hookSalt = _mineHookAddressSalt(poolManager, address(res.nguToken));
        res.hooks = deployer.deploy_UniswapHook(
            "UniswapHook", IPoolManager(poolManager), res.nguToken, DeployOptions({salt: uint256(hookSalt)})
        );
    }

    function _mineHookAddressSalt(address poolManager, address nguToken) internal view returns (bytes32 salt) {
        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(poolManager, nguToken);
        ( /* address hookAddress */ , salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(UniswapHook).creationCode, constructorArgs);
    }

    function _setupUniswapV4(PoolKey memory poolKey, address recipient) internal {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 amount0 = 1 ether;
        uint256 amount1 = 300_000_000 ether;

        bytes[] memory params = new bytes[](2);
        params[0] = createPool(poolKey, amount0, amount1, "");
        params[1] = addLiquidity(recipient, poolKey, tickLower, tickUpper, amount0, amount1, "");

        executePoolActions(poolKey, params, amount0);
    }
}
