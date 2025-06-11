// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {AddressRegistry} from "../utils/AddressRegistry.sol";

contract PoolActions is Script, AddressRegistry {
    function executePoolActions(PoolKey memory poolKey, bytes[] memory params, uint256 value) internal {
        PositionManager posm = PositionManager(payable(getAddress("PositionManager")));

        // token approvals
        IAllowanceTransfer permit2 = IAllowanceTransfer(getAddress("Permit2"));
        if (!poolKey.currency0.isAddressZero()) {
            address token0 = Currency.unwrap(poolKey.currency0);
            IERC20(token0).approve(address(permit2), type(uint256).max);
            permit2.approve(token0, address(posm), type(uint160).max, type(uint48).max);
        }
        if (!poolKey.currency1.isAddressZero()) {
            address token1 = Currency.unwrap(poolKey.currency1);
            IERC20(token1).approve(address(permit2), type(uint256).max);
            permit2.approve(token1, address(posm), type(uint160).max, type(uint48).max);
        }

        // multicall to atomically create pool & add liquidity
        posm.multicall{value: value}(params);
    }

    function calculateSqrtPriceX96(uint256 amount0, uint256 amount1) internal returns (uint160) {
        return uint160(Math.sqrt(amount1 / amount0) * 2 ** 96);
    }

    function createPool(PoolKey memory poolKey, uint256 amount0, uint256 amount1, bytes memory hookData)
        internal
        returns (bytes memory)
    {
        uint160 startingPrice = calculateSqrtPriceX96(amount0, amount1);
        PositionManager posm; // not sure why the compiler wants variable defined
        return abi.encodeWithSelector(posm.initializePool.selector, poolKey, startingPrice, hookData);
    }

    function addLiquidity(
        address recipient,
        PoolKey memory poolKey,
        /// @dev must be a multiple of tickSpacing
        int24 tickLower,
        /// @dev must be a multiple of tickSpacing
        int24 tickUpper,
        /// @dev amount of token0
        uint256 amount0,
        /// @dev amount of token1
        uint256 amount1,
        bytes memory hookData
    ) internal returns (bytes memory) {
        uint160 startingPrice = calculateSqrtPriceX96(amount0, amount1);

        // Converts token amounts to liquidity units
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            startingPrice,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        // slippage limits
        uint256 amount0Max = amount0 + 1 wei;
        uint256 amount1Max = amount1 + 1 wei;

        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));

        bool isNativeETHPosition = poolKey.currency0.isAddressZero() || poolKey.currency1.isAddressZero();

        uint256 paramsCount = 2;
        if (isNativeETHPosition) paramsCount++;
        bytes[] memory params = new bytes[](paramsCount);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, recipient, hookData);
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        if (isNativeETHPosition) params[paramsCount - 1] = abi.encode(CurrencyLibrary.ADDRESS_ZERO, recipient);

        return abi.encodeWithSelector(
            PositionManager.modifyLiquidities.selector, abi.encode(actions, params), block.timestamp + 1 hours
        );
    }

    function removeLiquidity(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes memory hookData)
        internal
        returns (bytes memory)
    {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION));

        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, hookData);

        return abi.encodeWithSelector(
            PositionManager.modifyLiquidities.selector, abi.encode(actions, params), block.timestamp + 1 hours
        );
    }
}
