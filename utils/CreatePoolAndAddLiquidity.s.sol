// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

contract CreatePoolAndAddLiquidityScript is Script {
    struct Args {
        IAllowanceTransfer permit2;
        IPositionManager posm;
        PoolKey poolKey;
        /// @dev must be a multiple of tickSpacing
        int24 tickLower;
        /// @dev must be a multiple of tickSpacing
        int24 tickUpper;
        /// @dev amount of token0
        uint256 amount0;
        /// @dev amount of token1
        uint256 amount1;
    }

    function _createPoolAndAddLiquidity(address signer, Args memory args) internal {
        bytes memory hookData = new bytes(0);

        uint160 startingPrice = uint160(Math.sqrt(args.amount1 / args.amount0) * 2 ** 96);

        // Converts token amounts to liquidity units
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            startingPrice,
            TickMath.getSqrtPriceAtTick(args.tickLower),
            TickMath.getSqrtPriceAtTick(args.tickUpper),
            args.amount0,
            args.amount1
        );

        // slippage limits
        uint256 amount0Max = args.amount0 + 1 wei;
        uint256 amount1Max = args.amount1 + 1 wei;

        (bytes memory actions, bytes[] memory mintParams) = _mintLiquidityParams(
            args.poolKey, args.tickLower, args.tickUpper, liquidity, amount0Max, amount1Max, signer, hookData
        );

        // multicall parameters
        bytes[] memory params = new bytes[](2);

        // initialize pool
        params[0] = abi.encodeWithSelector(args.posm.initializePool.selector, args.poolKey, startingPrice, hookData);

        // mint liquidity
        params[1] = abi.encodeWithSelector(
            args.posm.modifyLiquidities.selector, abi.encode(actions, mintParams), block.timestamp + 1 hours
        );

        // if the pool is an ETH pair, native tokens are to be transferred
        uint256 valueToPass = args.poolKey.currency0.isAddressZero() ? amount0Max : 0;

        vm.startBroadcast(signer);

        // token approvals
        if (!args.poolKey.currency0.isAddressZero()) {
            address token0 = Currency.unwrap(args.poolKey.currency0);
            IERC20(token0).approve(address(args.permit2), type(uint256).max);
            args.permit2.approve(token0, address(args.posm), type(uint160).max, type(uint48).max);
        }
        if (!args.poolKey.currency1.isAddressZero()) {
            address token1 = Currency.unwrap(args.poolKey.currency1);
            IERC20(token1).approve(address(args.permit2), type(uint256).max);
            args.permit2.approve(token1, address(args.posm), type(uint160).max, type(uint48).max);
        }

        // multicall to atomically create pool & add liquidity
        args.posm.multicall{value: valueToPass}(params);

        vm.stopBroadcast();
    }

    /// @dev helper function for encoding mint liquidity operation
    /// @dev does NOT encode SWEEP, developers should take care when minting liquidity on an ETH pair
    function _mintLiquidityParams(
        PoolKey memory poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient,
        bytes memory hookData
    ) internal pure returns (bytes memory, bytes[] memory) {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey, _tickLower, _tickUpper, liquidity, amount0Max, amount1Max, recipient, hookData);
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        return (actions, params);
    }
}
