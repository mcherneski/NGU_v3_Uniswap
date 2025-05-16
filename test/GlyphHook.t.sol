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

contract GlyphHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Constants specific to this test file
    uint256 constant INITIAL_LIQUIDITY = 100 * UNITS;
    
    // Price constants for NGU/WETH pair (1 WETH = 10 NGU)
    uint160 constant SQRT_PRICE_NGU_PER_WETH_10 = 792281625142643375935439503360;  // sqrt(10) * 2^96
    uint160 constant SQRT_PRICE_WETH_PER_NGU_0_1 = 250541448375047931186413801500; // sqrt(0.1) * 2^96

    // Test contracts
    GlyphMintingHook hook;
    NumberGoUp ngu;
    MockERC20 weth;
    PoolId poolId;

    // Test addresses
    address alice;
    address bob;

    function setUp() public {
        console2.log("Starting setUp()");
        
        // Deploy Permit2 first
        console2.log("Deploying Permit2...");
        etchPermit2();
        console2.log("Permit2 deployed at:", address(permit2));
        
        // Deploy manager, routers, and approve currencies (from Fixtures)
        console2.log("Deploying manager and routers...");
        deployFreshManagerAndRouters();
        console2.log("Manager deployed at:", address(manager));
        console2.log("SwapRouter deployed at:", address(swapRouter));

        // Setup test accounts with ETH and labels
        console2.log("Setting up test accounts...");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");

        // Deploy WETH and mint to test accounts
        console2.log("Deploying and minting WETH...");
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        weth.mint(address(this), 100 ether);  // Mint 100 WETH to admin for liquidity
        weth.mint(alice, 10 ether);
        weth.mint(bob, 10 ether);
        vm.label(address(weth), "WETH");

        // Deploy POSM first
        console2.log("Deploying POSM...");
        deployPosm(manager);
        console2.log("POSM deployed at:", address(posm));

        // Deploy NumberGoUp token with proper V4 addresses
        console2.log("Deploying NGU token...");
        ngu = new NumberGoUp(
            "Number Go Up",
            "NGU",
            18,
            UNITS,
            MAX_TOTAL_SUPPLY_ERC20,
            address(this), // initialOwner
            address(this), // initialMintRecipient
            address(swapRouter),
            address(posm),
            address(manager)
        );
        vm.label(address(ngu), "NGU Token");

        // Add Permit2 to exemption list
        ngu.setIsGlyphTransferExempt(address(permit2), true);
        
        // Add test contract to exemption list since it's providing liquidity
        ngu.setIsGlyphTransferExempt(address(this), true);

        // Configure hook permissions - we only need AFTER_SWAP_FLAG for GlyphMintingHook
        uint160 permissions = uint160(Hooks.AFTER_SWAP_FLAG);

        // Deploy the hook using HookMiner to get correct flags
        bytes memory constructorArgs = abi.encode(manager, address(ngu));
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            permissions,
            type(GlyphMintingHook).creationCode,
            constructorArgs
        );
        hook = new GlyphMintingHook{salt: salt}(manager, address(ngu));
        require(address(hook) == hookAddress, "GlyphHook: Hook address mismatch");
        vm.label(address(hook), "GlyphMintingHook");

        // Configure token permissions
        ngu.setGlyphMintingHookAddress(address(hook));

        // Create and initialize the pool with proper token ordering
        (Currency currency0, Currency currency1) = address(weth) < address(ngu) 
            ? (Currency.wrap(address(weth)), Currency.wrap(address(ngu)))
            : (Currency.wrap(address(ngu)), Currency.wrap(address(weth)));

        key = PoolKey(
            currency0,
            currency1,
            3000, // 0.3% fee tier
            60,   // tickSpacing
            IHooks(hook)
        );
        poolId = key.toId();
        
        // Initialize pool with appropriate price ratio (10 NGU = 1 WETH)
        uint160 initialPrice = address(weth) < address(ngu) 
            ? SQRT_PRICE_NGU_PER_WETH_10  // If WETH is token0, use 10 ratio
            : SQRT_PRICE_WETH_PER_NGU_0_1;  // If NGU is token0, use 0.1 ratio
        manager.initialize(key, initialPrice);

        // Approve tokens for all test participants
        vm.startPrank(address(this));
        weth.approve(address(manager), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        ngu.approve(address(manager), type(uint256).max);
        ngu.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(posm), type(uint256).max);  // Direct POSM approval for WETH
        ngu.approve(address(posm), type(uint256).max);   // Direct POSM approval for NGU

        // Approve tokens for POSM via Permit2
        weth.approve(address(permit2), type(uint256).max);
        ngu.approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(Currency.wrap(address(weth))), address(posm), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(Currency.wrap(address(ngu))), address(posm), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        vm.startPrank(alice);
        weth.approve(address(manager), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        ngu.approve(address(manager), type(uint256).max);
        ngu.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        weth.approve(address(manager), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        ngu.approve(address(manager), type(uint256).max);
        ngu.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Add initial liquidity through POSM
        int24 tickSpacing = 60;
        int24 currentTick = TickMath.getTickAtSqrtPrice(initialPrice);
        int24 tickLower = (currentTick / tickSpacing - 2) * tickSpacing;
        int24 tickUpper = (currentTick / tickSpacing + 2) * tickSpacing;

        // Adjust token amounts to match the 10:1 ratio
        uint256 wethAmount = 1e18;    // 1 WETH
        uint256 nguAmount = 10e18;    // 10 NGU (maintains 10:1 ratio)

        console2.log("Adding initial liquidity:");
        console2.log("- WETH amount:", wethAmount);
        console2.log("- NGU amount:", nguAmount);
        console2.log("- WETH balance:", weth.balanceOf(address(this)));
        console2.log("- NGU balance:", ngu.balanceOf(address(this)));
        console2.log("- WETH allowance for POSM:", weth.allowance(address(this), address(posm)));
        console2.log("- NGU allowance for POSM:", ngu.allowance(address(this), address(posm)));

        posm.mint(
            key,
            tickLower,
            tickUpper,
            INITIAL_LIQUIDITY,
            wethAmount,
            nguAmount,
            address(this),
            block.timestamp + 1000,
            ""
        );
    }

    function test_GlyphMinting_OnSwap() public {
        // Initial balances
        uint256 initialGlyphBalance = ngu.glyphBalanceOf(alice);
        uint256 initialNGUBalance = ngu.balanceOf(alice);
        uint256 initialWETHBalance = weth.balanceOf(alice);
        
        // Setup swap parameters for WETH → NGU
        bool zeroForOne = address(weth) < address(ngu);
        int256 amountSpecified = -1e18; // Exact input of 1 WETH
        uint160 sqrtPriceLimitX96 = zeroForOne ? 
            TickMath.MIN_SQRT_PRICE + 1 : 
            TickMath.MAX_SQRT_PRICE - 1;

        // Execute swap as alice
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

        // Calculate expected values
        uint256 nguReceived = uint256(uint128(zeroForOne ? -swapDelta.amount1() : -swapDelta.amount0()));
        uint256 expectedGlyphIncrease = nguReceived / UNITS;

        // Verify final balances
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
            initialWETHBalance - uint256(-amountSpecified),
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
        uint256 expectedTotalGlyphs = 0;
        uint256 totalNGUReceived = 0;

        bool zeroForOne = address(weth) < address(ngu);

        for (uint256 i = 0; i < swapAmounts.length; i++) {
            // Setup swap parameters
            int256 amountSpecified = -int256(swapAmounts[i]);
            uint160 sqrtPriceLimitX96 = zeroForOne ? 
                TickMath.MIN_SQRT_PRICE + 1 : 
                TickMath.MAX_SQRT_PRICE - 1;

            // Execute swap as bob
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

            // Track received amounts
            uint256 nguReceived = uint256(uint128(zeroForOne ? -swapDelta.amount1() : -swapDelta.amount0()));
            totalNGUReceived += nguReceived;
            expectedTotalGlyphs += nguReceived / UNITS;
        }

        // Verify final balances
        assertEq(
            ngu.glyphBalanceOf(bob),
            initialGlyphBalance + expectedTotalGlyphs,
            "Incorrect glyph balance after multiple swaps"
        );
        assertEq(
            ngu.balanceOf(bob),
            initialNGUBalance + totalNGUReceived,
            "Incorrect NGU balance after multiple swaps"
        );
    }

    function testFuzz_GlyphMinting_VaryingAmounts(uint256 wethAmount) public {
        // Bound input to reasonable ranges
        wethAmount = bound(wethAmount, 0.01 ether, 10 ether);
        
        // Track initial balances
        uint256 initialGlyphBalance = ngu.glyphBalanceOf(alice);
        uint256 initialNGUBalance = ngu.balanceOf(alice);
        
        // Setup swap parameters
        bool zeroForOne = address(weth) < address(ngu);
        int256 amountSpecified = -int256(wethAmount);
        uint160 sqrtPriceLimitX96 = zeroForOne ? 
            TickMath.MIN_SQRT_PRICE + 1 : 
            TickMath.MAX_SQRT_PRICE - 1;

        // Execute swap
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

        // Calculate expected values
        uint256 nguReceived = uint256(uint128(zeroForOne ? -swapDelta.amount1() : -swapDelta.amount0()));
        uint256 expectedGlyphIncrease = nguReceived / UNITS;

        // Verify balances
        assertEq(
            ngu.glyphBalanceOf(alice),
            initialGlyphBalance + expectedGlyphIncrease,
            "Incorrect glyph balance after fuzzed swap"
        );
        assertEq(
            ngu.balanceOf(alice),
            initialNGUBalance + nguReceived,
            "Incorrect NGU balance after fuzzed swap"
        );
    }
}
