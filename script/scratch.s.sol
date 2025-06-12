// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPoolManager, PoolKey, Currency, IHooks} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {PoolActions} from "./PoolActions.s.sol";
import {AddressRegistry} from "../utils/AddressRegistry.sol";
import {NGUToken} from "../src/NGUToken.sol";
import {Swaps} from "./Swaps.sol";

contract Scratch is Script, AddressRegistry, Swaps, PoolActions {
    // Change to address performing the action - used to receive tokens
    address internal me = 0x15947d946D723a8524229afc42b4F116F2b0874B;

    NGUToken internal token = NGUToken(0x5f73ae7acD022e14bf127018Eba5f308A8F99251);
    PoolKey internal poolKey = PoolKey({
        currency0: Currency.wrap(address(0)),
        currency1: Currency.wrap(address(token)),
        fee: 10_000, // 1%
        tickSpacing: 60,
        hooks: IHooks(0x674765101B2A80425f2ca4D2F879E6BC92184040)
    });

    constructor() Swaps() {
        vm.createSelectFork("base-sepolia");

        Swaps.setUp();
    }

    function buyTokens() public {
        vm.startBroadcast();

        _swapTokens(poolKey, me, 1.5 ether);

        vm.stopBroadcast();
    }

    function sellTokens() public {
        vm.startBroadcast();

        uint128 amount = 1.99 ether;

        IAllowanceTransfer permit2 = IAllowanceTransfer(getAddress("Permit2"));
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(router), uint160(amount), type(uint48).max);

        _swapTokens(poolKey, me, -int128(amount));

        vm.stopBroadcast();
    }

    function addLiquidity() public {
        vm.startBroadcast();

        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 amount0 = 1 ether;
        uint256 amount1 = 300_000_000 ether;
        bytes[] memory params = new bytes[](1);
        params[0] = addLiquidity(me, poolKey, tickLower, tickUpper, amount0, amount1, "");

        executePoolActions(poolKey, params, amount0);

        vm.stopBroadcast();
    }

    function burnPosition() public {
        vm.startBroadcast();

        uint256 tokenId = 1396;
        uint128 amount0Min = 0;
        uint128 amount1Min = 0;

        bytes[] memory params = new bytes[](1);
        params[0] = burnPosition(tokenId, amount0Min, amount1Min, "");

        executePoolActions(poolKey, params, 0);

        vm.stopBroadcast();
    }
}
