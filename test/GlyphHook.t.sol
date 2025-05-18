// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

// Local imports
import {GlyphMintingHook} from "../src/GlyphMintingHook.sol";
import {NumberGoUp} from "../src/NumberGoUp.sol";

// Import the base setup contract
import {BaseGlyphHookTestSetup} from "./utils/BaseGlyphHookTestSetup.sol";

contract GlyphHookTest is BaseGlyphHookTestSetup {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    function setUp() public override {
        _commonSetUp();
        // console2.log("GlyphHookTest: setUp() completed after _commonSetUp().");
    }

    function test_GlyphMinting_OnSwap() public {
        uint256 initialGlyphBalance = ngu.glyphBalanceOf(alice);
        uint256 initialNGUBalance = ngu.balanceOf(alice);
        uint256 initialWETHBalance = weth.balanceOf(alice);
        
        bool zeroForOne = address(weth) < address(ngu);
        int256 amountSpecified = -1e18;
        uint160 sqrtPriceLimitX96 = zeroForOne ? 
            TickMath.MIN_SQRT_PRICE + 1 : 
            TickMath.MAX_SQRT_PRICE - 1;

        vm.startPrank(alice);
        BalanceDelta swapDelta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            abi.encode(alice)
        );
        vm.stopPrank();

        uint256 nguReceived = zeroForOne ? uint256(int256(swapDelta.amount1())) : uint256(int256(swapDelta.amount0()));
        uint256 expectedGlyphIncrease = nguReceived / UNITS;
        uint256 wethSpent = zeroForOne ? uint256(int256(swapDelta.amount0()) * -1) : uint256(int256(swapDelta.amount1()) * -1);

        assertEq(
            ngu.glyphBalanceOf(alice),
            initialGlyphBalance + expectedGlyphIncrease,
            "Incorrect glyph balance after swap"
        );
        assertEq(
            ngu.balanceOf(alice),
            initialNGUBalance + nguReceived,
            "Incorrect NGU balance after swap"
        );
        assertEq(
            weth.balanceOf(alice),
            initialWETHBalance - wethSpent,
            "Incorrect WETH balance after swap"
        );
    }

    function test_GlyphMinting_MultipleSwaps() public {
        uint256[] memory swapAmounts = new uint256[](3);
        swapAmounts[0] = 0.1 ether;
        swapAmounts[1] = 0.5 ether;
        swapAmounts[2] = 1 ether;

        uint256 initialGlyphBalance = ngu.glyphBalanceOf(bob);
        uint256 initialNGUBalance = ngu.balanceOf(bob);
        uint256 totalNGUReceivedByBob = 0;

        bool zeroForOne = address(weth) < address(ngu);

        for (uint256 i = 0; i < swapAmounts.length; i++) {
            int256 amountSpecified = -int256(swapAmounts[i]);
            uint160 sqrtPriceLimitX96 = zeroForOne ? 
                TickMath.MIN_SQRT_PRICE + 1 : 
                TickMath.MAX_SQRT_PRICE - 1;

            vm.startPrank(bob);
            BalanceDelta swapDelta = swapRouter.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified,
                    sqrtPriceLimitX96: sqrtPriceLimitX96
                }),
                PoolSwapTest.TestSettings({
                    takeClaims: false,
                    settleUsingBurn: false
                }),
                abi.encode(bob)
            );
            vm.stopPrank();

            uint256 nguReceivedThisSwap = zeroForOne ? uint256(int256(swapDelta.amount1())) : uint256(int256(swapDelta.amount0()));
            totalNGUReceivedByBob += nguReceivedThisSwap;
        }

        uint256 expectedGlyphIncrease = totalNGUReceivedByBob / UNITS;

        assertEq(
            ngu.glyphBalanceOf(bob),
            initialGlyphBalance + expectedGlyphIncrease,
            "Incorrect glyph balance after multiple swaps"
        );
        assertEq(
            ngu.balanceOf(bob),
            initialNGUBalance + totalNGUReceivedByBob,
            "Incorrect NGU balance after multiple swaps"
        );
    }

    function testFuzz_GlyphMinting_VaryingAmounts(uint104 amountWETH_raw) public {
        uint104 swapAmountWETH = uint104(bound(amountWETH_raw, 1e16, 13_000 * 1e18));

        uint256 initialGlyphBalanceAlice = ngu.glyphBalanceOf(alice);
        uint256 initialNGUBalanceAlice = ngu.balanceOf(alice);
        
        bool zeroForOne = address(weth) < address(ngu);
        int256 amountSpecified = -int256(uint256(swapAmountWETH));
        uint160 sqrtPriceLimitX96 = zeroForOne ? 
            TickMath.MIN_SQRT_PRICE + 1 : 
            TickMath.MAX_SQRT_PRICE - 1;

        vm.startPrank(alice);
        BalanceDelta swapDelta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            abi.encode(alice)
        );
        vm.stopPrank();

        uint256 nguReceived = zeroForOne ? uint256(int256(swapDelta.amount1())) : uint256(int256(swapDelta.amount0()));
        uint256 expectedGlyphIncrease = nguReceived / UNITS;

        assertEq(
            ngu.glyphBalanceOf(alice),
            initialGlyphBalanceAlice + expectedGlyphIncrease,
            "Incorrect glyph balance after fuzzed swap"
        );
        assertEq(
            ngu.balanceOf(alice),
            initialNGUBalanceAlice + nguReceived,
            "Incorrect NGU balance after fuzzed swap"
        );
    }
}
